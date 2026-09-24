// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Represents a musical composition (song, instrumental work) in musicos.
/// Compositions are the underlying written works that recordings are based on.
/// Each composition has its own share token for ownership distribution.
///
/// ### Key Features:
///
/// - Share token initialization with fixed supply (100M tokens, 6 decimals)
/// - State machine: Initialized -> Published (embedded fields immutable after
///   publish; dynamic fields remain extensible via `uid_mut`)
/// - Deterministic addresses via derived object pattern
///
/// Attribution (credits) is intentionally NOT part of core: it is
/// display-oriented, varies across platforms, and is never read by the
/// economics. It lives in a first-party credits extension attached via
/// `uid_mut`, so core takes no dependency on an identity package and core
/// publish enforces no attribution.
///
/// The same rule governs naming: a composition carries no title. A title has
/// more than one correct rendering — translations, alternate titles,
/// corrections — which makes it presentation, and presentation lives in the
/// metadata extension, never in the frozen core. The economics never read a
/// name. Core stores what a composition *is*: its identity, its share type,
/// and the royalty rate it earns from recordings; extensions describe it.
///
/// ### Lifecycle and trust model
///
/// A composition is `key`-only with no `drop`: a fresh `Initialized` object
/// cannot be transferred, wrapped, publicly shared, or discarded, and its only
/// by-value consumer is `publish`. Create-and-publish is therefore atomic by
/// construction — an `Initialized` composition cannot outlive its creating
/// transaction, and every composition that exists on-chain is `Published` and
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
module musicos::composition;

use bps::bps::{Self, BPS};
use share::share;
use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin::TreasuryCap;
use sui::coin_registry::Currency;
use sui::derived_object::claim;
use sui::event::emit;

// === Errors ===

// State errors (10-19)
/// Operation requires Initialized state but composition is in a different state.
const ENotInitializedState: u64 = 10;

// === Structs ===

/// A musical composition representing the underlying written work.
/// The phantom CompositionShare type parameter links to the share token.
public struct Composition<phantom CompositionShare> has key {
    /// Unique identifier for this composition.
    id: UID,
    /// Current lifecycle state.
    state: CompositionState,
    /// Royalty rate this composition earns from each recording's revenue.
    royalty_rate: BPS,
}

/// Capability that authorizes modifications to a specific composition.
/// Initialized when a composition is registered and transferred to the owner.
/// Address is derived from the composition for client-side discoverability.
public struct CompositionAdminCap<phantom CompositionShare> has key, store {
    /// Unique identifier for this capability.
    id: UID,
}

/// Key for deriving the admin capability's deterministic address from the composition.
public struct CompositionAdminCapKey() has copy, drop, store;

// === Enums ===

/// Lifecycle state of a composition.
public enum CompositionState has drop, store {
    /// Composition is initialized but not published. Carries nothing:
    /// everything `publish` needs is an embedded field or a `publish`
    /// argument.
    Initialized,
    /// Composition is published and immutable. Includes publication timestamp.
    Published(
        /// Timestamp (ms) when published.
        u64,
    ),
}

// === Events ===

/// Emitted once when a composition is published.
///
/// The payload is deliberately minimal. A field is carried only if an indexer
/// reading musicos events alone would otherwise need an object lookup to
/// obtain it and it matters to the business: the composition's identity, its
/// immutable royalty rate, and when it was published. Everything else about
/// the publication is derivable without a lookup — the share type from the
/// event's type argument; the sender from the transaction envelope; the share
/// currency and consumed treasury cap ids from the `share::ShareInitializedEvent`
/// emitted in the same transaction; the admin cap id as the derived address of
/// `composition_id` under `CompositionAdminCapKey`; and the share supply
/// (100M · 10^6, 6 decimals, zero before, fixed after, returned in full to the
/// creator) from `share::initialize`'s constants.
public struct CompositionPublishedEvent<phantom CompositionShare> has copy, drop {
    composition_id: address,
    royalty_rate_bps: u16,
    published_at_ms: u64,
}

// === Public Functions ===

/// Creates a new composition with the given royalty rate.
///
/// The rate is set once, here, and is immutable for the composition's
/// lifetime: it is a permanent standing offer that recorders and share buyers
/// can price against without trusting the admin. The protocol imposes no
/// opinion on it beyond the arithmetic bound of 100% (10000 bps, enforced by
/// `bps::new`). There is no floor — 0% is permitted (e.g. a generative
/// recording with no authored composition) — and no protocol ceiling: an
/// uncompetitive rate simply attracts no recordings. What rate is reasonable
/// is a client-side concern; per-deal deviations settle as voluntary share
/// transfers after recording creation.
/// Initializes share tokens (100M supply, 6 decimals) and returns:
/// - The composition object
/// - Admin capability for the owner
/// - Initial share token balance
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

/// Publishes the composition, making its embedded fields immutable.
/// Required State: Initialized
///
/// Note: core enforces no attribution requirement — credits live in the credits
/// extension and may be attached before or after publish via `uid_mut`.
public fun publish<CompositionShare>(
    mut self: Composition<CompositionShare>,
    _: &CompositionAdminCap<CompositionShare>,
    clock: &Clock,
) {
    match (&self.state) {
        CompositionState::Initialized => {
            let published_at_ms = clock.timestamp_ms();
            self.state = CompositionState::Published(published_at_ms);

            let composition_id = object::id_address(&self);
            let royalty_rate_bps = self.royalty_rate.value();

            transfer::share_object(self);

            emit(CompositionPublishedEvent<CompositionShare> {
                composition_id,
                royalty_rate_bps,
                published_at_ms,
            });
        },
        _ => abort ENotInitializedState,
    }
}

// === View Functions ===

/// Returns the royalty rate this composition earns from each recording.
/// Immutable for the composition's lifetime — the value read here is, by
/// construction, the value `recording::new` will apply.
public fun royalty_rate<CompositionShare>(self: &Composition<CompositionShare>): BPS {
    self.royalty_rate
}

/// Returns a reference to the composition's UID for reading dynamic fields.
public fun uid<CompositionShare>(self: &Composition<CompositionShare>): &UID {
    &self.id
}

/// Returns a mutable reference to the composition's UID.
/// Requires the admin capability. Works in any lifecycle state — dynamic
/// fields are the extension surface and stay admin-mutable after publish;
/// only the embedded fields are frozen. The reference is root over every
/// dynamic field on the object, including fields attached by other
/// extensions.
public fun uid_mut<CompositionShare>(
    self: &mut Composition<CompositionShare>,
    _: &CompositionAdminCap<CompositionShare>,
): &mut UID {
    &mut self.id
}

// === Test Functions ===

// The state predicates are test-only: create-and-publish is atomic (see the
// module doc), so every composition any runtime caller can hold is `Published`
// — the answer is known a priori and a public accessor would carry no
// information. Tests still need them to verify the transition itself.

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
        CompositionState::Published(_) => true,
        _ => false,
    }
}

#[test_only]
public fun published_state_bcs_bytes(timestamp_ms: u64): vector<u8> {
    sui::bcs::to_bytes(&CompositionState::Published(timestamp_ms))
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

/// Unpacks a `CompositionPublishedEvent` for test-side field assertions —
/// the event's fields are module-private, so tests in another module need this
/// accessor to assert the payload rather than just "an event fired".
#[test_only]
public fun composition_published_event_fields<CompositionShare>(
    event: CompositionPublishedEvent<CompositionShare>,
): (address, u16, u64) {
    let CompositionPublishedEvent {
        composition_id,
        royalty_rate_bps,
        published_at_ms,
    } = event;
    (composition_id, royalty_rate_bps, published_at_ms)
}
