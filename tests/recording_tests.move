#[test_only]
module musicos::recording_tests;

use musicos::recording::{Self, Recording};
use musicos::test_helpers::{Self, RecordingShare, CompositionShare};
use std::unit_test::destroy;
use sui::test_scenario;

const OWNER: address = @0xA1;

/// Helper to create a test recording.
fun new_test_recording(ctx: &mut TxContext): (
    recording::Recording<RecordingShare, CompositionShare>,
    recording::RecordingAdminCap<RecordingShare>,
) {
    recording::new_for_testing<RecordingShare, CompositionShare>(test_helpers::fake_id(ctx), ctx)
}

// === Publish ===

/// `publish` shares the recording — an ownership-affecting op — so this runs
/// as a scenario: publish in one transaction, confirm the object is
/// genuinely shared and re-fetchable via `take_shared` in the next.
#[test]
fun test_publish_recording() {
    let mut scenario = test_scenario::begin(OWNER);
    let ctx = scenario.ctx();
    let (rec, cap) = new_test_recording(ctx);
    let clock = sui::clock::create_for_testing(ctx);
    rec.publish(&cap, &clock); // shares the recording
    clock.destroy_for_testing();

    scenario.next_tx(OWNER);
    let rec = scenario.take_shared<Recording<RecordingShare, CompositionShare>>();
    assert!(rec.is_published_state());
    test_scenario::return_shared(rec);

    destroy(cap);
    scenario.end();
}

// A recording carries no naming fields: its display title is its composition's
// title, read by reference, and richer naming lives in the metadata extension.
// Naming behavior is therefore untestable here by design.

// Recordings are independent objects (fresh `object::new`), not derived children
// keyed by a per-composition index: two recordings created under one composition
// have distinct ids and require no contiguity/derivation. Concurrency- and
// id-independence behavior is covered by `production_constructor_tests`.
