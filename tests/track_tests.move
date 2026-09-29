// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module musicos::track_tests;

use std::unit_test::assert_eq;
use musicos::test_helpers;
use musicos::track;

#[test]
fun target_validation_preserves_consent() {
    let ctx = &mut tx_context::dummy();
    let rec_id = test_helpers::fake_id(ctx);
    let release_uid = object::new(ctx);
    let release_id = release_uid.to_inner();
    let t = track::new_for_testing(rec_id, release_id, 5000);
    t.validate_target(&release_uid);
    t.validate_target(&release_uid);
    assert_eq!(t.target_release_id(), release_id);
    assert_eq!(t.recording_id(), rec_id);
    assert_eq!(t.split_bps().value(), 5000);
    release_uid.delete();
}

#[test, expected_failure(abort_code = track::EUnauthorizedAssignment)]
fun wrong_target_rejected() {
    let ctx = &mut tx_context::dummy();
    let rec_id = test_helpers::fake_id(ctx);
    let target_id = test_helpers::fake_id(ctx);
    let wrong_release = object::new(ctx);
    let t = track::new_for_testing(rec_id, target_id, 10000);
    t.validate_target(&wrong_release);
    wrong_release.delete();
}
