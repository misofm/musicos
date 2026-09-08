/// `release::new` construction/validation and `track::new` boundary checks.
/// None of these touch object ownership: `release::new` returns an
/// `Initialized` release by value with no `share_object`/`transfer` call, and
/// `track::new` returns a plain `Track` (`drop, store`, not `key`) — there is
/// no sender, shared object, or cross-transaction mechanics to model, so
/// these remain `tx_context::dummy()` unit tests. Ownership-flow behavior
/// (publish, take_shared, wrong-cap-by-a-different-actor) lives in
/// `post_publish_tests` and `release_e2e_tests`.
#[test_only]
module musicos::release_tests;

use musicos::composition;
use musicos::recording;
use musicos::release;
use musicos::test_helpers::{Self, CompositionShare, RecordingShare};
use musicos::track;
use std::unit_test::{assert_eq, destroy};

// Error codes from release.move
const EInvalidTrackSplitsSum: u64 = 20;
const EMaxTracksExceeded: u64 = 31;
const EMaxTitleLengthExceeded: u64 = 34;
const EEmptyString: u64 = 35;
const ENoTracks: u64 = 51;

// Must match release.move
const MAX_TRACKS: u64 = 255;
const MAX_TITLE_LENGTH: u64 = 300;

/// Helper to create a single test track.
fun test_track(ctx: &mut TxContext): track::Track {
    track::new_for_testing(
        test_helpers::fake_id(ctx),
        test_helpers::fake_id(ctx),
        test_helpers::fake_id(ctx),
        10000, // 100% split (single track)
    )
}

/// Helper to create an ordered tracklist of n tracks sharing splits evenly.
fun test_tracks(track_count: u64, split_bps: u16, ctx: &mut TxContext): vector<track::Track> {
    vector::tabulate!(track_count, |_index| track::new_for_testing(
        test_helpers::fake_id(ctx),
        test_helpers::fake_id(ctx),
        test_helpers::fake_id(ctx),
        split_bps,
    ))
}

/// Helper: a composition and a recording of it, with their admin caps.
fun composition_and_recording(
    ctx: &mut TxContext,
): (
    composition::Composition<CompositionShare>,
    composition::CompositionAdminCap<CompositionShare>,
    recording::Recording<RecordingShare, CompositionShare>,
    recording::RecordingAdminCap<RecordingShare>,
) {
    let (comp, comp_cap) =
        composition::new_for_testing<CompositionShare>(b"Song".to_string(), 1500, ctx);
    let (rec, rec_cap) =
        recording::new_for_testing<RecordingShare, CompositionShare>(object::id(&comp), ctx);
    (comp, comp_cap, rec, rec_cap)
}

// === Title Length ===

#[test, expected_failure(abort_code = EMaxTitleLengthExceeded, location = musicos::release)]
fun new_title_too_long_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut registry = release::new_registry_for_testing(ctx);
    let (rel, cap) = registry.new(
        test_helpers::long_string(MAX_TITLE_LENGTH + 1),
        vector[test_track(ctx)],
        0u256,
    );
    destroy(rel);
    destroy(cap);
    destroy(registry);
}

// === Max Tracks ===

#[test, expected_failure(abort_code = EMaxTracksExceeded, location = musicos::release)]
fun new_exceeds_max_tracks_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut registry = release::new_registry_for_testing(ctx);

    // MAX_TRACKS + 1 = 256 tracks in one flat tracklist.
    // Splits: 256 x 39 BPS = 9984; the first 16 get 40 BPS (16 extra = 10000).
    let tracks = vector::tabulate!(MAX_TRACKS + 1, |index| track::new_for_testing(
        test_helpers::fake_id(ctx),
        test_helpers::fake_id(ctx),
        test_helpers::fake_id(ctx),
        if (index < 16) 40 else 39,
    ));

    let (rel, cap) = registry.new(
        b"Too Many Tracks".to_string(),
        tracks,
        0u256,
    );
    destroy(rel);
    destroy(cap);
    destroy(registry);
}

/// Helper to create a minimal release.
fun test_release(ctx: &mut TxContext): (release::Release, release::ReleaseAdminCap) {
    release::new_for_testing(
        b"Album".to_string(),
        test_tracks(1, 10000, ctx),
        ctx,
    )
}

// === Creation Validation ===

#[test, expected_failure(abort_code = EEmptyString, location = musicos::release)]
fun new_empty_title_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut registry = release::new_registry_for_testing(ctx);
    let (rel, cap) = registry.new(
        b"".to_string(),
        vector[test_track(ctx)],
        0u256,
    );
    destroy(rel);
    destroy(cap);
    destroy(registry);
}

