// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module musicos::track_tests;

use std::unit_test::assert_eq;
use sui::bcs;
use musicos::test_helpers;
use musicos::track;

#[test]
fun consent_unwraps_to_minimal_track() {
    let ctx = &mut tx_context::dummy();
    let recording_id = test_helpers::fake_id(ctx);
    let release_id = test_helpers::fake_id(ctx);
    let consent = track::consent_for_testing(recording_id, release_id, 5000);
    assert_eq!(consent.release_id(), release_id);
    assert_eq!(consent.track().recording_id(), recording_id);
    let track = consent.into_track(release_id);
    assert_eq!(track.recording_id(), recording_id);
    assert_eq!(track.split_bps().value(), 5000);
    let mut expected = bcs::to_bytes(&recording_id);
    expected.append(bcs::to_bytes(&5000u16));
    assert_eq!(bcs::to_bytes(&track), expected);
}

#[test, expected_failure(abort_code = track::EUnauthorizedAssignment)]
fun wrong_release_rejected() {
    let ctx = &mut tx_context::dummy();
    let rec_id = test_helpers::fake_id(ctx);
    let release_id = test_helpers::fake_id(ctx);
    let wrong_release_id = test_helpers::fake_id(ctx);
    let consent = track::consent_for_testing(rec_id, release_id, 10000);
    consent.into_track(wrong_release_id);
}
