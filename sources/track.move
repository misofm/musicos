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
    /// The recording on this track and the routing target for its revenue.
    recording_id: ID,
    /// This track's share of the release's revenue. All tracks in a release
    /// sum to 100%; downstream allocations belong to extensions.
    split_bps: BPS,
}

/// Recording-admin consent to include a track in one specific release.
/// Extensions may wrap consent for offers or escrow before release creation.
public struct TrackConsent has drop, store {
    release_id: ID,
    track: Track,
}

// === Public Functions ===

/// Consents to inclusion in a release at the given split.
/// The capability must belong to the recording. Consent may be discarded or
/// stored by an extension; release creation consumes it without retaining its ID.
public fun consent(
    recording: &Recording,
    cap: &RecordingAdminCap,
    release_id: ID,
    split_bps: u16,
): TrackConsent {
    recording.authorize(cap);
    TrackConsent {
        release_id,
        track: Track {
            recording_id: object::id(recording),
            split_bps: bps::new(split_bps),
        },
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

/// The release authorized by this consent.
public fun release_id(self: &TrackConsent): ID { self.release_id }

/// Read-only access to the consented recording and split.
public fun track(self: &TrackConsent): &Track { &self.track }

// === Package Functions ===

/// Consumes consent after checking the release identity.
public(package) fun into_track(self: TrackConsent, release_id: ID): Track {
    let TrackConsent { release_id: consented_release_id, track } = self;
    assert!(release_id == consented_release_id, EUnauthorizedAssignment);
    track
}

// === Test Functions ===

#[test_only]
public fun consent_for_testing(
    recording_id: ID,
    release_id: ID,
    split_bps: u16,
): TrackConsent {
    TrackConsent {
        release_id,
        track: Track { recording_id, split_bps: bps::new(split_bps) },
    }
}

#[test_only]
public fun set_release_id_for_testing(self: &mut TrackConsent, release_id: ID) {
    self.release_id = release_id;
}
