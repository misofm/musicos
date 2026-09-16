// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Composition share currency for production-constructor tests. Recording
/// shares live in separate fixture packages because each share type must be
/// named `<package>::share::Share` and can be registered only once.
#[test_only]
module musicos::share;

use sui::coin::TreasuryCap;
use sui::coin_registry::{Self, CoinRegistry};

/// The one share type this package can initialize (`::share::Share` suffix).
/// `coin_registry::new_currency` requires `key`; the type is only ever used
/// as a phantom parameter and is never instantiated.
public struct Share has key {
    id: UID,
}

/// Registers and shares the currency through production APIs. The caller
/// supplies the scenario's single registry and retrieves the shared currency
/// in a later transaction. A second registration of this type must abort.
public fun register(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<Share> {
    let (initializer, treasury_cap) = coin_registry::new_currency<Share>(
        registry,
        6,
        b"SHR".to_string(),
        b"Test Share".to_string(),
        b"".to_string(),
        b"".to_string(),
        ctx,
    );
    coin_registry::finalize_and_delete_metadata_cap(initializer, ctx);
    treasury_cap
}
