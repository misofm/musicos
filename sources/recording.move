// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A musical recording, identified independently of ownership or tokenization.
/// Embedded relationships freeze at publication. Extensions attach through
/// admin-authorized UID access, which remains available after publication.
/// Objects are key-only: creation must end with publication in the same transaction.
module musicos::recording;

// === Imports ===

use sui::derived_object::claim;
use sui::event::emit;

#[test_only]
use sui::bcs::to_bytes;

use musicos::composition::Composition;

// === Errors ===

/// The admin capability belongs to another object.
const EUnauthorized: u64 = 0;

// State errors (10-19)
/// Operation requires Initialized state but recording is in a different state.
const ENotInitializedState: u64 = 10;

// === Structs ===

/// An audio recording of a composition.
public struct Recording has key {
    id: UID,
    /// Current lifecycle state.
    state: RecordingState,
    /// The parent composition identity.
    composition_id: ID,
}

/// Authorizes admin operations on one recording. Its address is derived from
/// the recording under `RecordingAdminCapKey`.
public struct RecordingAdminCap has key, store {
    id: UID,
    recording_id: ID,
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

/// Emitted once when the recording is published.
public struct RecordingPublishedEvent has copy, drop {
    recording_id: ID,
    composition_id: ID,
}

// === Public Functions ===

/// Creates the recording and its object-bound admin capability.
public fun new(composition: &Composition, ctx: &mut TxContext): (Recording, RecordingAdminCap) {
    let mut recording = Recording {
        id: object::new(ctx),
        state: RecordingState::Initialized,
        composition_id: object::id(composition),
    };
    let recording_id = object::id(&recording);
    let cap = RecordingAdminCap {
        id: claim(&mut recording.id, RecordingAdminCapKey()),
        recording_id,
    };
    (recording, cap)
}

/// Publishes the recording: shares it and freezes its embedded fields.
/// Aborts with `ENotInitializedState` unless `Initialized`.
public fun publish(
    mut self: Recording,
    cap: &RecordingAdminCap,
) {
    self.authorize(cap);
    match (&self.state) {
        RecordingState::Initialized => {
            self.state = RecordingState::Published;

            let recording_id = object::id(&self);
            let composition_id = self.composition_id;

            transfer::share_object(self);

            emit(RecordingPublishedEvent {
                recording_id,
                composition_id,
            });
        },
        _ => abort ENotInitializedState,
    }
}

/// Verifies that the admin capability belongs to this recording.
public fun authorize(self: &Recording, cap: &RecordingAdminCap) {
    assert!(object::id(self) == cap.recording_id, EUnauthorized);
}

// === View Functions ===

/// The parent composition's object id, immutable since `new`.
public fun composition_id(self: &Recording): ID {
    self.composition_id
}

/// Read access to the recording's UID (dynamic fields).
public fun uid(self: &Recording): &UID {
    &self.id
}

/// Mutable access to the recording's UID, gated by the admin cap. Works in
/// any lifecycle state; see `composition::uid_mut` for the trust model.
public fun uid_mut(
    self: &mut Recording,
    cap: &RecordingAdminCap,
): &mut UID {
    self.authorize(cap);
    &mut self.id
}

// === Test Functions ===

// State predicates are test-only: create-and-publish is atomic, so every
// recording a runtime caller can hold is `Published`.

#[test_only]
public fun is_initialized_state(self: &Recording): bool {
    match (&self.state) { RecordingState::Initialized => true, _ => false }
}

#[test_only]
public fun is_published_state(self: &Recording): bool {
    match (&self.state) { RecordingState::Published => true, _ => false }
}

#[test_only]
public fun published_state_bcs_bytes(): vector<u8> {
    to_bytes(&RecordingState::Published)
}

#[test_only]
public fun new_for_testing(
    composition_id: ID,
    ctx: &mut TxContext,
): (Recording, RecordingAdminCap) {
    let mut recording = Recording {
        id: object::new(ctx),
        state: RecordingState::Initialized,
        composition_id,
    };

    let recording_id = object::id(&recording);
    let recording_admin_cap = RecordingAdminCap {
        id: claim(&mut recording.id, RecordingAdminCapKey()),
        recording_id,
    };

    (recording, recording_admin_cap)
}

/// Unpacks a `RecordingPublishedEvent` (fields are module-private) for test assertions.
#[test_only]
public fun recording_published_event_fields(
    event: RecordingPublishedEvent,
): (ID, ID) {
    let RecordingPublishedEvent { recording_id, composition_id } = event;
    (recording_id, composition_id)
}
