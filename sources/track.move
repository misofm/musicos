// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Represents a track on a release, linking a recording to its position
/// in the tracklist.
///
/// A `Track` is the minimal positioned (recording, revenue-share) pair:
/// - `recording_id` — the routing target for the track's revenue, and the
///   handle through which everything else about the track is reached: the
///   recording's share-type identity, its extension metadata, and — via the
///   recording's `composition_id` — its composition.
/// - `split_bps` — this track's share of the release's revenue; genuinely
///   release-specific and not derivable from the recording.
/// - `state` — the assign-once lifecycle that carries (then sheds) the
///   recording admin's target release commitment, made at creation; see
///   `TrackState`.
///
/// `Track` is intentionally monomorphic: a `Release` holds a `vector<Track>`
/// of tracks from many different recordings, so it cannot be generic over
/// their share types. It stores nothing derivable from the recording — not
/// its share type, its metadata, or its composition, whose single source of
/// truth is the recording's own immutable `composition_id`. Revenue routes to
/// the recording alone (the composition is paid through its recording-share
/// ownership), so no track consumer needs the composition to act.
module musicos::track;

use bps::bps::{Self, BPS};
use musicos::recording::{Recording, RecordingAdminCap};

// === Errors ===

/// Track's target release ID does not match the assigning release.
const EUnauthorizedAssignment: u64 = 0;
/// Track has already been assigned to a release.
const EAlreadyAssigned: u64 = 1;

// === Structs ===

/// A track on a release: a positioned pointer to a recording with a revenue split.
public struct Track has drop, store {
    /// Current state of the track.
    state: TrackState,
    /// ID of the recording on this track. The routing target for the track's
    /// revenue; also the handle a consumer uses to fetch the recording (whose
    /// type carries its share-type identity, and whose `composition_id` leads
    /// on to the composition and its share type).
    recording_id: ID,
    /// This track's share of the release's revenue, in basis points. All
    /// tracks in a release sum to 100%. The composition's cut is settled as
    /// recording-share ownership at recording creation, so it is not split out
    /// here — a track routes its full share to the recording.
    split_bps: BPS,
}

// === Enums ===

/// Lifecycle state of a track within a release. A track is born `Unassigned`,
/// carrying the target release id the consent committed to at creation (the
/// release id is a digest of the whole tracklist, so this is the recording
/// owner's consent to the exact release configuration). At publish the release
/// verifies the match and transitions the track to `Assigned`, which carries
/// no id — shedding the 32-byte commitment once it has served its purpose.
public enum TrackState has drop, store {
    /// Track has been created but not yet assigned to a release. Carries the
    /// target release id the consent committed to at creation.
    Unassigned(ID),
    /// Track has been assigned to its target release.
    Assigned,
}

// === Public Functions ===

/// Creates a new track: the recording admin's consent to that recording's
/// inclusion in a specific future release with an agreed split.
/// Requires the recording admin capability. No event: a `Track` has `drop`
/// and is not an object, so a creation event could announce a consent that is
/// then silently discarded, and indexers would be unable to distinguish
/// pending from dead. Pre-publish observability is the responsibility of
/// whatever wraps the track (see below).
///
/// ### What creating a track consents to
///
/// `target_release_id` is derived from the release digest, so targeting it
/// consents to that release's exact economics and membership: the ordered
/// list of `(recording, split)` pairs and the creator's nonce, nothing more.
/// Everything else about the release — title, artwork, credits, display
/// grouping — lives in the extension layer, not in core: it is chosen by the
/// release creator, before or after this track is created, and is not bound
/// by the digest. Presentation is trusted and publicly attributable, not
/// cryptographically committed.
///
/// The recording need not be `Published`: its admin can create tracks inside
/// the recording's own creating transaction (an `Initialized` recording
/// cannot escape that transaction, so across transactions tracks always
/// reference `Published`, shared recordings).
///
/// A `Track` has `store`, not `key`: it carries no identity of its own, so it
/// may be exercised synchronously in the same transaction that creates it, or
/// handed to an offer extension that wraps it in a real object with its own
/// identity. Withdrawal, expiry, and rejection are then whatever that
/// wrapping extension encodes — visible in its type, not in core.
///
/// `recording` shares its `RecordingShare` with the cap, which binds cap to
/// recording at compile time, and is read for its id: the monomorphic `Track`
/// must store the recording's *address* for revenue routing, and an address
/// cannot come from a phantom.
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
/// Aborts if the track is `Assigned`: an assigned track only exists inside
/// a published release, so its release is the object you fetched it from.
public fun target_release_id(self: &Track): ID {
    match (&self.state) {
        TrackState::Unassigned(target_release_id) => *target_release_id,
        TrackState::Assigned => abort EAlreadyAssigned,
    }
}

// === Package Functions ===

/// Assigns the track to a release by verifying the release UID matches
/// the track's target release ID. Can only be called once per track.
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

// The state predicates are test-only: a track's state is determined by where
// it came from. `assign` is package-only and runs solely inside release
// publish, and there is no extraction path — so a track read out of a (shared,
// therefore published) release is always `Assigned`, and a track anywhere else
// is always `Unassigned`. No runtime caller learns anything from asking which
// variant a track is in — these boolean predicates remain information-free —
// but the unassigned variant's payload, the target release id, is genuinely
// runtime-relevant (an offer extension reads it to route or validate a
// pending track), hence the public `target_release_id` accessor above.

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
