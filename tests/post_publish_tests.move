// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Post-publish immutability tests: every embedded-field mutator must abort on
/// a published (shared) object, while the dynamic-field extension surface
/// (`uid_mut`) must keep working — that asymmetry is the protocol's core
/// frozen-vs-evolvable contract.
#[test_only]
module musicos::post_publish_tests;

use musicos::composition::{Self, Composition, CompositionPublishedEvent};
use musicos::recording::{Self, Recording, RecordingPublishedEvent};
use musicos::release::{Self, Release, ReleasePublishedEvent};
use musicos::test_helpers::{Self, CompositionShare, RecordingShare};
use std::unit_test::{assert_eq, destroy};
use sui::dynamic_field;
use sui::event;
use sui::test_scenario;

const OWNER: address = @0xA1;
const STRANGER: address = @0x51;

// State errors mirrored from the core modules.
const ENotInitializedState: u64 = 10;
// Mirrors release::EUnauthorized (0).
const EUnauthorized: u64 = 0;

/// Publishes a minimal composition and returns its admin cap (object is shared).
fun publish_composition(
    scenario: &mut test_scenario::Scenario,
): composition::CompositionAdminCap<CompositionShare> {
    let ctx = scenario.ctx();
    let (comp, cap) =
        composition::new_for_testing<CompositionShare>(b"Song".to_string(), 1500, ctx);
    let comp_id = object::id(&comp);
    let mut clock = sui::clock::create_for_testing(ctx);
    sui::clock::set_for_testing(&mut clock, 4242);
    let clock_id = object::id(&clock).to_address();
    comp.publish(&cap, &clock);
    clock.destroy_for_testing();

    // Event payload captures the final immutable fields and shared-object linkage.
    let mut events = event::events_by_type<CompositionPublishedEvent<CompositionShare>>();
    assert_eq!(events.length(), 1);
    let (event_comp_id, event_cap_id, event_clock_id, title_bytes, rate_bps, published_at_ms, shared_after) =
        composition::composition_published_event_fields(events.pop_back());
    assert_eq!(event_comp_id, comp_id.to_address());
    assert_eq!(event_cap_id, object::id(&cap).to_address());
    assert_eq!(event_clock_id, clock_id);
    assert_eq!(title_bytes, b"Song");
    assert_eq!(rate_bps, 1500);
    assert_eq!(published_at_ms, 4242);
    assert!(shared_after);

    cap
}

/// Publishes a minimal recording and returns its admin cap (object is shared).
fun publish_recording(
    scenario: &mut test_scenario::Scenario,
): recording::RecordingAdminCap<RecordingShare> {
    let ctx = scenario.ctx();
    let composition_id = test_helpers::fake_id(ctx);
    let (rec, cap) = recording::new_for_testing<RecordingShare, CompositionShare>(
        composition_id,
        ctx,
    );
    let rec_id = object::id(&rec);
    let mut clock = sui::clock::create_for_testing(ctx);
    sui::clock::set_for_testing(&mut clock, 4343);
    let clock_id = object::id(&clock).to_address();
    rec.publish(&cap, &clock);
    clock.destroy_for_testing();

    // Event payload captures the recording/composition linkage and shared clock.
    let mut events = event::events_by_type<RecordingPublishedEvent<RecordingShare, CompositionShare>>();
    assert_eq!(events.length(), 1);
    let (event_rec_id, event_comp_id, event_cap_id, event_clock_id, published_at_ms, shared_after) =
        recording::recording_published_event_fields(events.pop_back());
    assert_eq!(event_rec_id, rec_id.to_address());
    assert_eq!(event_comp_id, composition_id.to_address());
    assert_eq!(event_cap_id, object::id(&cap).to_address());
    assert_eq!(event_clock_id, clock_id);
    assert_eq!(published_at_ms, 4343);
    assert!(shared_after);

    cap
}

