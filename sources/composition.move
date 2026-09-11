// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Represents a musical composition (song, instrumental work) in musicos.
/// Compositions are the underlying written works that recordings are based on.
/// Each composition has its own share token for ownership distribution.
///
/// ### Key Features:
///
/// - Share token initialization with fixed supply (10M tokens, 6 decimals)
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
use std::string::String;
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

// Constraint errors (30-39)
/// Title exceeds maximum length.
const EMaxTitleLengthExceeded: u64 = 33;
/// String must not be empty.
const EEmptyString: u64 = 35;

// === Constants ===

/// Maximum length of a title in bytes.
const MAX_TITLE_LENGTH: u64 = 300;

// === Structs ===

/// A musical composition representing the underlying written work.
/// The phantom CompositionShare type parameter links to the share token.
public struct Composition<phantom CompositionShare> has key {
    /// Unique identifier for this composition.
    id: UID,
    /// Current lifecycle state.
    state: CompositionState,
    /// Primary title of the composition.
    title: String,
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
public enum CompositionState has copy, drop, store {
    /// Composition is initialized but not published.
    Initialized,
    /// Composition is published and immutable. Includes publication timestamp.
    Published(
        /// Timestamp (ms) when published.
        u64,
    ),
}

// === Events ===

/// Emitted once when a composition is created.
public struct CompositionCreatedEvent<phantom CompositionShare> has copy, drop {
    composition_id: address,
    composition_admin_cap_id: address,
    share_currency_id: address,
    consumed_treasury_cap_id: address,
    created_by: address,
    title_bytes: vector<u8>,
    royalty_rate_bps: u16,
    share_supply_before: u64,
    share_supply_after: u64,
    shares_returned: u64,
    share_decimals: u8,
    share_supply_fixed_after: bool,
}

/// Emitted once when a composition is published.
public struct CompositionPublishedEvent<phantom CompositionShare> has copy, drop {
    composition_id: address,
    composition_admin_cap_id: address,
    clock_id: address,
    title_bytes: vector<u8>,
    royalty_rate_bps: u16,
    published_at_ms: u64,
    shared_after: bool,
}

// === Public Functions ===

/// Creates a new composition with the given title and royalty rate.
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
/// Initializes share tokens (10M supply, 6 decimals) and returns:
/// - The composition object
/// - Admin capability for the owner
/// - Initial share token balance
public fun new<CompositionShare>(
    title: String,
    royalty_rate_bps: u16,
    share_currency: &mut Currency<CompositionShare>,
    mut share_treasury_cap: TreasuryCap<CompositionShare>,
    ctx: &mut TxContext,
): (
    Composition<CompositionShare>,
    CompositionAdminCap<CompositionShare>,
    Balance<CompositionShare>,
) {
    assert!(!title.is_empty(), EEmptyString);
    assert!(title.length() <= MAX_TITLE_LENGTH, EMaxTitleLengthExceeded);

    let title_bytes = title.substring(0, title.length()).into_bytes();
    let share_currency_id = object::id_address(share_currency);
    let consumed_treasury_cap_id = object::id_address(&share_treasury_cap);
    let share_decimals = share_currency.decimals();
    let share_supply_before = share_treasury_cap.supply().value();
    let created_by = ctx.sender();

    let mut composition = Composition<CompositionShare> {
        id: object::new(ctx),
        state: CompositionState::Initialized,
        title,
        royalty_rate: bps::new(royalty_rate_bps),
    };

    let composition_admin_cap = CompositionAdminCap<CompositionShare> {
        id: claim(&mut composition.id, CompositionAdminCapKey()),
    };

    let composition_shares = share::initialize<CompositionShare>(
        share_currency,
        share_treasury_cap,
    );

    let composition_id = object::id_address(&composition);
    let composition_admin_cap_id = object::id_address(&composition_admin_cap);
    let share_supply_after = composition_shares.value();
    let shares_returned = composition_shares.value();
    let share_supply_fixed_after = share_currency.is_supply_fixed();

    emit(CompositionCreatedEvent<CompositionShare> {
        composition_id,
        composition_admin_cap_id,
        share_currency_id,
        consumed_treasury_cap_id,
        created_by,
        title_bytes,
        royalty_rate_bps: royalty_rate_bps,
        share_supply_before,
        share_supply_after,
        shares_returned,
        share_decimals,
        share_supply_fixed_after,
    });

    (composition, composition_admin_cap, composition_shares)
}

/// Publishes the composition, making its embedded fields immutable.
/// Required State: Initialized
///
/// Note: core enforces no attribution requirement — credits live in the credits
/// extension and may be attached before or after publish via `uid_mut`.
public fun publish<CompositionShare>(
    mut self: Composition<CompositionShare>,
    cap: &CompositionAdminCap<CompositionShare>,
    clock: &Clock,
) {
    match (self.state) {
        CompositionState::Initialized => {
            let published_at_ms = clock.timestamp_ms();
            self.state = CompositionState::Published(published_at_ms);

            let composition_id = object::id_address(&self);
            let composition_admin_cap_id = object::id_address(cap);
            let clock_id = object::id_address(clock);
            let title_bytes = self.title.substring(0, self.title.length()).into_bytes();
            let royalty_rate_bps = self.royalty_rate.value();

            transfer::share_object(self);

            emit(CompositionPublishedEvent<CompositionShare> {
                composition_id,
                composition_admin_cap_id,
                clock_id,
                title_bytes,
                royalty_rate_bps,
                published_at_ms,
                shared_after: true,
            });
        },
        _ => abort ENotInitializedState,
    }
}

// === View Functions ===

/// Returns the primary title.
public fun title<CompositionShare>(self: &Composition<CompositionShare>): &String {
    &self.title
}

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
    match (self.state) {
        CompositionState::Initialized => true,
        _ => false,
    }
}

