// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Represents an audio recording of a composition in musicos.
/// Recordings are the audio performances that are distributed and played.
/// Each recording has its own share token for ownership distribution.
///
/// ### Key Features:
///
/// - Share token initialization with fixed supply (100M tokens, 6 decimals)
/// - State machine: Initialized -> Published (embedded fields immutable after
///   publish; dynamic fields remain extensible via `uid_mut`, e.g. masters,
///   and credits/attribution attached by the credits extension)
/// - Deterministic addresses via derived object pattern
///
/// Attribution (credits, primary/featured artists) is intentionally NOT part of
/// core: it is display-oriented, varies across platforms, and is never read by
/// the economics. It lives in a first-party credits extension attached via
/// `uid_mut`, so core takes no dependency on an identity package and core
/// publish enforces no attribution.
///
/// A recording carries no name of its own, and neither does its composition:
/// display titles for both live in the metadata extension. A recording is a
/// take of its composition, so its name is the composition's name plus
/// whatever names this particular take — "(Live)", "Radio Edit", a translated
/// title — and every part of that has more than one correct rendering, which
/// makes it presentation, and presentation lives in the metadata extension,
/// never in the frozen core. Core stores what a recording *is*; extensions
/// describe it.
///
/// ### Lifecycle and trust model
///
/// A recording is `key`-only with no `drop`: a fresh `Initialized` object
/// cannot be transferred, wrapped, publicly shared, or discarded, and its only
/// by-value consumer is `publish`. Create-and-publish is therefore atomic by
/// construction — an `Initialized` recording cannot outlive its creating
/// transaction, and every recording that exists on-chain is `Published` and
/// shared. There is deliberately no keep function; staged building must fit
/// one transaction.
///
/// `uid_mut` works in any lifecycle state and is permanent root over ALL
/// dynamic fields on the object — including fields attached by other
/// extensions. "Immutable after publish" covers the embedded fields only;
/// extension-layer data stays admin-mutable in perpetuity. This is the
/// designed extension surface, and it is the one trust assumption that never
/// expires: integrators should model the cap holder as able to mutate or
/// delete any extension data, forever.
///
/// The recording's link to its parent composition is the embedded
/// `composition_id`: set from the `&Composition` passed to `new`, immutable
/// thereafter, and the single source of truth for which composition a
/// recording — and so every track of it — embodies: consumers holding a
/// `&Recording` or a track's `recording_id` reach the composition (and,
/// through it, the composition's own share type) through it. `Recording` deliberately carries no
/// `CompositionShare` type parameter. The composition share type is already a
/// function of the recording share type — `new` consumes the recording
/// share's `TreasuryCap`, so each `RecordingShare` backs exactly one
/// recording, which has exactly one composition — and a phantom would never
/// be checked against anything after `new`: an ID can be resolved off-chain
/// and checked on-chain against a supplied object, whereas a type can be
/// neither, so the pairing is a data fact either way. Keeping
/// the type single-parameter also lets a client locate a recording by the
/// `Recording<R>` type filter from its share type alone (Sui type filters
/// cannot wildcard one type argument). Code that must establish that a
/// specific `Recording` and `Composition` go together compares
/// `composition_id()` with the composition's object ID.
///
/// A recording is its own freshly-created object (`object::new`), not a derived
/// child of its composition: `recording::new` takes a read-only `&Composition`
/// (only to read its royalty rate and id), so publishing recordings under a
/// composition neither contends on the composition's shared-object version nor
/// collides on a per-composition index.
module musicos::recording;

use musicos::composition::Composition;
use share::share;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::TreasuryCap;
use sui::coin_registry::Currency;
use sui::derived_object::claim;
use sui::event::emit;

// === Errors ===

// State errors (10-19)
/// Operation requires Initialized state but recording is in a different state.
const ENotInitializedState: u64 = 10;

// === Structs ===

/// An audio recording of a composition. The `RecordingShare` phantom links to
/// this recording's own share token; the parent composition is linked by the
/// embedded `composition_id` alone (see the module doc for why there is no
/// `CompositionShare` type parameter).
public struct Recording<phantom RecordingShare> has key {
    /// Unique identifier for this recording.
    id: UID,
    /// Current lifecycle state.
    state: RecordingState,
    /// Object ID of the parent composition — the recording's one link to it,
    /// set from the `&Composition` passed to `new` and immutable thereafter. An
    /// identity handle — not a revenue routing target: the composition is
    /// paid through its recording-share ownership, settled at creation.
    composition_id: ID,
}

/// Capability that authorizes modifications to a specific recording.
/// Initialized when a recording is registered and transferred to the owner.
/// Address is derived from the recording for client-side discoverability.
///
/// Parameterized by `RecordingShare` alone, like the recording itself: the
/// share type uniquely identifies the recording (`new` consumes the share's
/// `TreasuryCap`, so one share type backs at most one recording), and the cap
/// authorizes recording-scoped operations that have no bearing on the parent
/// composition — so the composition's identity has no place in the cap's type.
public struct RecordingAdminCap<phantom RecordingShare> has key, store {
    /// Unique identifier for this capability.
    id: UID,
}

