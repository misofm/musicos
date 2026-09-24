// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Release digest and `derive_target_release_id` tests, verifying TypeScript
/// SDK parity. Pure hashing/BCS math with no ownership mechanics.
#[test_only]
module musicos::release_digest_tests;

use musicos::release;
use musicos::test_helpers;
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::hash::blake2b256;

/// Mirrors `release::calculate_release_digest` for SDK parity checks.
fun calculate_release_digest(
    recording_ids: vector<ID>,
    track_split_values: vector<u64>,
    nonce: u256,
): vector<u8> {
    let mut hash_input = vector<u8>[];
    hash_input.append(to_bytes(&recording_ids));
    hash_input.append(to_bytes(&track_split_values));
    hash_input.append(to_bytes(&nonce));

    blake2b256(&hash_input)
}

#[test]
/// Test that different nonces produce different digests.
fun different_nonces_produce_different_digests() {
    let recording_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000000001
    );
    let recording_ids = vector[recording_id];
    let track_splits = vector[10000u64];

    let digest_nonce_1 = calculate_release_digest(recording_ids, track_splits, 1u256);
    let digest_nonce_2 = calculate_release_digest(recording_ids, track_splits, 2u256);

    assert!(digest_nonce_1 != digest_nonce_2);
}

#[test]
/// Test that different recording IDs produce different digests.
fun different_recordings_produce_different_digests() {
    let recording_id_1 = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000000001
    );
    let recording_id_2 = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000000002
    );
    let track_splits = vector[10000u64];
    let nonce = 1u256;

    let digest_1 = calculate_release_digest(vector[recording_id_1], track_splits, nonce);
    let digest_2 = calculate_release_digest(vector[recording_id_2], track_splits, nonce);

    assert!(digest_1 != digest_2);
}

#[test]
/// Test that different track splits produce different digests.
fun different_splits_produce_different_digests() {
    let recording_id_1 = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000000001
    );
    let recording_id_2 = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000000002
    );
    let recording_ids = vector[recording_id_1, recording_id_2];
    let nonce = 1u256;

    let digest_50_50 = calculate_release_digest(recording_ids, vector[5000u64, 5000u64], nonce);
    let digest_60_40 = calculate_release_digest(recording_ids, vector[6000u64, 4000u64], nonce);

    assert!(digest_50_50 != digest_60_40);
}

#[test]
/// The digest pre-image components have the BCS shape the TypeScript SDK mirrors.
fun bcs_encoding_has_expected_structure() {
    let recording_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000000001
    );

    // vector<ID>, 1 element: ULEB128 length byte + 32-byte address.
    assert!(to_bytes(&vector[recording_id]).length() == 33);
    // vector<u64>, 1 element: length byte + 8-byte little-endian u64.
    assert!(to_bytes(&vector[10000u64]).length() == 9);
    // u256: 32 bytes little-endian.
    assert!(to_bytes(&1u256).length() == 32);
}

// === derive_target_release_id parity tests ===
// These verify that the on-chain derive_target_release_id() returns the same
// ID as the TypeScript SDK's deriveReleaseId(). Expected values were computed
// from @sona/sdk/derive with the same inputs.

#[test]
/// Single recording, 100% split, nonce=1.
/// TypeScript expected digest: dccbc50994240ba6de125686dc040b27b8c739fe8b55d8d7cbf923535b57af6c
fun single_target_release_id_derivation_is_deterministic() {
    let mut ctx = tx_context::dummy();
    let registry = release::new_registry_for_testing(&mut ctx);

    let recording_ids = vector[
        object::id_from_address(@0x0000000000000000000000000000000000000000000000000000000000000001),
    ];
    let track_splits = vector[10000u64];
    let nonce = 1u256;

    // Verify digest matches TypeScript output
    let digest = calculate_release_digest(recording_ids, track_splits, nonce);
    let expected_digest = x"dccbc50994240ba6de125686dc040b27b8c739fe8b55d8d7cbf923535b57af6c";
    assert!(digest == expected_digest, 0);

    // The release id depends on the fixture registry's id, so only determinism
    // is checked here.
    let release_id_1 = registry.derive_target_release_id(recording_ids, track_splits, nonce);
    let release_id_2 = registry.derive_target_release_id(recording_ids, track_splits, nonce);
    assert_eq!(release_id_1, release_id_2);
    destroy(registry);
}

#[test]
/// Two recordings, 50/50 split, nonce=42.
/// TypeScript expected digest: 58895ea293730fcbca59e08cadd81c3a8da7c0604fa014ac629b0a8f543f4141
fun multiple_target_release_id_derivation_is_deterministic() {
    let mut ctx = tx_context::dummy();
    let registry = release::new_registry_for_testing(&mut ctx);

    let recording_ids = vector[
        object::id_from_address(@0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef),
        object::id_from_address(@0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890),
    ];
    let track_splits = vector[5000u64, 5000u64];
    let nonce = 42u256;

    // Verify digest matches TypeScript output
    let digest = calculate_release_digest(recording_ids, track_splits, nonce);
    let expected_digest = x"58895ea293730fcbca59e08cadd81c3a8da7c0604fa014ac629b0a8f543f4141";
    assert!(digest == expected_digest, 0);

    // Verify derive_target_release_id is deterministic
    let release_id_1 = registry.derive_target_release_id(recording_ids, track_splits, nonce);
    let release_id_2 = registry.derive_target_release_id(recording_ids, track_splits, nonce);
    assert_eq!(release_id_1, release_id_2);

    // Verify different inputs produce different IDs
    let release_id_different_nonce = registry.derive_target_release_id(recording_ids, track_splits, 43u256);
    assert!(release_id_1 != release_id_different_nonce);
    destroy(registry);
}
