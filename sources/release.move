// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// A music release: an ordered, flat tracklist with per-track revenue splits.
/// Title, cover art, credits, and disc/side grouping are presentation and
/// live in extensions. The core/extension split, atomic create-and-publish,
/// and `uid_mut` trust model are as described in `composition`.
///
/// ### Consent scope
///
/// The release id is derived under the canonical `ReleaseRegistry` from a
/// digest of the ordered `(recording, split)` pairs and the creator's nonce.
/// A `Track` commits to that id at creation, consenting to exactly the
/// release's economics and membership and nothing else; the stored tracklist
/// has the digest pre-image's shape, so nothing is chosen after consent.
///
/// The id also commits to the registry's UID, so every pending track depends
/// on that namespace staying reachable. `ReleaseRegistry` is therefore
/// created and shared exactly once at package initialization, with no
/// constructor, deletion path, or mutable UID accessor.
module musicos::release;

use bps::bps;
use musicos::track::Track;
use sui::bcs::to_bytes;
use sui::clock::Clock;
use sui::derived_object::{Self, claim};
use sui::event::emit;
use sui::hash::blake2b256;

// === Errors ===

// Authorization errors (0-9)
/// The provided admin capability does not match this release.
const EUnauthorized: u64 = 0;

// State errors (10-19)
/// Operation requires Initialized state.
const ENotInitializedState: u64 = 10;

// Validation errors (20-29)
/// Track splits don't sum to 100% (10,000 BPS).
const EInvalidTrackSplitsSum: u64 = 20;

// Reference errors (50-59)
/// Release must contain at least one track.
const ENoTracks: u64 = 51;

// === Structs ===

/// A music release: an ordered flat tracklist with per-track revenue splits.
public struct Release has key {
    id: UID,
    /// Current lifecycle state.
    state: ReleaseState,
    /// The ordered tracklist; same shape as the digest pre-image every
    /// track's creator consented to.
    tracks: vector<Track>,
}

/// The canonical derivation parent for every release. Its private UID is
/// reachable only by `new`, so the namespace cannot be bypassed.
public struct ReleaseRegistry has key {
    id: UID,
}

/// Key for release UID derivation.
public struct ReleaseKey(vector<u8>) has copy, drop, store;

/// Authorizes admin operations on one release.
public struct ReleaseAdminCap has key, store {
    id: UID,
    /// ID of the release this capability controls.
    release_id: ID,
}

// Derivation key for ReleaseAdminCap.
public struct ReleaseAdminCapKey() has copy, drop, store;

// === Enums ===

/// Lifecycle state of a release.
public enum ReleaseState has drop, store {
    /// Created but not yet published. Carries the creator's nonce, a digest
    /// input `publish` reports and cannot otherwise reach.
    Initialized {
        nonce: u256,
    },
    /// Published and immutable.
    Published(
        /// Timestamp (ms) when published.
        u64,
    ),
}

// === Events ===

/// Emitted once per track when a release is published, in tracklist order and
/// before the `ReleasePublishedEvent`. Together the track events are the
/// release's full allocation, duplicates and zero splits included. The
/// track's composition is not repeated: join `recording_id` to that
/// recording's `RecordingPublishedEvent`.
public struct ReleaseTrackAssignedEvent has copy, drop {
    release_id: address,
    /// Zero-based position of the track in the tracklist.
    position: u64,
    recording_id: address,
    split_bps: u16,
}

/// Emitted once when a release is published, after its track events:
/// identity, timestamp, and the creator's nonce. Everything else (sender,
/// admin cap address, track count, registry id, and the digest — see
/// `calculate_release_digest`) is derivable from the transaction and the
/// same-transaction events.
public struct ReleasePublishedEvent has copy, drop {
    release_id: address,
    published_at_ms: u64,
    nonce: u256,
}

/// Emitted once at package initialization with the canonical registry's id.
public struct ReleaseRegistryCreatedEvent has copy, drop {
    registry_id: address,
}

// === Method Aliases ===

public use fun release_admin_cap_release_id as ReleaseAdminCap.release_id;
public use fun release_registry_id as ReleaseRegistry.id;

