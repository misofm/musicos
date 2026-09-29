// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A musical composition, identified independently of ownership or tokenization.
/// Embedded relationships freeze at publication. Extensions attach through
/// admin-authorized UID access, which remains available after publication.
/// Objects are key-only: creation must end with publication in the same transaction.
module musicos::composition;

// === Imports ===

use sui::derived_object::claim;
use sui::event::emit;

#[test_only]
use sui::bcs::to_bytes;

// === Errors ===

/// The admin capability belongs to another object.
const EUnauthorized: u64 = 0;

// State errors (10-19)
/// Operation requires Initialized state but composition is in a different state.
const ENotInitializedState: u64 = 10;

// === Structs ===

/// The underlying written work.
public struct Composition has key {
    id: UID,
    /// Current lifecycle state.
    state: CompositionState,
}

/// Authorizes admin operations on one composition. Its address is derived
/// from the composition under `CompositionAdminCapKey`.
public struct CompositionAdminCap has key, store {
    id: UID,
    composition_id: ID,
}

/// Derivation key for `CompositionAdminCap`.
public struct CompositionAdminCapKey() has copy, drop, store;

// === Enums ===

/// Lifecycle state of a composition.
public enum CompositionState has drop, store {
    /// Created but not yet published.
    Initialized,
    /// Published and immutable.
    Published,
}

// === Events ===

/// Emitted once when the composition is published.
public struct CompositionPublishedEvent has copy, drop {
    composition_id: ID,
}

// === Public Functions ===

/// Creates the composition and its object-bound admin capability.
public fun new(ctx: &mut TxContext): (Composition, CompositionAdminCap) {
    let mut composition = Composition {
        id: object::new(ctx),
        state: CompositionState::Initialized,
    };
    let composition_id = object::id(&composition);
    let cap = CompositionAdminCap {
        id: claim(&mut composition.id, CompositionAdminCapKey()),
        composition_id,
    };
    (composition, cap)
}

/// Publishes the composition: shares it and freezes its embedded fields.
/// Aborts with `ENotInitializedState` unless `Initialized`.
public fun publish(
    mut self: Composition,
    cap: &CompositionAdminCap,
) {
    self.authorize(cap);
    match (&self.state) {
        CompositionState::Initialized => {
            self.state = CompositionState::Published;

            let composition_id = object::id(&self);

            transfer::share_object(self);

            emit(CompositionPublishedEvent {
                composition_id,
            });
        },
        _ => abort ENotInitializedState,
    }
}

/// Verifies that the admin capability belongs to this composition.
public fun authorize(self: &Composition, cap: &CompositionAdminCap) {
    assert!(object::id(self) == cap.composition_id, EUnauthorized);
}

// === View Functions ===

/// Read access to the composition's UID (dynamic fields).
public fun uid(self: &Composition): &UID {
    &self.id
}

/// Mutable access to the composition's UID, gated by the admin cap. Works in
/// any lifecycle state: dynamic fields are the extension surface and stay
/// mutable after publish. The `&mut UID` reaches every dynamic field on the
/// object, though a field keyed by a type private to another module can only
/// be added or removed through that module.
public fun uid_mut(
    self: &mut Composition,
    cap: &CompositionAdminCap,
): &mut UID {
    self.authorize(cap);
    &mut self.id
}

// === Test Functions ===

// State predicates are test-only: create-and-publish is atomic, so every
// composition a runtime caller can hold is `Published`.

#[test_only]
public fun is_initialized_state(self: &Composition): bool {
    match (&self.state) {
        CompositionState::Initialized => true,
        _ => false,
    }
}

#[test_only]
public fun is_published_state(self: &Composition): bool {
    match (&self.state) {
        CompositionState::Published => true,
        _ => false,
    }
}

#[test_only]
public fun published_state_bcs_bytes(): vector<u8> {
    to_bytes(&CompositionState::Published)
}

/// Unpacks a `CompositionPublishedEvent` (fields are module-private) for test assertions.
#[test_only]
public fun composition_published_event_fields(event: CompositionPublishedEvent): ID {
    let CompositionPublishedEvent { composition_id } = event;
    composition_id
}
