#[test_only]
module musicos::recording_tests;

use musicos::recording::{Self, Recording};
use musicos::test_helpers::{Self, RecordingShare, CompositionShare};
use std::unit_test::destroy;
use sui::clock;
use sui::test_scenario;

const OWNER: address = @0xA1;

/// Helper to create a test recording.
fun new_test_recording(ctx: &mut TxContext): (
    recording::Recording<RecordingShare>,
    recording::RecordingAdminCap<RecordingShare>,
) {
    recording::new_for_testing<RecordingShare>(test_helpers::fake_id(ctx), ctx)
}

// === Publish ===

/// `publish` shares the recording: publish in one transaction, re-fetch it
/// via `take_shared` in the next.
#[test]
fun test_publish_recording() {
    let mut scenario = test_scenario::begin(OWNER);
    let ctx = scenario.ctx();
    let (rec, cap) = new_test_recording(ctx);
    let clock = clock::create_for_testing(ctx);
    rec.publish(&cap, &clock); // shares the recording
    clock.destroy_for_testing();

    scenario.next_tx(OWNER);
    let rec = scenario.take_shared<Recording<RecordingShare>>();
    assert!(rec.is_published_state());
    test_scenario::return_shared(rec);

    destroy(cap);
    scenario.end();
}

// Id independence of recordings under one composition is covered by
// `production_constructor_tests`.