#[test_only]
public fun is_published_state<CompositionShare>(self: &Composition<CompositionShare>): bool {
    match (self.state) {
        CompositionState::Published(_) => true,
        _ => false,
    }
}

#[test_only]
public fun new_for_testing<CompositionShare>(
    title: String,
    royalty_rate_bps: u16,
    ctx: &mut TxContext,
): (Composition<CompositionShare>, CompositionAdminCap<CompositionShare>) {
    assert!(!title.is_empty(), EEmptyString);
    assert!(title.length() <= MAX_TITLE_LENGTH, EMaxTitleLengthExceeded);

    let mut composition = Composition<CompositionShare> {
        id: object::new(ctx),
        state: CompositionState::Initialized,
        title,
        royalty_rate: bps::new(royalty_rate_bps),
    };

    let composition_admin_cap = CompositionAdminCap<CompositionShare> {
        id: claim(&mut composition.id, CompositionAdminCapKey()),
    };

    (composition, composition_admin_cap)
}

/// Unpacks a `CompositionPublishedEvent` for test-side field assertions —
/// the event's field is module-private, so tests in another module need this
/// accessor to assert the full payload rather than just "an event fired".
#[test_only]
public fun composition_published_event_fields<CompositionShare>(
    event: CompositionPublishedEvent<CompositionShare>,
): (address, address, address, vector<u8>, u16, u64, bool) {
    let CompositionPublishedEvent {
        composition_id,
        composition_admin_cap_id,
        clock_id,
        title_bytes,
        royalty_rate_bps,
        published_at_ms,
        shared_after,
    } = event;
    (
        composition_id,
        composition_admin_cap_id,
        clock_id,
        title_bytes,
        royalty_rate_bps,
        published_at_ms,
        shared_after,
    )
}

/// Unpacks a `CompositionCreatedEvent` for test-side field assertions.
#[test_only]
public fun composition_created_event_fields<CompositionShare>(
    event: CompositionCreatedEvent<CompositionShare>,
): (address, address, address, address, address, vector<u8>, u16, u64, u64, u64, u8, bool) {
    let CompositionCreatedEvent {
        composition_id,
        composition_admin_cap_id,
        share_currency_id,
        consumed_treasury_cap_id,
        created_by,
        title_bytes,
        royalty_rate_bps,
        share_supply_before,
        share_supply_after,
        shares_returned,
        share_decimals,
        share_supply_fixed_after,
    } = event;
    (
        composition_id,
        composition_admin_cap_id,
        share_currency_id,
        consumed_treasury_cap_id,
        created_by,
        title_bytes,
        royalty_rate_bps,
        share_supply_before,
        share_supply_after,
        shares_returned,
        share_decimals,
        share_supply_fixed_after,
    )
}
