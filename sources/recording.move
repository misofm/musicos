// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Represents an audio recording of a composition in musicos.
/// Recordings are the audio performances that are distributed and played.
/// Each recording has its own share token for ownership distribution.
///
/// ### Key Features:
///
/// - Share token initialization with fixed supply (10M tokens, 6 decimals)
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
/// A recording carries no name of its own. Its display title is its
/// composition's title, read by reference — composition titles are immutable,
/// so an embedded copy would carry no information. Anything that names this
/// particular take — "(Live)", "Radio Edit", a translated title — has more
/// than one correct rendering, which makes it presentation, and presentation
/// lives in the metadata extension, never in the frozen core. Core stores what
/// a recording *is*; extensions describe it.
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
/// The recording carries its parent composition's identity two ways. The
/// `CompositionShare` phantom type parameter is the durable identity (a share
/// currency is published independently of musicos and survives a fresh
/// republish, whereas an object ID does not) and makes the
/// recording↔composition lineage compile-time enforced wherever the two meet.
/// The embedded `composition_id` is the address-level handle: Move cannot
/// chase a type (or an ID) to an object, so on-chain consumers holding only
/// `&Recording` — or a bare `Track` — could not otherwise reach the
/// composition at all. Both are set at creation and immutable, so they cannot
/// diverge.
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
/// this recording's own share token; the `CompositionShare` phantom is the
/// durable identity of the parent composition (its share type).
public struct Recording<phantom RecordingShare, phantom CompositionShare> has key {
    /// Unique identifier for this recording.
    id: UID,
    /// Current lifecycle state.
    state: RecordingState,
    /// Object ID of the parent composition. The address-level counterpart of
    /// the `CompositionShare` phantom, set from the `&Composition` passed to
    /// `new` (the shared phantom proves the pairing). An identity handle —
    /// not a revenue routing target: the composition is paid through its
    /// recording-share ownership, settled at creation.
    composition_id: ID,
}

/// Capability that authorizes modifications to a specific recording.
/// Initialized when a recording is registered and transferred to the owner.
/// Address is derived from the recording for client-side discoverability.
///
/// Parameterized only by `RecordingShare` (not `CompositionShare`): the share
/// type already uniquely identifies the recording, and the cap authorizes
/// recording-scoped operations that have no bearing on the parent composition.
/// Keeping it single-param stops the composition identity from contaminating
/// every place a cap is held or passed.
public struct RecordingAdminCap<phantom RecordingShare> has key, store {
    /// Unique identifier for this capability.
    id: UID,
}

/// Key for deriving the admin capability's deterministic address from the recording.
public struct RecordingAdminCapKey() has copy, drop, store;

// === Enums ===

/// Lifecycle state of a recording.
public enum RecordingState has copy, drop, store {
    /// Recording is being set up and can be modified.
    Initialized,
    /// Recording is published and immutable. Includes publication timestamp.
    Published(
        /// Timestamp (ms) when published.
        u64,
    ),
}

// === Events ===

/// Emitted once when a recording is published. A pure pointer: it carries the
/// recording's identity, with the parent composition encoded as the
/// `CompositionShare` phantom. A recording's embedded fields are immutable after
/// publishing, so an indexer treats this as a signal to fetch the full object by
/// `recording_id`; all indexed data — including the publish timestamp — lives in
/// the object itself. Dynamic fields (e.g. masters attached by ingesters,
/// credits attached by the credits extension) may still change afterward.
public struct RecordingPublishedEvent<phantom RecordingShare, phantom CompositionShare> has copy, drop {
    recording_id: ID,
}

/// Emitted when a recording grants the composition its royalty-rate worth of
/// recording shares at creation. The composition's cut is settled as cap-table
/// ownership — `send_funds`ed to the composition's address — so its claim on
/// recording revenue is enforced by share ownership, not by any revenue
/// distributor choosing to honor a rate. The rate is not stored on the
/// recording: this event (in the creation transaction's effects) is its
/// canonical record. What the composition owner then does with the shares
/// (hold, stake, sell) is outside the protocol's scope. Both parties are
/// identified by both object IDs and the event's phantom type parameters.
public struct CompositionSharesGrantedEvent<phantom RecordingShare, phantom CompositionShare> has copy, drop {
    recording_id: ID,
    composition_id: ID,
    /// Recording-share base units granted to the composition.
    value: u64,
    /// The composition royalty rate applied at creation, in basis points.
    rate_bps: u16,
    granted_by: address,
}

// === Public Functions ===

