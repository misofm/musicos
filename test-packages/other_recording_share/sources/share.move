// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module other_recording_share::share;

use sui::coin::TreasuryCap;
use sui::coin_registry::{Self, CoinRegistry};

public struct Share has key { id: UID }

public fun register(registry: &mut CoinRegistry, ctx: &mut TxContext): TreasuryCap<Share> {
    let (initializer, treasury_cap) = coin_registry::new_currency<Share>(
        registry, 6, b"REC2".to_string(), b"Other Recording Share".to_string(),
        b"".to_string(), b"".to_string(), ctx,
    );
    coin_registry::finalize_and_delete_metadata_cap(initializer, ctx);
    treasury_cap
}
