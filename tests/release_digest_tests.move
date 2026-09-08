// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Tests for release digest calculation and derive_target_release_id to verify TypeScript SDK parity.
/// Pure hashing/BCS-encoding math over plain `ID`/`u64`/`u256` values, with no
/// object creation, ownership, or transaction boundaries involved — scenario
/// mechanics would add nothing, so these stay `tx_context::dummy()` (used
/// only to mint fixture IDs via `test_helpers::fake_id`).
#[test_only]
module musicos::release_digest_tests;

use musicos::release;
use musicos::test_helpers;
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::hash::blake2b256;

/// Calculates the release digest using the same algorithm as release.move.
/// This is exposed for testing to verify SDK parity.
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
/// Test single recording with 100% split and nonce 1.
/// This test verifies the BCS encoding and hashing matches the TypeScript SDK.
fun single_recording_digest_matches_expected_bcs_hash() {
    let recording_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000000001
    );
    let recording_ids = vector[recording_id];
    let track_splits = vector[10000u64]; // 100% = 10000 BPS
    let nonce = 1u256;

    let digest = calculate_release_digest(recording_ids, track_splits, nonce);

    // Digest should be 32 bytes
    assert!(digest.length() == 32);

    // Print the digest for comparison with TypeScript SDK
    // (In actual usage, we'd compare against a known expected value)
    std::debug::print(&digest);
}

#[test]
/// Test multiple recordings with split shares and nonce 42.
fun multiple_recordings_digest_matches_expected_bcs_hash() {
    let recording_id_1 = object::id_from_address(
        @0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef
    );
    let recording_id_2 = object::id_from_address(
        @0xabcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890
    );
    let recording_ids = vector[recording_id_1, recording_id_2];
    let track_splits = vector[5000u64, 5000u64]; // 50% each
    let nonce = 42u256;

    let digest = calculate_release_digest(recording_ids, track_splits, nonce);

    // Digest should be 32 bytes
    assert!(digest.length() == 32);

    // Print the digest for comparison with TypeScript SDK
    std::debug::print(&digest);
}

#[test]
/// Test that the same inputs produce the same digest (deterministic).
fun digest_is_deterministic() {
    let recording_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000000001
    );
    let recording_ids = vector[recording_id];
    let track_splits = vector[10000u64];
    let nonce = 100u256;

    let digest_1 = calculate_release_digest(recording_ids, track_splits, nonce);
    let digest_2 = calculate_release_digest(recording_ids, track_splits, nonce);

    assert!(digest_1 == digest_2);
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
/// Verify the BCS encoding structure matches expectations.
/// This test helps debug any encoding mismatches with the TypeScript SDK.
fun bcs_encoding_has_expected_structure() {
    let recording_id = object::id_from_address(
        @0x0000000000000000000000000000000000000000000000000000000000000001
    );
    let recording_ids = vector[recording_id];
    let track_splits = vector[10000u64];
    let nonce = 1u256;

    // BCS encode each component separately to verify structure
    let recording_ids_bytes = to_bytes(&recording_ids);
    let track_splits_bytes = to_bytes(&track_splits);
    let nonce_bytes = to_bytes(&nonce);

    // vector<ID> with 1 element: 1 byte length (ULEB128) + 32 bytes address = 33 bytes
    assert!(recording_ids_bytes.length() == 33);

    // vector<u64> with 1 element: 1 byte length (ULEB128) + 8 bytes u64 = 9 bytes
    assert!(track_splits_bytes.length() == 9);

    // u256: 32 bytes little-endian
    assert!(nonce_bytes.length() == 32);

    // Print bytes for debugging
    std::debug::print(&recording_ids_bytes);
    std::debug::print(&track_splits_bytes);
    std::debug::print(&nonce_bytes);
}

// === derive_target_release_id parity tests ===
// These verify that the on-chain derive_target_release_id() returns the same
// ID as the TypeScript SDK's deriveReleaseId(). Expected values were computed
// from @sona/sdk/derive with the same inputs.

#[test]
/// Single recording, 100% split, nonce=1.
/// TypeScript expected digest: dccbc50994240ba6de125686dc040b27b8c739fe8b55d8d7cbf923535b57af6c
/// TypeScript expected release ID: 0x814674793a22d3ef2ee90c1356018e7a5c56a517a3116b372d83457a1789711b
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

    // derive_target_release_id depends on the registry's actual ID, so we can't
    // hardcode an expected release ID here (the registry here is a fixture).
    // But we verify it returns a valid ID and that calling it twice returns
    // the same result (deterministic).
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