// === Public Functions ===

/// Creates and shares the one canonical registry. There is no production
/// constructor: this object is the permanent namespace every release commits to.
fun init(ctx: &mut TxContext) {
    let registry = ReleaseRegistry { id: object::new(ctx) };
    let registry_id = object::id_address(&registry);

    transfer::share_object(registry);

    emit(ReleaseRegistryCreatedEvent { registry_id });
}

/// Assembles a release under the canonical registry. Permissionless: consent
/// is carried by the tracks, each created for this exact derived id. Returns
/// the release and admin cap by value so `publish` can follow in the same
/// PTB. Aborts with `ENoTracks` on an empty tracklist and
/// `EInvalidTrackSplitsSum` unless splits sum to 10,000 bps; claiming an
/// already-claimed digest aborts in `derived_object`.
public fun new(
    self: &mut ReleaseRegistry,
    tracks: vector<Track>,
    nonce: u256,
): (Release, ReleaseAdminCap) {
    assert!(!tracks.is_empty(), ENoTracks);

    let (recording_ids, track_split_values, split_sum) = extract_digest_inputs(&tracks);
    assert!(split_sum == (bps::denominator!() as u64), EInvalidTrackSplitsSum);

    let release_digest = calculate_release_digest(recording_ids, track_split_values, nonce);
    let release_uid = claim(&mut self.id, ReleaseKey(release_digest));
    let mut release = Release {
        id: release_uid,
        state: ReleaseState::Initialized { nonce },
        tracks,
    };

    let release_admin_cap = ReleaseAdminCap {
        id: claim(&mut release.id, ReleaseAdminCapKey()),
        release_id: object::id(&release),
    };

    (release, release_admin_cap)
}

/// Derives the release id `new` would claim for these inputs, without
/// creating a release. Read-only registry access, so it parallelizes.
public fun derive_target_release_id(
    self: &ReleaseRegistry,
    recording_ids: vector<ID>,
    track_split_values: vector<u64>,
    nonce: u256,
): ID {
    let release_digest = calculate_release_digest(recording_ids, track_split_values, nonce);
    derived_object::derive_address(self.id.to_inner(), ReleaseKey(release_digest)).to_id()
}

/// The canonical registry's object id — the derivation parent used by `new`
/// and `derive_target_release_id`. Exposed as the `ReleaseRegistry.id()` method.
public fun release_registry_id(self: &ReleaseRegistry): ID {
    self.id.to_inner()
}

/// Publishes the release: verifies every track targets this release (emitting
/// one `ReleaseTrackAssignedEvent` each), shares it, and emits
/// `ReleasePublishedEvent`. Aborts with `EUnauthorized` on a mismatched cap
/// and `ENotInitializedState` unless `Initialized`.
public fun publish(mut self: Release, cap: &ReleaseAdminCap, clock: &Clock) {
    self.authorize(cap);

    match (&self.state) {
        ReleaseState::Initialized { nonce } => {
            let nonce = *nonce;
            // Verifies each track's target and emits one track event per track.
            self.assign_tracks();

            let published_at_ms = clock.timestamp_ms();

            self.state = ReleaseState::Published(published_at_ms);

            let release_id = object::id_address(&self);

            transfer::share_object(self);

            emit(ReleasePublishedEvent {
                release_id,
                published_at_ms,
                nonce,
            });
        },
        _ => abort ENotInitializedState,
    }
}

/// Verifies that the admin capability matches this release.
public fun authorize(self: &Release, cap: &ReleaseAdminCap) {
    assert!(object::id(self) == cap.release_id, EUnauthorized);
}

// === View Functions ===

/// The ordered tracklist — the single accessor for length, membership, and
/// per-track data.
public fun tracks(self: &Release): &vector<Track> {
    &self.tracks
}

/// Returns the release ID associated with the admin capability.
public fun release_admin_cap_release_id(cap: &ReleaseAdminCap): ID {
    cap.release_id
}

/// Read access to the release's UID (dynamic fields).
public fun uid(self: &Release): &UID {
    &self.id
}

