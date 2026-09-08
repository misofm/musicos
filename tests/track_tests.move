// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `Track` has `drop, store` but not `key`: it is never an object, never owned,
/// never shared, and `assign` is `public(package)` — reachable only from
/// `release::publish` in production, or directly from any module in this
/// package in tests. There is no ownership mechanics to model here (no
/// sender, no `take_shared`/`take_from_sender`), so these remain
/// `tx_context::dummy()` unit tests exercising the state machine directly.
/// The double-assign and assign-after-read paths below are unreachable through
/// `release::publish` (a release can only ever be published once, and each of
/// its tracks assigned exactly once — see `post_publish_tests`), so they are
/// only reachable by calling the package-visible `assign` a second time
/// directly, as done here.
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
    let comp_id = test_helpers::fake_id(ctx);
    let rec_id = test_helpers::fake_id(ctx);
    let release_uid = object::new(ctx);
    let release_id = release_uid.to_inner();

    let mut t = track::new_for_testing(comp_id, rec_id, release_id, 10000);
    assert!(t.is_unassigned_state());

    track::assign(&mut t, &release_uid);

    assert!(t.is_assigned_state());
    assert!(!t.is_unassigned_state());

    destroy(t);
    release_uid.delete();
}

/// A track can only ever be assigned once: calling `assign` a second time —
/// even with the same matching release UID — aborts. In production this is
/// unreachable (a release publishes, and therefore assigns each of its
/// tracks, exactly once), so the second call here goes directly through the
/// package-visible `assign` rather than through `release::publish`.
#[test, expected_failure(abort_code = EAlreadyAssigned, location = musicos::track)]
fun assign_twice_aborts() {
    let ctx = &mut tx_context::dummy();
    let comp_id = test_helpers::fake_id(ctx);
    let rec_id = test_helpers::fake_id(ctx);
    let release_uid = object::new(ctx);
    let release_id = release_uid.to_inner();

    let mut t = track::new_for_testing(comp_id, rec_id, release_id, 10000);
    track::assign(&mut t, &release_uid);
    track::assign(&mut t, &release_uid); // already Assigned: aborts

    destroy(t);
    release_uid.delete();
}

/// `target_release_id` reads the pending commitment on an `Unassigned` track.
#[test]
fun target_release_id_reads_unassigned_commitment() {
    let ctx = &mut tx_context::dummy();
    let comp_id = test_helpers::fake_id(ctx);
    let rec_id = test_helpers::fake_id(ctx);
    let target_id = test_helpers::fake_id(ctx);

    let t = track::new_for_testing(comp_id, rec_id, target_id, 5000);
    assert_eq!(t.target_release_id(), target_id);

    destroy(t);
}

/// Once assigned, the 32-byte target-release commitment has served its
/// purpose and is shed: `target_release_id` aborts on an `Assigned` track.
/// An assigned track only ever exists inside the published release it came
/// from, so callers already have the answer from context — see the accessor's
/// doc comment in track.move.
#[test, expected_failure(abort_code = EAlreadyAssigned, location = musicos::track)]
fun target_release_id_on_assigned_track_aborts() {
    let ctx = &mut tx_context::dummy();
    let comp_id = test_helpers::fake_id(ctx);
    let rec_id = test_helpers::fake_id(ctx);
    let release_uid = object::new(ctx);
    let release_id = release_uid.to_inner();

    let mut t = track::new_for_testing(comp_id, rec_id, release_id, 10000);
    track::assign(&mut t, &release_uid);

    let _ = t.target_release_id(); // Assigned: aborts

    destroy(t);
    release_uid.delete();
}
