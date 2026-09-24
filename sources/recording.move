// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// An audio recording of a composition, with its own fixed-supply share token
/// (100M, 6 decimals). Core stores identity, lifecycle state, and the parent
/// `composition_id`; names, credits, and masters are extension data attached
/// via `uid_mut`. The core/extension split, atomic create-and-publish, and
/// `uid_mut` trust model are as described in `composition`.
///
/// The embedded `composition_id`, set from the `&Composition` passed to `new`
/// and immutable, is the single source of truth for which composition a
/// recording (and every track of it) embodies. `Recording` takes only a
/// `RecordingShare` parameter: one share type backs exactly one recording, so
/// clients can locate a recording by its share type alone.
///
/// A recording is a fresh object, not a derived child of its composition:
/// `new` reads `&Composition` only, so recordings under one composition
/// neither contend on its version nor collide on an index.
module musicos::recording;

use musicos::composition::Composition;
use share::share;
use sui::balance::Balance;
use sui::coin::TreasuryCap;
use sui::coin_registry::Currency;
use sui::derived_object::claim;
use sui::event::emit;

#[test_only]
use sui::bcs::to_bytes;

// === Errors ===

// State errors (10-19)
/// Operation requires Initialized state but recording is in a different state.
const ENotInitializedState: u64 = 10;

// === Structs ===

/// An audio recording of a composition; `RecordingShare` is its share token type.
public struct Recording<phantom RecordingShare> has key {
    id: UID,
    /// Current lifecycle state.
    state: RecordingState,
    /// The parent composition's id. An identity handle, not a revenue target:
    /// the composition is paid through the recording shares it owns (see `new`).
    composition_id: ID,
}

/// Authorizes admin operations on one recording. Its address is derived from
/// the recording under `RecordingAdminCapKey`.
public struct RecordingAdminCap<phantom RecordingShare> has key, store {
    id: UID,
}

/// Derivation key for `RecordingAdminCap`.
public struct RecordingAdminCapKey() has copy, drop, store;

// === Enums ===

/// Lifecycle state of a recording.
public enum RecordingState has drop, store {
    /// Created but not yet published.
    Initialized,
    /// Published and immutable.
    Published,
}

// === Events ===

/// Emitted once when a recording is published: identity and composition id.
/// The publish time is the event's transaction timestamp. Everything else
/// (share type, sender, currency and treasury cap ids, admin cap address) is
/// derivable from the transaction and `share::ShareInitializedEvent`; the
/// royalty rate `new` applied is the immutable `royalty_rate_bps` of the
/// composition's `CompositionPublishedEvent`.
public struct RecordingPublishedEvent<phantom RecordingShare> has copy, drop {
    recording_id: address,
    composition_id: address,
}

// === Public Functions ===

/// Creates a recording of `composition` and initializes its share token
/// (100M supply, 6 decimals). Returns the recording, its admin cap, and the
/// creator's share balance (full supply minus the composition's cut).
///
/// The composition's royalty rate is settled as ownership at creation: that
/// fraction of the freshly minted recording shares is sent to the
/// composition's address, so its claim on recording revenue is enforced by
/// share ownership rather than by a distributor honoring a rate. The rate is
/// immutable, so the rate a client displayed is exactly the rate applied;
/// per-deal deviations are voluntary share transfers after creation.
///
/// The composition need not be `Published`: its creator may mint recordings
/// against it within the creating transaction. Across transactions only
/// `Published`, shared compositions exist.
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

    let mut recording = Recording<RecordingShare> {
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

    // Settle the composition's cut as recording-share ownership; the split-off
    // portion is never returned to the caller. A 0% rate has no cut: skip the
    // split so the composition gets no zero-value share accumulator. Any
    // non-zero rate yields a non-zero cut, since the full fixed supply is
    // always minted (1 bps of it is 10^10 base units).
    if (composition_royalty_rate.value() > 0) {
        let composition_cut = composition_royalty_rate.apply(recording_shares.value());
        let composition_shares = recording_shares.split(composition_cut);
        composition_shares.send_funds(composition_id.to_address());
    };

    (recording, recording_admin_cap, recording_shares)
}

/// Publishes the recording: shares it and freezes its embedded fields.
/// Aborts with `ENotInitializedState` unless `Initialized`.
public fun publish<RecordingShare>(
    mut self: Recording<RecordingShare>,
    _: &RecordingAdminCap<RecordingShare>,
) {
    match (&self.state) {
        RecordingState::Initialized => {
            self.state = RecordingState::Published;

            let recording_id = object::id_address(&self);
            let composition_id = self.composition_id.to_address();

            transfer::share_object(self);

            emit(RecordingPublishedEvent<RecordingShare> {
                recording_id,
                composition_id,
            });
        },
        _ => abort ENotInitializedState,
    }
}

// === View Functions ===

/// The parent composition's object id, immutable since `new`.
public fun composition_id<RecordingShare>(self: &Recording<RecordingShare>): ID {
    self.composition_id
}

/// Read access to the recording's UID (dynamic fields).
public fun uid<RecordingShare>(self: &Recording<RecordingShare>): &UID {
    &self.id
}

/// Mutable access to the recording's UID, gated by the admin cap. Works in
/// any lifecycle state; see `composition::uid_mut` for the trust model.
public fun uid_mut<RecordingShare>(
    self: &mut Recording<RecordingShare>,
    _: &RecordingAdminCap<RecordingShare>,
): &mut UID {
    &mut self.id
}

// === Test Functions ===

// State predicates are test-only: create-and-publish is atomic, so every
// recording a runtime caller can hold is `Published`.

#[test_only]
public fun is_initialized_state<RecordingShare>(self: &Recording<RecordingShare>): bool {
    match (&self.state) { RecordingState::Initialized => true, _ => false }
}

#[test_only]
public fun is_published_state<RecordingShare>(self: &Recording<RecordingShare>): bool {
    match (&self.state) { RecordingState::Published => true, _ => false }
}

#[test_only]
public fun published_state_bcs_bytes(): vector<u8> {
    to_bytes(&RecordingState::Published)
}

#[test_only]
public fun new_for_testing<RecordingShare>(
    composition_id: ID,
    ctx: &mut TxContext,
): (Recording<RecordingShare>, RecordingAdminCap<RecordingShare>) {
    let mut recording = Recording<RecordingShare> {
        id: object::new(ctx),
        state: RecordingState::Initialized,
        composition_id,
    };

    let recording_admin_cap = RecordingAdminCap<RecordingShare> {
        id: claim(&mut recording.id, RecordingAdminCapKey()),
    };

    (recording, recording_admin_cap)
}

/// Unpacks a `RecordingPublishedEvent` (fields are module-private) for test assertions.
#[test_only]
public fun recording_published_event_fields<RecordingShare>(
    event: RecordingPublishedEvent<RecordingShare>,
): (address, address) {
    let RecordingPublishedEvent { recording_id, composition_id } = event;
    (recording_id, composition_id)
}