/// Mutable access to the release's UID, gated by the admin cap. Works in any
/// lifecycle state; see `composition::uid_mut` for the trust model.
public fun uid_mut(self: &mut Release, cap: &ReleaseAdminCap): &mut UID {
    self.authorize(cap);
    &mut self.id
}

/// Recording ids, split values, and split sum, in tracklist order: the digest
/// pre-image is the stored shape.
fun extract_digest_inputs(tracks: &vector<Track>): (vector<ID>, vector<u64>, u64) {
    let recording_ids = tracks.map_ref!(|track| track.recording_id());
    // bps::value() returns u16; widen to u64 to preserve digest format.
    let track_split_values = tracks.map_ref!(|track| track.split_bps().value() as u64);
    let split_sum = track_split_values.fold!(0u64, |accumulator, value| accumulator + value);

    (recording_ids, track_split_values, split_sum)
}

/// The release digest:
/// `blake2b256(bcs(recording_ids) || bcs(split_bps as u64) || bcs(nonce))`.
/// The release id is this digest's derived address under the registry
/// (`ReleaseKey`).
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

/// Assigns every track to this release (verifying its target) and emits one
/// `ReleaseTrackAssignedEvent` per track in tracklist order.
fun assign_tracks(self: &mut Release) {
    let release_id = self.id.to_address();
    let mut position = 0;
    self.tracks.do_mut!(|track| {
        track.assign(&self.id);
        emit(ReleaseTrackAssignedEvent {
            release_id,
            position,
            recording_id: track.recording_id().to_address(),
            split_bps: track.split_bps().value(),
        });
        position = position + 1;
    });
}

// === Test Functions ===

/// Runs the real module initializer, creating and sharing the canonical registry.
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

/// Creates an unshared registry for pure validation and derivation tests.
#[test_only]
public fun new_registry_for_testing(ctx: &mut TxContext): ReleaseRegistry {
    ReleaseRegistry { id: object::new(ctx) }
}

/// Unpacks the initialization event for test assertions.
#[test_only]
public fun release_registry_created_event_fields(event: ReleaseRegistryCreatedEvent): address {
    let ReleaseRegistryCreatedEvent { registry_id } = event;
    registry_id
}

/// Unpacks a `ReleasePublishedEvent` (fields are module-private) for test assertions.
#[test_only]
public fun release_published_event_fields(
    event: ReleasePublishedEvent,
): (address, u64, u256) {
    let ReleasePublishedEvent { release_id, published_at_ms, nonce } = event;
    (release_id, published_at_ms, nonce)
}

// State predicates are test-only: create-and-publish is atomic, so every
// release a runtime caller can hold is `Published`.

#[test_only]
public fun is_initialized_state(self: &Release): bool {
    match (&self.state) {
        ReleaseState::Initialized { .. } => true,
        _ => false,
    }
}

#[test_only]
public fun is_published_state(self: &Release): bool {
    match (&self.state) {
        ReleaseState::Published(_) => true,
        _ => false,
    }
}

#[test_only]
public fun published_state_bcs_bytes(timestamp_ms: u64): vector<u8> {
    to_bytes(&ReleaseState::Published(timestamp_ms))
}

#[test_only]
public fun new_for_testing(
    tracks: vector<Track>,
    ctx: &mut TxContext,
): (Release, ReleaseAdminCap) {
    use musicos::track;

    let mut release = Release {
        id: object::new(ctx),
        state: ReleaseState::Initialized { nonce: 0 },
        tracks,
    };

    // Patch all tracks to target this release so publish() can assign them.
    let release_id = object::id(&release);
    release.tracks.do_mut!(|t| track::set_target_release_id_for_testing(t, release_id));

    let release_admin_cap = ReleaseAdminCap {
        id: claim(&mut release.id, ReleaseAdminCapKey()),
        release_id: object::id(&release),
    };

    (release, release_admin_cap)
}

#[test_only]
public fun release_track_assigned_event_fields(
    event: ReleaseTrackAssignedEvent,
): (address, u64, address, u16) {
    let ReleaseTrackAssignedEvent { release_id, position, recording_id, split_bps } = event;
    (release_id, position, recording_id, split_bps)
}
