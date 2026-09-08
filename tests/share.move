// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Test-only `share` module so this package can mint one *real* share type:
/// `share::initialize` requires the type to be `<addr>::share::Share`, and a
/// package can have only one module named `share`. This is what lets the
/// production `composition::new` / `recording::new` constructors (which wire
/// `share::initialize`) be exercised in unit tests instead of only the
/// `*_for_testing` bypasses.
#[test_only]
module musicos::share;

use sui::coin::TreasuryCap;
use sui::coin_registry::{Self, Currency};

/// The one share type this package can initialize (`::share::Share` suffix).
/// `coin_registry::new_currency` requires `key`; the type is only ever used
/// as a phantom parameter and is never instantiated.
public struct Share has key {
    id: UID,
}

/// Creates a registered `Currency<Share>` + fresh `TreasuryCap<Share>` that
/// satisfy every `share::initialize` precondition: 6 decimals, metadata cap
/// deleted, zero supply.
public fun currency_for_testing(ctx: &mut TxContext): (Currency<Share>, TreasuryCap<Share>) {
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    let (initializer, treasury_cap) = coin_registry::new_currency<Share>(
        &mut registry,
        6,
        b"SHR".to_string(),
        b"Test Share".to_string(),
        b"".to_string(),
        b"".to_string(),
        ctx,
    );
    let (mut currency, metadata_cap) = coin_registry::finalize_unwrap_for_testing(initializer, ctx);
    currency.delete_metadata_cap(metadata_cap);
    std::unit_test::destroy(registry);
    (currency, treasury_cap)
}
