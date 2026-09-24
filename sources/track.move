// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A track: a recording placed on a release with a revenue split. `Track` is
/// the minimal `(recording, split)` pair plus an assign-once state carrying
/// the target release id consented to at creation.
///
/// `Track` is monomorphic — a `Release` holds tracks from many recordings —
/// and stores nothing derivable from the recording: its share type, metadata,
/// and composition are reached through `recording_id`. Revenue routes to the
/// recording alone; the composition is paid through the recording shares it
/// owns.
module musicos::track;

use bps::bps::{Self, BPS};
use musicos::recording::{Recording, RecordingAdminCap};

// === Errors ===

/// Track's target release ID does not match the assigning release.
const EUnauthorizedAssignment: u64 = 0;
/// Track has already been assigned to a release.
const EAlreadyAssigned: u64 = 1;

// === Structs ===

/// A recording on a release with its revenue split.
public struct Track has drop, store {
    /// Assign-once lifecycle; see `TrackState`.
    state: TrackState,
    /// The recording on this track and the routing target for its revenue.
    recording_id: ID,
    /// This track's share of the release's revenue. All tracks in a release
    /// sum to 100%; the composition's cut is not split out here.
    split_bps: BPS,
}

// === Enums ===

/// A track is born `Unassigned` with the target release id its creator
/// consented to; `release::publish` verifies the match and moves it to
/// `Assigned`, shedding the id.
public enum TrackState has drop, store {
    /// Not yet assigned; carries the consented target release id.
    Unassigned(ID),
    /// Assigned to its target release.
    Assigned,
}

// === Public Functions ===

/// Creates a track: the recording admin's consent to this recording's
/// inclusion in one specific future release with the given split. The
/// recording need not be `Published`; `recording` shares its type with the
/// cap and supplies the id the monomorphic track stores.
///
/// `target_release_id` is derived from the release digest, so creating a
/// track consents to exactly that release's ordered `(recording, split)`
/// pairs and nonce — nothing else. Title, artwork, credits, and grouping are
/// extension data chosen by the release creator, not bound by the digest.
///
/// No event: a `Track` has `drop` and is not an object, so a creation event
/// could announce a consent that is then discarded. A track is consumed in
/// its creating transaction or wrapped by an offer extension, which then
/// owns withdrawal, expiry, and observability.
public fun new<RecordingShare>(
    _: &RecordingAdminCap<RecordingShare>,
    recording: &Recording<RecordingShare>,
    target_release_id: ID,
    track_split_bps_value: u16,
): Track {
    Track {
        state: TrackState::Unassigned(target_release_id),
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

/// Returns the target release id this track's creator consented to.
/// Aborts with `EAlreadyAssigned` if the track is `Assigned`: such a track
/// only exists inside a published release, so its release is already known.
public fun target_release_id(self: &Track): ID {
    match (&self.state) {
        TrackState::Unassigned(target_release_id) => *target_release_id,
        TrackState::Assigned => abort EAlreadyAssigned,
    }
}

// === Package Functions ===

/// Assigns the track to a release whose UID matches its target. Aborts with
/// `EUnauthorizedAssignment` on a mismatch and `EAlreadyAssigned` if called twice.
public(package) fun assign(self: &mut Track, release_uid: &UID) {
    match (&self.state) {
        TrackState::Unassigned(target_release_id) => {
            assert!(release_uid.to_inner() == *target_release_id, EUnauthorizedAssignment);
            self.state = TrackState::Assigned;
        },
        TrackState::Assigned => abort EAlreadyAssigned,
    }
}

// === Test Functions ===

// State predicates are test-only: a track inside a (published) release is
// always `Assigned`, and a track anywhere else is always `Unassigned`.

#[test_only]
public fun is_assigned_state(self: &Track): bool {
    match (&self.state) { TrackState::Assigned => true, _ => false }
}

#[test_only]
public fun is_unassigned_state(self: &Track): bool {
    match (&self.state) { TrackState::Unassigned(_) => true, _ => false }
}

#[test_only]
public fun new_for_testing(
    recording_id: ID,
    target_release_id: ID,
    split_bps_value: u16,
): Track {
    Track {
        state: TrackState::Unassigned(target_release_id),
        recording_id,
        split_bps: bps::new(split_bps_value),
    }
}

#[test_only]
public fun set_target_release_id_for_testing(self: &mut Track, target_release_id: ID) {
    self.state = TrackState::Unassigned(target_release_id);
}