/// Publishes a minimal release under the given title and returns its admin
/// cap and id (object is shared). Titled per-call so a test can create more
/// than one distinguishable shared `Release` and disambiguate them by id.
fun publish_titled_release(
    scenario: &mut test_scenario::Scenario,
    title: vector<u8>,
): (release::ReleaseAdminCap, ID) {
    let ctx = scenario.ctx();
    let composition_id = test_helpers::fake_id(ctx);
    let recording_id = test_helpers::fake_id(ctx);
    let (rel, cap) = release::new_for_testing(
        title.to_string(),
        vector[musicos::track::new_for_testing(
            composition_id,
            recording_id,
            test_helpers::fake_id(ctx),
            10000,
        )],
        ctx,
    );
    let rel_id = object::id(&rel);
    let mut clock = sui::clock::create_for_testing(ctx);
    sui::clock::set_for_testing(&mut clock, 4444);
    let clock_id = object::id(&clock).to_address();
    rel.publish(&cap, &clock);
    clock.destroy_for_testing();

    // Popping the most recent event is safe even when a test publishes more
    // than one release, since each publish appends exactly one event.
    let mut events = event::events_by_type<ReleasePublishedEvent>();
    assert!(!events.is_empty());
    let (event_rel_id, event_cap_id, event_clock_id, title_bytes, published_at_ms,
        composition_ids, recording_ids, track_split_bps, assigned_track_count, shared_after) =
        release::release_published_event_fields(events.pop_back());
    assert_eq!(event_rel_id, rel_id.to_address());
    assert_eq!(event_cap_id, object::id(&cap).to_address());
    assert_eq!(event_clock_id, clock_id);
    assert_eq!(title_bytes, title);
    assert_eq!(published_at_ms, 4444);
    assert_eq!(composition_ids, vector[composition_id.to_address()]);
    assert_eq!(recording_ids, vector[recording_id.to_address()]);
    assert_eq!(track_split_bps, vector[10000]);
    assert_eq!(assigned_track_count, 1);
    assert!(shared_after);

    (cap, rel_id)
}

/// Publishes a minimal release and returns its admin cap (object is shared).
fun publish_release(scenario: &mut test_scenario::Scenario): release::ReleaseAdminCap {
    let (cap, _rel_id) = publish_titled_release(scenario, b"Album");
    cap
}

// === Composition ===

#[test, expected_failure(abort_code = ENotInitializedState, location = musicos::composition)]
fun composition_publish_twice_aborts() {
    let mut scenario = test_scenario::begin(OWNER);
    let cap = publish_composition(&mut scenario);

    scenario.next_tx(OWNER);
    let comp = scenario.take_shared<Composition<CompositionShare>>();
    let clock = sui::clock::create_for_testing(scenario.ctx());
    comp.publish(&cap, &clock);

    clock.destroy_for_testing();
    destroy(cap);
    abort
}

/// The extension surface stays open after publish: `uid_mut` works on a
/// published composition and dynamic fields can be attached and read back.
#[test]
fun composition_uid_mut_works_after_publish() {
    let mut scenario = test_scenario::begin(OWNER);
    let cap = publish_composition(&mut scenario);

    scenario.next_tx(OWNER);
    let mut comp = scenario.take_shared<Composition<CompositionShare>>();
    assert!(comp.is_published_state());
    assert!(!comp.is_initialized_state());
    dynamic_field::add(comp.uid_mut(&cap), b"extension", 42u64);
    assert!(dynamic_field::exists(comp.uid(), b"extension"));
    assert!(*dynamic_field::borrow<vector<u8>, u64>(comp.uid(), b"extension") == 42);
    test_scenario::return_shared(comp);

    destroy(cap);
    scenario.end();
}

// === Recording ===

// Recording and Release carry no embedded-field mutators besides `publish`
// itself (naming lives in the metadata extension, everything else is fixed at
// construction), so post-publish immutability reduces to the publish-twice
// aborts below plus the uid_mut-stays-open tests.