/// Key for deriving the admin capability's deterministic address from the recording.
public struct RecordingAdminCapKey() has copy, drop, store;

// === Enums ===

/// Lifecycle state of a recording.
public enum RecordingState has drop, store {
    /// Recording is initialized but not published. Carries only what
    /// `publish` needs and cannot otherwise reach: the composition royalty
    /// rate `new` applied — `publish` does not receive the composition, and
    /// the recording embeds only its id.
    Initialized {
        composition_royalty_rate_bps: u16,
    },
    /// Recording is published and immutable. Includes publication timestamp.
    Published(
        /// Timestamp (ms) when published.
        u64,
    ),
}

// === Events ===

/// Emitted once when a recording is published. Typed by `RecordingShare`
/// only, like the recording; the parent composition is carried as the
/// `composition_id` payload field.
///
/// The payload is deliberately minimal. A field is carried only if an indexer
/// reading musicos events alone would otherwise need an object lookup to
/// obtain it and it matters to the business: the recording's identity, its
/// composition, the composition royalty rate that `new` settled as share
/// ownership, and when it was published. Everything else about the
/// publication is derivable without a lookup — the share type from the
/// event's type argument; the sender from the transaction envelope; the share
/// currency and consumed treasury cap ids from the `share::ShareInitializedEvent`
/// emitted in the same transaction; the admin cap id as the derived address
/// of `recording_id` under `RecordingAdminCapKey`; and the share arithmetic
/// from `share::initialize`'s constants (100M · 10^6 supply, 6 decimals, zero
/// before, fixed after): the composition's cut is
/// `composition_royalty_rate_bps` applied to that supply, it was sent to
/// `composition_id` exactly when it is non-zero, and the creator received the
/// remainder.
public struct RecordingPublishedEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
    composition_id: address,
    composition_royalty_rate_bps: u16,
    published_at_ms: u64,
}

// === Public Functions ===

/// Creates a new recording for a composition.
///
/// Initializes share tokens (100M supply, 6 decimals), then splits the
/// composition's royalty-rate worth of those shares off the freshly minted
/// supply and `send_funds`es them to the composition's address. This settles
/// the composition's cut as cap-table ownership: the composition literally
/// owns its share of the recording, so its claim on recording revenue is
/// enforced by share ownership rather than by any revenue distributor choosing
/// to honor a rate. What the composition owner then does with the shares
/// (hold, stake, sell) is outside the protocol's scope.
///
/// The composition's royalty rate is immutable, so the rate a recorder's
/// client displayed is exactly the rate applied here — no slippage protection
/// is needed or possible. Whether that rate is acceptable is the recorder's
/// decision to make before calling; per-deal deviations settle as voluntary
/// share transfers after creation.
///
/// The composition need not be `Published`: within the composition's own
/// creating transaction its creator can already mint recordings against it.
/// Third parties only ever see `Published`, shared compositions (an
/// `Initialized` one cannot escape its creating transaction), so indexers may
/// observe a recording created "against an unpublished composition" only as
/// an intra-transaction ordering, never across transactions.
///
/// Returns:
/// - The recording object, its `composition_id` set to `composition`'s id
///   (`CompositionShare` is a parameter of this function only — it does not
///   appear in the recording's type)
/// - Admin capability for the owner
/// - The creator's remaining share balance (full supply minus the
///   composition's cut)
public fun new<RecordingShare, CompositionShare>(
    composition: &Composition<CompositionShare>,
    share_currency: &mut Currency<RecordingShare>,
    share_treasury_cap: TreasuryCap<RecordingShare>,
    ctx: &mut TxContext,
): (
    Recording<RecordingShare>,
    RecordingAdminCap<RecordingShare>,
    Balance<RecordingShare>,
) {
    let composition_id = object::id(composition);
    let composition_royalty_rate = composition.royalty_rate();

    // A recording is its own freshly-created object, not a derived child of its
    // composition. The composition is read-only (`&Composition`) — taken only to
    // snapshot its royalty rate and address — so concurrent recordings under the
    // same composition neither contend on its shared-object version nor collide
    // on an index. The composition↔recording link is the embedded
    // `composition_id`, taken here from a real `&Composition` and never
    // rewritten — the recording's type says nothing about its composition.
    let mut recording = Recording<RecordingShare> {
        id: object::new(ctx),
        state: RecordingState::Initialized {
            composition_royalty_rate_bps: composition_royalty_rate.value(),
        },
        composition_id,
    };

    let recording_admin_cap = RecordingAdminCap<RecordingShare> {
        id: claim(&mut recording.id, RecordingAdminCapKey()),
    };

    let mut recording_shares = share::initialize<RecordingShare>(
        share_currency,
        share_treasury_cap,
    );

    // Settle the composition's royalty rate as ownership rather than as a
    // distribution-time routing parameter: split the rate's worth of recording
    // shares off the freshly minted supply and send it to the composition's
    // address. The composition now owns its cut of the recording outright; the
    // remainder returns to the creator. The split is internal and the
    // composition's portion is never returned to the caller, so the creator
    // cannot retain it.
    //
    // A 0% rate (e.g. a generative recording with no authored composition) yields
    // no cut: skip the split/send so we don't open a zero-value share accumulator
    // for the composition. The Published event still records that the applied
    // rate was zero.
    let composition_cut = composition_royalty_rate.apply(recording_shares.value());
    if (composition_cut > 0) {
        let composition_shares = recording_shares.split(composition_cut);
        composition_shares.send_funds(composition_id.to_address());
    };

    (recording, recording_admin_cap, recording_shares)
}