#[test, expected_failure(abort_code = ENoTracks, location = musicos::release)]
fun new_without_tracks_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut registry = release::new_registry_for_testing(ctx);
    let (rel, cap) = registry.new(
        b"Empty".to_string(),
        vector[],
        0u256,
    );
    destroy(rel);
    destroy(cap);
    destroy(registry);
}

#[test, expected_failure(abort_code = EInvalidTrackSplitsSum, location = musicos::release)]
fun new_with_splits_below_total_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut registry = release::new_registry_for_testing(ctx);
    let (rel, cap) = registry.new(
        b"Underweight".to_string(),
        test_tracks(1, 9999, ctx), // 99.99%
        0u256,
    );
    destroy(rel);
    destroy(cap);
    destroy(registry);
}

#[test, expected_failure(abort_code = EInvalidTrackSplitsSum, location = musicos::release)]
fun new_with_splits_above_total_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut registry = release::new_registry_for_testing(ctx);
    let (rel, cap) = registry.new(
        b"Overweight".to_string(),
        test_tracks(2, 5001, ctx), // 100.02%
        0u256,
    );
    destroy(rel);
    destroy(cap);
    destroy(registry);
}

/// The same digest (recording set + splits + nonce) can only ever be claimed
/// once under the same canonical registry.
#[test, expected_failure] // aborts in sui::derived_object on the duplicate claim
fun duplicate_digest_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut registry = release::new_registry_for_testing(ctx);
    let rec_id = test_helpers::fake_id(ctx);
    let rel_id = test_helpers::fake_id(ctx);

    let comp_id = test_helpers::fake_id(ctx);
    let (rel1, cap1) = registry.new(
        b"First".to_string(),
        vector[track::new_for_testing(comp_id, rec_id, rel_id, 10000)],
        7u256,
    );
    // Identical recording ids, splits, and nonce: identical digest.
    let (rel2, cap2) = registry.new(
        b"Second".to_string(),
        vector[track::new_for_testing(comp_id, rec_id, rel_id, 10000)],
        7u256,
    );
    destroy(rel1);
    destroy(cap1);
    destroy(rel2);
    destroy(cap2);
    destroy(registry);
}

// === Authorization ===

// The wrong-cap `uid_mut` abort (`EUnauthorized`) is exercised as a
// `test_scenario` in `post_publish_tests::release_uid_mut_wrong_cap_aborts`,
// against two published-and-shared releases and distinct senders (OWNER,
// STRANGER) — the realistic, cross-actor, post-publish shape. That
// supersedes an earlier same-transaction, dummy-ctx version of this check.

// === Views ===

#[test]
fun release_views_reflect_initialized_release() {
    let ctx = &mut tx_context::dummy();
    let (rel, cap) = test_release(ctx);

    assert!(rel.is_initialized_state());
    assert!(!rel.is_published_state());
    assert_eq!(*rel.title(), b"Album".to_string());
    assert_eq!(rel.tracks().length(), 1);
    assert_eq!(cap.release_id(), object::id(&rel));

    destroy(rel);
    destroy(cap);
}

// === track::new ===

/// `track::new` produces an `Unassigned` track carrying the target release id
/// and split it was called with, and reads the recording id off the
/// `&Recording` argument.
#[test]
fun track_new_creates_unassigned_track() {
    let ctx = &mut tx_context::dummy();
    let (comp, comp_cap, rec, rec_cap) = composition_and_recording(ctx);
    let target_release_id = test_helpers::fake_id(ctx);

    let t = track::new(&rec_cap, &rec, target_release_id, 10000);

    assert_eq!(t.recording_id(), object::id(&rec));
    assert_eq!(t.composition_id(), object::id(&comp));
    assert_eq!(t.split_bps().value(), 10000);
    assert_eq!(t.target_release_id(), target_release_id);
    assert!(t.is_unassigned_state());
    assert!(!t.is_assigned_state());

    destroy(t);
    destroy(comp);
    destroy(comp_cap);
    destroy(rec);
    destroy(rec_cap);
}

/// `bps::new` rejects a split above 100% (10,000 BPS) — the validation
/// `track::new` relies on when constructing `split_bps`.
#[test, expected_failure(abort_code = 0, location = bps::bps)] // bps EOverflow
fun track_new_split_above_100_percent_aborts() {
    let ctx = &mut tx_context::dummy();
    let (comp, comp_cap, rec, rec_cap) = composition_and_recording(ctx);

    let t = track::new(
        &rec_cap,
        &rec,
        test_helpers::fake_id(ctx),
        10001, // > 10_000 BPS
    );

    destroy(t);
    destroy(comp);
    destroy(comp_cap);
    destroy(rec);
    destroy(rec_cap);
}
