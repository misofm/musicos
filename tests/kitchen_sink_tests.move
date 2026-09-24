/// Structural stress test: a 255-track release with exact-100% splits builds
/// and publishes through the registry. Core imposes no track limit of its
/// own; the ceiling is Sui's object, event and gas limits.
#[test_only]
module musicos::kitchen_sink_tests;

use musicos::release;
use musicos::test_helpers;
use musicos::track;
use std::unit_test::{assert_eq, destroy};
use sui::event;

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

    rel.publish(&rel_cap);
    destroy(rel_cap);
    let mut published_events = event::events_by_type<release::ReleasePublishedEvent>();
    assert_eq!(published_events.length(), 1);
    let (event_release_id, event_nonce) =
        release::release_published_event_fields(published_events.pop_back());
    assert_eq!(event_release_id, predicted_release_id);
    assert_eq!(event_nonce, nonce);

    let track_events = event::events_by_type<release::ReleaseTrackAssignedEvent>();
    assert_eq!(track_events.length(), 255);
    255u64.do!(|index| {
        let (release_id, position, recording_id, split_bps) =
            release::release_track_assigned_event_fields(track_events[index]);
        assert_eq!(release_id, predicted_release_id);
        assert_eq!(position, index);
        assert_eq!(recording_id, recording_ids[index]);
        assert_eq!(split_bps as u64, track_split_bps[index]);
    });

    destroy(registry);
}