/// Publishes the recording, making its embedded fields immutable.
/// Required State: Initialized
///
/// Note: core enforces no attribution requirement — credits live in the credits
/// extension and may be attached before or after publish via `uid_mut`.
public fun publish<RecordingShare>(
    mut self: Recording<RecordingShare>,
    _: &RecordingAdminCap<RecordingShare>,
    clock: &Clock,
) {
    match (&self.state) {
        RecordingState::Initialized { composition_royalty_rate_bps } => {
            let composition_royalty_rate_bps = *composition_royalty_rate_bps;
            // Set the recording's publish timestamp.
            let published_at_ms = clock.timestamp_ms();
            self.state = RecordingState::Published(published_at_ms);

            let recording_id = object::id_address(&self);
            let composition_id = self.composition_id.to_address();

            transfer::share_object(self);

            emit(RecordingPublishedEvent<RecordingShare> {
                recording_id,
                composition_id,
                composition_royalty_rate_bps,
                published_at_ms,
            });
        },
        _ => abort ENotInitializedState,
    };
}

// === View Functions ===

/// Returns the object ID of the parent composition — the recording's link to
/// it, set from a real `&Composition` in `new` and immutable since. An
/// identity/membership handle, not a revenue routing target: the composition
/// is paid via its recording-share ownership.
public fun composition_id<RecordingShare>(self: &Recording<RecordingShare>): ID {
    self.composition_id
}

/// Returns a reference to the recording's UID for reading dynamic fields.
public fun uid<RecordingShare>(self: &Recording<RecordingShare>): &UID {
    &self.id
}

/// Returns a mutable reference to the recording's UID.
/// Requires the admin capability. Works in any lifecycle state — dynamic
/// fields are the extension surface (e.g. masters, credits) and stay
/// admin-mutable after publish; only the embedded fields are frozen. The
/// reference is root over every dynamic field on the object, including
/// fields attached by other extensions.
public fun uid_mut<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    _: &RecordingAdminCap<RecordingShare>,
): &mut UID {
    &mut self.id
}

// === Test Functions ===

// The state predicates are test-only: create-and-publish is atomic (a recording
// is `key`-only and `publish` is its sole by-value consumer), so every
// recording any runtime caller can hold is `Published` — the answer is known a
// priori and a public accessor would carry no information. Tests still need
// them to verify the transition itself.

#[test_only]
public fun is_initialized_state<RecordingShare>(self: &Recording<RecordingShare>): bool {
    match (&self.state) { RecordingState::Initialized { .. } => true, _ => false }
}

#[test_only]
public fun is_published_state<RecordingShare>(self: &Recording<RecordingShare>): bool {
    match (&self.state) { RecordingState::Published(_) => true, _ => false }
}

#[test_only]
public fun published_state_bcs_bytes(timestamp_ms: u64): vector<u8> {
    sui::bcs::to_bytes(&RecordingState::Published(timestamp_ms))
}

#[test_only]
public fun new_for_testing<RecordingShare>(
    composition_id: ID,
    ctx: &mut TxContext,
): (Recording<RecordingShare>, RecordingAdminCap<RecordingShare>) {
    let mut recording = Recording<RecordingShare> {
        id: object::new(ctx),
        state: RecordingState::Initialized { composition_royalty_rate_bps: 0 },
        composition_id,
    };

    let recording_admin_cap = RecordingAdminCap<RecordingShare> {
        id: claim(&mut recording.id, RecordingAdminCapKey()),
    };

    (recording, recording_admin_cap)
}

/// Unpacks a `RecordingPublishedEvent` for test-side field assertions — the
/// event's fields are module-private, so tests in another module need this
/// accessor to assert the payload rather than just "an event fired".
#[test_only]
public fun recording_published_event_fields<RecordingShare>(
    event: RecordingPublishedEvent<RecordingShare>,
): (address, address, u16, u64) {
    let RecordingPublishedEvent {
        recording_id,
        composition_id,
        composition_royalty_rate_bps,
        published_at_ms,
    } = event;
    (recording_id, composition_id, composition_royalty_rate_bps, published_at_ms)
}
