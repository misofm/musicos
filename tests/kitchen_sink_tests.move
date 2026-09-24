/// Structural stress test: proves a large tracklist (255 tracks) with
/// exact-100% splits is achievable and that the resulting release still
/// publishes. Core imposes no track limit of its own — the ceiling is Sui's
/// object, event and gas limits. The only thing under test is whether
/// construction and `publish` abort at this size — there is no cross-transaction
/// re-fetch or sender-dependent behavior to assert on the shared object
/// afterward, so this stays a single `tx_context::dummy()` transaction rather
/// than a `test_scenario`.
#[test_only]
module musicos::kitchen_sink_tests;

use musicos::release;
use musicos::test_helpers;
use musicos::track;
use std::unit_test::{assert_eq, destroy};
use sui::event;

// === Tests ===

// Recording and release kitchen-sink tests used to exercise their naming
// fields at max bounds; core objects now carry no naming fields (titles live
// in the metadata extensions), so only the release's tracklist retains
// structural bounds.

/// Kitchen sink test: creates a release with a large tracklist.
/// - 255 tracks in one flat tracklist
/// - Track splits sum to exactly 10000 BPS (55 x 40 + 200 x 39 = 10000)
/// - Successfully publishes
#[test]
fun test_release_kitchen_sink() {
    let ctx = &mut tx_context::dummy();

    // Split math: 55 x 40 BPS + 200 x 39 BPS = 2200 + 7800 = 10000 BPS (100%)
    // Tracks are created with a dummy release_id; release::new_for_testing patches them.
    let dummy_release_id = test_helpers::fake_id(ctx);
    let tracks = vector::tabulate!(255, |index| track::new_for_testing(
        test_helpers::fake_id(ctx),
        dummy_release_id,
        if (index < 55) 40 else 39,
    ));

    // new_for_testing patches all tracks to point to the real release ID.
    let (rel, rel_cap) = release::new_for_testing(tracks, ctx);

    // Publish - proves a large tracklist with exact splits publishes
    let clock = sui::clock::create_for_testing(ctx);
    rel.publish(&rel_cap, &clock);

    // Cleanup
    clock.destroy_for_testing();
    destroy(rel_cap);
}

/// Publishing a 255-track release emits one `ReleaseTrackAssignedEvent` per
/// position, in order, including duplicate recording IDs and zero-valued
/// splits, followed by a single `ReleasePublishedEvent`.
#[test]
fun test_release_track_events_at_255_tracks() {
    let ctx = &mut tx_context::dummy();
    let mut registry = release::new_registry_for_testing(ctx);
    let base_recording_ids = vector::tabulate!(255, |_| test_helpers::fake_id(ctx));
    let recording_ids = vector::tabulate!(255, |index| {
        if (index == 254) base_recording_ids[0] else base_recording_ids[index]
    });
    let track_split_bps = vector::tabulate!(255, |index| {
        if (index == 0) 0 else if (index == 254) 79 else if (index < 55) 40 else 39
    });

    let nonce = 7u256;
    let predicted_release_id = registry.derive_target_release_id(
        recording_ids,
        track_split_bps,
        nonce,
    );
    let tracks = vector::tabulate!(255, |index| track::new_for_testing(
        recording_ids[index],
        predicted_release_id,
        track_split_bps[index] as u16,
    ));
    let (rel, rel_cap) = registry.new(tracks, nonce);

    assert_eq!(event::events_by_type<release::ReleasePublishedEvent>().length(), 0);

    let clock = sui::clock::create_for_testing(ctx);
    rel.publish(&rel_cap, &clock);
    clock.destroy_for_testing();
    destroy(rel_cap);
    let mut published_events = event::events_by_type<release::ReleasePublishedEvent>();
    assert_eq!(published_events.length(), 1);
    let (event_release_id, _published_at, event_nonce) =
        release::release_published_event_fields(published_events.pop_back());
    assert_eq!(event_release_id, predicted_release_id.to_address());
    assert_eq!(event_nonce, nonce);

    let track_events = event::events_by_type<release::ReleaseTrackAssignedEvent>();
    assert_eq!(track_events.length(), 255);
    255u64.do!(|index| {
        let (release_id, position, recording_id, split_bps) =
            release::release_track_assigned_event_fields(track_events[index]);
        assert_eq!(release_id, predicted_release_id.to_address());
        assert_eq!(position, index);
        assert_eq!(recording_id, recording_ids[index].to_address());
        assert_eq!(split_bps as u64, track_split_bps[index]);
    });

    destroy(registry);
}
