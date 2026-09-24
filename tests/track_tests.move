// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `Track` state-machine tests. A track is never an object and `assign` is
/// package-visible, so these call it directly; the double-assign path is
/// unreachable through `release::publish`, which assigns each track once.
#[test_only]
module musicos::track_tests;

use musicos::test_helpers;
use musicos::track;
use std::unit_test::{assert_eq, destroy};

// Error codes mirrored from track.move.
const EAlreadyAssigned: u64 = 1;

/// `assign` transitions `Unassigned(target) -> Assigned` when the release UID
/// matches the track's committed target.
#[test]
fun assign_transitions_unassigned_to_assigned() {
    let ctx = &mut tx_context::dummy();
    let rec_id = test_helpers::fake_id(ctx);
    let release_uid = object::new(ctx);
    let release_id = release_uid.to_inner();

    let mut t = track::new_for_testing(rec_id, release_id, 10000);
    assert!(t.is_unassigned_state());

    track::assign(&mut t, &release_uid);

    assert!(t.is_assigned_state());
    assert!(!t.is_unassigned_state());

    destroy(t);
    release_uid.delete();
}

/// A second `assign`, even with the same matching release UID, aborts.
#[test, expected_failure(abort_code = EAlreadyAssigned, location = musicos::track)]
fun assign_twice_aborts() {
    let ctx = &mut tx_context::dummy();
    let rec_id = test_helpers::fake_id(ctx);
    let release_uid = object::new(ctx);
    let release_id = release_uid.to_inner();

    let mut t = track::new_for_testing(rec_id, release_id, 10000);
    track::assign(&mut t, &release_uid);
    track::assign(&mut t, &release_uid); // already Assigned: aborts

    destroy(t);
    release_uid.delete();
}

/// `target_release_id` reads the pending commitment on an `Unassigned` track.
#[test]
fun target_release_id_reads_unassigned_commitment() {
    let ctx = &mut tx_context::dummy();
    let rec_id = test_helpers::fake_id(ctx);
    let target_id = test_helpers::fake_id(ctx);

    let t = track::new_for_testing(rec_id, target_id, 5000);
    assert_eq!(t.target_release_id(), target_id);

    destroy(t);
}

/// Once assigned, the target commitment is shed: `target_release_id` aborts
/// on an `Assigned` track.
#[test, expected_failure(abort_code = EAlreadyAssigned, location = musicos::track)]
fun target_release_id_on_assigned_track_aborts() {
    let ctx = &mut tx_context::dummy();
    let rec_id = test_helpers::fake_id(ctx);
    let release_uid = object::new(ctx);
    let release_id = release_uid.to_inner();

    let mut t = track::new_for_testing(rec_id, release_id, 10000);
    track::assign(&mut t, &release_uid);

    let _ = t.target_release_id(); // Assigned: aborts

    destroy(t);
    release_uid.delete();
}
