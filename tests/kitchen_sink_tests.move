/// Structural stress test: proves every bound (255 tracks, 300-byte title,
/// exact-100% splits) is achievable simultaneously and that the resulting
/// release still publishes. The only thing under test is whether construction
/// and `publish` abort at these bounds — there is no cross-transaction
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

// A recording kitchen-sink test used to exercise its naming fields at max
// bounds; recordings now carry no configurable embedded fields (naming lives
// in the metadata extension), so only the release retains structural bounds.

/// Kitchen sink test: creates a release with the structural fields at maximum
/// bounds.
/// - 255 tracks (MAX_TRACKS) in one flat tracklist
/// - Track splits sum to exactly 10000 BPS (55 x 40 + 200 x 39 = 10000)
/// - Title at 300 bytes (MAX_TITLE_LENGTH)
/// - Successfully publishes
#[test]
fun test_release_kitchen_sink() {
    let ctx = &mut tx_context::dummy();

    // Split math: 55 x 40 BPS + 200 x 39 BPS = 2200 + 7800 = 10000 BPS (100%)
    // Tracks are created with a dummy release_id; release::new_for_testing patches them.
    let dummy_release_id = test_helpers::fake_id(ctx);
    let tracks = vector::tabulate!(255, |index| track::new_for_testing(
        test_helpers::fake_id(ctx),
        test_helpers::fake_id(ctx),
        dummy_release_id,
        if (index < 55) 40 else 39,
    ));

    // Create release with max title.
    // new_for_testing patches all tracks to point to the real release ID.
    let (rel, rel_cap) = release::new_for_testing(
        test_helpers::long_string(300), // MAX_TITLE_LENGTH
        tracks,
        ctx,
    );

    // Publish - proves all max bounds are achievable together
    let clock = sui::clock::create_for_testing(ctx);
    rel.publish(&rel_cap, &clock);

    // Cleanup
    clock.destroy_for_testing();
    destroy(rel_cap);
}

/// The production constructor preserves all 255 track positions in the rich
/// Published event, including duplicate recording IDs and zero-valued splits.
#[test]
fun test_release_rich_event_arrays_at_max_tracks() {
    let ctx = &mut tx_context::dummy();
    let mut registry = release::new_registry_for_testing(ctx);
    let base_recording_ids = vector::tabulate!(255, |_| test_helpers::fake_id(ctx));
    let base_composition_ids = vector::tabulate!(255, |_| test_helpers::fake_id(ctx));
    let recording_ids = vector::tabulate!(255, |index| {
        if (index == 254) base_recording_ids[0] else base_recording_ids[index]
    });
    let composition_ids = vector::tabulate!(255, |index| {
        if (index == 254) base_composition_ids[0] else base_composition_ids[index]
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
        composition_ids[index],
        recording_ids[index],
        predicted_release_id,
        track_split_bps[index] as u16,
    ));
    let (rel, rel_cap) = registry.new(
        b"Max Rich Release".to_string(),
        tracks,
        nonce,
    );

    assert_eq!(event::events_by_type<release::ReleasePublishedEvent>().length(), 0);

    let clock = sui::clock::create_for_testing(ctx);
    rel.publish(&rel_cap, &clock);
    clock.destroy_for_testing();
    destroy(rel_cap);
    let mut published_events = event::events_by_type<release::ReleasePublishedEvent>();
    assert_eq!(published_events.length(), 1);
    assert!(sui::bcs::to_bytes(&published_events[0]).length() < 18000);
    let (
        event_release_id,
        _cap_id,
        _clock_id,
        _title,
        _published_at,
        assigned_track_count,
        shared_after,
        _registry_id,
        _digest,
        event_nonce,
        track_allocations,
    ) = release::release_published_event_fields(published_events.pop_back());
    assert_eq!(event_release_id, predicted_release_id.to_address());
    assert_eq!(assigned_track_count, 255);
    assert!(shared_after);
    assert_eq!(event_nonce, nonce);
    assert_eq!(track_allocations.length(), 255);
    assert_eq!(sui::bcs::to_bytes(&track_allocations).length(), 2 + 255 * 66);
    255u64.do!(|index| {
        let (composition_id, recording_id, split_bps) =
            release::track_allocation_fields(track_allocations[index]);
        assert_eq!(composition_id, composition_ids[index].to_address());
        assert_eq!(recording_id, recording_ids[index].to_address());
        assert_eq!(split_bps as u64, track_split_bps[index]);
    });

    destroy(registry);
}
