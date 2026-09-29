// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A recording placed on a release with a revenue split and explicit
/// recording-admin consent to the target release identity.
module musicos::track;

// === Imports ===

use bps::bps::{Self, BPS};
use musicos::recording::{Recording, RecordingAdminCap};

// === Errors ===

/// Track's target release ID does not match the assigning release.
const EUnauthorizedAssignment: u64 = 0;

// === Structs ===

/// A recording on a release with its revenue split.
public struct Track has drop, store {
    /// The release identity consented to by the recording admin.
    target_release_id: ID,
    /// The recording on this track and the routing target for its revenue.
    recording_id: ID,
    /// This track's share of the release's revenue. All tracks in a release
    /// sum to 100%; downstream allocations belong to extensions.
    split_bps: BPS,
}

// === Public Functions ===

/// Creates a track: the recording admin's consent to this recording's
/// inclusion in the release `target_release_id` (see `release` for what that
/// id commits to) at the given split. The recording need not be `Published`;
/// the cap must belong to this recording.
///
/// No event: a `Track` has `drop` and is not an object, so a creation event
/// could announce a consent that is then discarded. A track is consumed in
/// its creating transaction or wrapped by an offer extension, which then
/// owns withdrawal, expiry, and observability.
public fun new(
    cap: &RecordingAdminCap,
    recording: &Recording,
    target_release_id: ID,
    track_split_bps_value: u16,
): Track {
    recording.authorize(cap);
    Track {
        target_release_id,
        recording_id: object::id(recording),
        split_bps: bps::new(track_split_bps_value),
    }
}

// === View Functions ===

/// Returns the ID of the recording.
public fun recording_id(self: &Track): ID {
    self.recording_id
}

/// Returns this track's share of the release's revenue (in basis points).
public fun split_bps(self: &Track): BPS {
    self.split_bps
}

/// Returns the release identity consented to at creation, including after publication.
public fun target_release_id(self: &Track): ID {
    self.target_release_id
}

// === Package Functions ===

/// Verifies that the enclosing release matches the recording admin's consent.
public(package) fun validate_target(self: &Track, release_uid: &UID) {
    assert!(release_uid.to_inner() == self.target_release_id, EUnauthorizedAssignment);
}

// === Test Functions ===

#[test_only]
public fun new_for_testing(
    recording_id: ID,
    target_release_id: ID,
    split_bps_value: u16,
): Track {
    Track {
        target_release_id,
        recording_id,
        split_bps: bps::new(split_bps_value),
    }
}

#[test_only]
public fun set_target_release_id_for_testing(self: &mut Track, target_release_id: ID) {
    self.target_release_id = target_release_id;
}