/// Creates a new recording for a composition.
///
/// Initializes share tokens (10M supply, 6 decimals), then splits the
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
/// - The recording object (typed to its parent composition's `CompositionShare`)
/// - Admin capability for the owner
/// - The creator's remaining share balance (full supply minus the
///   composition's cut)
public fun new<RecordingShare, CompositionShare>(
    composition: &Composition<CompositionShare>,
    share_currency: &mut Currency<RecordingShare>,
    share_treasury_cap: TreasuryCap<RecordingShare>,
    ctx: &mut TxContext,
): (
    Recording<RecordingShare, CompositionShare>,
    RecordingAdminCap<RecordingShare>,
    Balance<RecordingShare>,
) {
    let composition_id = object::id(composition);
    let composition_royalty_rate = composition.royalty_rate();

    // A recording is its own freshly-created object, not a derived child of its
    // composition. The composition is read-only (`&Composition`) — taken only to
    // snapshot its royalty rate and address — so concurrent recordings under the
    // same composition neither contend on its shared-object version nor collide
    // on an index. The composition↔recording link rides solely on the
    // `CompositionShare` phantom (durable identity).
    let mut recording = Recording<RecordingShare, CompositionShare> {
        id: object::new(ctx),
        state: RecordingState::Initialized,
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
    // for the composition. The grant event is still emitted as the canonical
    // record that the applied rate was zero.
    let composition_cut = composition_royalty_rate.apply(recording_shares.value());
    if (composition_cut > 0) {
        let composition_shares = recording_shares.split(composition_cut);
        composition_shares.send_funds(composition_id.to_address());
    };

    emit(CompositionSharesGrantedEvent<RecordingShare, CompositionShare> {
        recording_id: object::id(&recording),
        composition_id,
        value: composition_cut,
        rate_bps: composition_royalty_rate.value(),
        granted_by: ctx.sender(),
    });

    (recording, recording_admin_cap, recording_shares)
}

/// Publishes the recording, making its embedded fields immutable.
/// Required State: Initialized
///
/// Note: core enforces no attribution requirement — credits live in the credits
/// extension and may be attached before or after publish via `uid_mut`.
public fun publish<RecordingShare, CompositionShare>(
    mut self: Recording<RecordingShare, CompositionShare>,
    _: &RecordingAdminCap<RecordingShare>,
    clock: &Clock,
) {
    match (self.state) {
        RecordingState::Initialized => {
            // Set the recording's publish timestamp.
            let published_at_ms = clock.timestamp_ms();
            self.state = RecordingState::Published(published_at_ms);

            emit(RecordingPublishedEvent<RecordingShare, CompositionShare> {
                recording_id: object::id(&self),
            });

            transfer::share_object(self);
        },
        _ => abort ENotInitializedState,
    };
}

// === View Functions ===

/// Returns the object ID of the parent composition. An identity/membership
/// handle (the address-level counterpart of the `CompositionShare` phantom) —
/// not a revenue routing target: the composition is paid via its
/// recording-share ownership.
public fun composition_id<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): ID {
    self.composition_id
}

/// Returns a reference to the recording's UID for reading dynamic fields.
public fun uid<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): &UID {
    &self.id
}

/// Returns a mutable reference to the recording's UID.
/// Requires the admin capability. Works in any lifecycle state — dynamic
/// fields are the extension surface (e.g. masters, credits) and stay
/// admin-mutable after publish; only the embedded fields are frozen. The
/// reference is root over every dynamic field on the object, including
/// fields attached by other extensions.
public fun uid_mut<RecordingShare, CompositionShare>(
    self: &mut Recording<RecordingShare, CompositionShare>,
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
public fun is_initialized_state<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): bool {
    match (self.state) { RecordingState::Initialized => true, _ => false }
}

#[test_only]
public fun is_published_state<RecordingShare, CompositionShare>(
    self: &Recording<RecordingShare, CompositionShare>,
): bool {
    match (self.state) { RecordingState::Published(_) => true, _ => false }
}

#[test_only]
public fun new_for_testing<RecordingShare, CompositionShare>(
    composition_id: ID,
    ctx: &mut TxContext,
): (Recording<RecordingShare, CompositionShare>, RecordingAdminCap<RecordingShare>) {
    let mut recording = Recording<RecordingShare, CompositionShare> {
        id: object::new(ctx),
        state: RecordingState::Initialized,
        composition_id,
    };

    let recording_admin_cap = RecordingAdminCap<RecordingShare> {
        id: claim(&mut recording.id, RecordingAdminCapKey()),
    };

    (recording, recording_admin_cap)
}

#[test_only]
public fun composition_shares_granted_event_fields<RecordingShare, CompositionShare>(
    event: CompositionSharesGrantedEvent<RecordingShare, CompositionShare>,
): (ID, ID, u64, u16, address) {
    let CompositionSharesGrantedEvent {
        recording_id,
        composition_id,
        value,
        rate_bps,
        granted_by,
    } = event;
    (recording_id, composition_id, value, rate_bps, granted_by)
}

/// Unpacks a `RecordingPublishedEvent` for test-side field assertions — the
/// event's field is module-private, so tests in another module need this
/// accessor to assert the full payload rather than just "an event fired".
#[test_only]
public fun recording_published_event_fields<RecordingShare, CompositionShare>(
    event: RecordingPublishedEvent<RecordingShare, CompositionShare>,
): ID {
    let RecordingPublishedEvent { recording_id } = event;
    recording_id
}
