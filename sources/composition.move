// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A musical composition: the underlying written work that recordings are
/// based on, with its own fixed-supply share token (100M, 6 decimals).
///
/// Core stores what a composition *is* — identity, share type, and the
/// royalty rate it earns from recordings. Everything else (title, credits)
/// is presentation and lives in extensions attached via `uid_mut`; core
/// publish enforces no attribution.
///
/// Lifecycle: `Initialized -> Published`. A composition is `key`-only with no
/// `drop` and `publish` is its sole by-value consumer, so create-and-publish
/// is atomic: an `Initialized` object cannot outlive its creating transaction
/// and every composition on-chain is `Published` and shared.
///
/// Embedded fields freeze at publish; dynamic fields stay admin-mutable
/// forever via `uid_mut`. Integrators should model the cap holder as able to
/// mutate or delete extension data at any time.
module musicos::composition;

use bps::bps::{Self, BPS};
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
/// Operation requires Initialized state but composition is in a different state.
const ENotInitializedState: u64 = 10;

// === Structs ===

/// The underlying written work; `CompositionShare` is its share token type.
public struct Composition<phantom CompositionShare> has key {
    id: UID,
    /// Current lifecycle state.
    state: CompositionState,
    /// Royalty rate this composition earns from each recording's revenue.
    /// Immutable; see `new`.
    royalty_rate: BPS,
}

/// Authorizes admin operations on one composition. Its address is derived
/// from the composition under `CompositionAdminCapKey`.
public struct CompositionAdminCap<phantom CompositionShare> has key, store {
    id: UID,
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

/// Emitted once when a composition is published: identity and immutable
/// royalty rate. The publish time is the event's transaction timestamp.
/// Everything else (share type, sender, currency and treasury cap ids, admin
/// cap address, share supply) is derivable from the transaction and the
/// same-transaction `share::ShareInitializedEvent`.
public struct CompositionPublishedEvent<phantom CompositionShare> has copy, drop {
    composition_id: ID,
    royalty_rate_bps: u16,
}

// === Public Functions ===

/// Creates a composition with the given royalty rate and initializes its
/// share token (100M supply, 6 decimals). Returns the composition, its admin
/// cap, and the full initial share balance.
///
/// The rate is immutable and bounded only by `bps::new` (0–10000 bps): 0% is
/// allowed and there is no protocol ceiling. Whether a rate is reasonable is
/// a client-side concern; per-deal deviations settle as voluntary share
/// transfers after recording creation.
public fun new<CompositionShare>(
    royalty_rate_bps: u16,
    share_currency: &mut Currency<CompositionShare>,
    share_treasury_cap: TreasuryCap<CompositionShare>,
    ctx: &mut TxContext,
): (
    Composition<CompositionShare>,
    CompositionAdminCap<CompositionShare>,
    Balance<CompositionShare>,
) {
    let mut composition = Composition<CompositionShare> {
        id: object::new(ctx),
        state: CompositionState::Initialized,
        royalty_rate: bps::new(royalty_rate_bps),
    };

    let composition_admin_cap = CompositionAdminCap<CompositionShare> {
        id: claim(&mut composition.id, CompositionAdminCapKey()),
    };

    let composition_shares = share::initialize<CompositionShare>(
        share_currency,
        share_treasury_cap,
    );

    (composition, composition_admin_cap, composition_shares)
}

/// Publishes the composition: shares it and freezes its embedded fields.
/// Aborts with `ENotInitializedState` unless `Initialized`.
public fun publish<CompositionShare>(
    mut self: Composition<CompositionShare>,
    _: &CompositionAdminCap<CompositionShare>,
) {
    match (&self.state) {
        CompositionState::Initialized => {
            self.state = CompositionState::Published;

            let composition_id = object::id(&self);
            let royalty_rate_bps = self.royalty_rate.value();

            transfer::share_object(self);

            emit(CompositionPublishedEvent<CompositionShare> {
                composition_id,
                royalty_rate_bps,
            });
        },
        _ => abort ENotInitializedState,
    }
}

// === View Functions ===

/// The composition's immutable royalty rate — the rate `recording::new` applies.
public fun royalty_rate<CompositionShare>(self: &Composition<CompositionShare>): BPS {
    self.royalty_rate
}

/// Read access to the composition's UID (dynamic fields).
public fun uid<CompositionShare>(self: &Composition<CompositionShare>): &UID {
    &self.id
}

/// Mutable access to the composition's UID, gated by the admin cap. Works in
/// any lifecycle state: dynamic fields are the extension surface and stay
/// mutable after publish. The `&mut UID` reaches every dynamic field on the
/// object, though a field keyed by a type private to another module can only
/// be added or removed through that module.
public fun uid_mut<CompositionShare>(
    self: &mut Composition<CompositionShare>,
    _: &CompositionAdminCap<CompositionShare>,
): &mut UID {
    &mut self.id
}

// === Test Functions ===

// State predicates are test-only: create-and-publish is atomic, so every
// composition a runtime caller can hold is `Published`.

#[test_only]
public fun is_initialized_state<CompositionShare>(self: &Composition<CompositionShare>): bool {
    match (&self.state) {
        CompositionState::Initialized => true,
        _ => false,
    }
}

#[test_only]
public fun is_published_state<CompositionShare>(self: &Composition<CompositionShare>): bool {
    match (&self.state) {
        CompositionState::Published => true,
        _ => false,
    }
}

#[test_only]
public fun published_state_bcs_bytes(): vector<u8> {
    to_bytes(&CompositionState::Published)
}

#[test_only]
public fun new_for_testing<CompositionShare>(
    royalty_rate_bps: u16,
    ctx: &mut TxContext,
): (Composition<CompositionShare>, CompositionAdminCap<CompositionShare>) {
    let mut composition = Composition<CompositionShare> {
        id: object::new(ctx),
        state: CompositionState::Initialized,
        royalty_rate: bps::new(royalty_rate_bps),
    };

    let composition_admin_cap = CompositionAdminCap<CompositionShare> {
        id: claim(&mut composition.id, CompositionAdminCapKey()),
    };

    (composition, composition_admin_cap)
}

/// Unpacks a `CompositionPublishedEvent` (fields are module-private) for test assertions.
#[test_only]
public fun composition_published_event_fields<CompositionShare>(
    event: CompositionPublishedEvent<CompositionShare>,
): (ID, u16) {
    let CompositionPublishedEvent { composition_id, royalty_rate_bps } = event;
    (composition_id, royalty_rate_bps)
}