#[test, expected_failure(abort_code = ENotInitializedState, location = musicos::recording)]
fun recording_publish_twice_aborts() {
    let mut scenario = test_scenario::begin(OWNER);
    let cap = publish_recording(&mut scenario);

    scenario.next_tx(OWNER);
    let rec = scenario.take_shared<Recording<RecordingShare, CompositionShare>>();
    let clock = sui::clock::create_for_testing(scenario.ctx());
    rec.publish(&cap, &clock);

    clock.destroy_for_testing();
    destroy(cap);
    abort
}

// === Release ===

#[test, expected_failure(abort_code = ENotInitializedState, location = musicos::release)]
fun release_publish_twice_aborts() {
    let mut scenario = test_scenario::begin(OWNER);
    let cap = publish_release(&mut scenario);

    scenario.next_tx(OWNER);
    let rel = scenario.take_shared<Release>();
    let clock = sui::clock::create_for_testing(scenario.ctx());
    rel.publish(&cap, &clock);

    clock.destroy_for_testing();
    destroy(cap);
    abort
}

/// Masters and other extensions attach to recordings after publish — the
/// dynamic-field surface must stay open while embedded fields are frozen.
#[test]
fun recording_uid_mut_works_after_publish() {
    let mut scenario = test_scenario::begin(OWNER);
    let cap = publish_recording(&mut scenario);

    scenario.next_tx(OWNER);
    let mut rec = scenario.take_shared<Recording<RecordingShare, CompositionShare>>();
    assert!(rec.is_published_state());
    assert!(!rec.is_initialized_state());
    dynamic_field::add(rec.uid_mut(&cap), b"master", 7u64);
    assert!(dynamic_field::exists(rec.uid(), b"master"));
    test_scenario::return_shared(rec);

    destroy(cap);
    scenario.end();
}

#[test]
fun release_uid_mut_works_after_publish() {
    let mut scenario = test_scenario::begin(OWNER);
    let cap = publish_release(&mut scenario);

    scenario.next_tx(OWNER);
    let mut rel = scenario.take_shared<Release>();
    assert!(rel.is_published_state());
    assert!(!rel.is_initialized_state());
    dynamic_field::add(rel.uid_mut(&cap), b"metadata", 9u64);
    assert!(dynamic_field::exists(rel.uid(), b"metadata"));
    test_scenario::return_shared(rel);

    destroy(cap);
    scenario.end();
}

/// The extension surface's authorization is unforgeable: a cap minted for a
/// different, unrelated release cannot open `uid_mut` on this one — even
/// after both are published and shared. This is the realistic production
/// shape of a wrong-cap attempt (`uid_mut` works in any lifecycle state, so
/// the interesting adversarial case is post-publish, cross-actor, not
/// pre-publish same-transaction).
#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun release_uid_mut_wrong_cap_aborts() {
    let mut scenario = test_scenario::begin(OWNER);
    let (owner_cap, owner_rel_id) = publish_titled_release(&mut scenario, b"Owner's Album");

    // STRANGER publishes and shares an entirely unrelated release, and holds
    // that release's own (validly-scoped) cap.
    scenario.next_tx(STRANGER);
    let (stranger_cap, _stranger_rel_id) =
        publish_titled_release(&mut scenario, b"Stranger's Album");

    // STRANGER now tries to open uid_mut on OWNER's release using their own
    // cap — disambiguated from STRANGER's own shared release by id.
    scenario.next_tx(STRANGER);
    let mut owner_rel = test_scenario::take_shared_by_id<Release>(&scenario, owner_rel_id);
    let _uid = owner_rel.uid_mut(&stranger_cap); // wrong cap: aborts EUnauthorized

    test_scenario::return_shared(owner_rel);
    destroy(owner_cap);
    destroy(stranger_cap);
    abort
}
