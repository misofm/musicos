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
use musicos::track;
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

/// The indexer hand-decodes state BCS: `Published` is variant tag 1 with no payload.
#[test]
fun published_state_bcs_layout_keeps_variant_tag() {
    let expected = vector[1u8];
    assert_eq!(composition::published_state_bcs_bytes(), expected);
    assert_eq!(recording::published_state_bcs_bytes(), expected);
    assert_eq!(release::published_state_bcs_bytes(), expected);
}

/// Publishes a minimal composition and returns its admin cap (object is shared).
fun publish_composition(
    scenario: &mut test_scenario::Scenario,
): composition::CompositionAdminCap<CompositionShare> {
    let ctx = scenario.ctx();
    let (comp, cap) = composition::new_for_testing<CompositionShare>(1500, ctx);
    let comp_id = object::id(&comp);
    comp.publish(&cap);

    // Event payload captures the identity and the immutable rate.
    let mut events = event::events_by_type<CompositionPublishedEvent<CompositionShare>>();
    assert_eq!(events.length(), 1);
    let (event_comp_id, rate_bps) =
        composition::composition_published_event_fields(events.pop_back());
    assert_eq!(event_comp_id, comp_id.to_address());
    assert_eq!(rate_bps, 1500);

    cap
}

/// Publishes a minimal recording and returns its admin cap (object is shared).
fun publish_recording(
    scenario: &mut test_scenario::Scenario,
): recording::RecordingAdminCap<RecordingShare> {
    let ctx = scenario.ctx();
    let composition_id = test_helpers::fake_id(ctx);
    let (rec, cap) = recording::new_for_testing<RecordingShare>(
        composition_id,
        ctx,
    );
    let rec_id = object::id(&rec);
    rec.publish(&cap);

    // Event payload captures the recording/composition linkage.
    let mut events = event::events_by_type<RecordingPublishedEvent<RecordingShare>>();
    assert_eq!(events.length(), 1);
    let (event_rec_id, event_comp_id) =
        recording::recording_published_event_fields(events.pop_back());
    assert_eq!(event_rec_id, rec_id.to_address());
    assert_eq!(event_comp_id, composition_id.to_address());

    cap
}

/// Publishes a minimal release and returns its admin cap and id (object is
/// shared). The id disambiguates when a test publishes several releases.
fun publish_release(scenario: &mut test_scenario::Scenario): (release::ReleaseAdminCap, ID) {
    let ctx = scenario.ctx();
    let recording_id = test_helpers::fake_id(ctx);
    let (rel, cap) = release::new_for_testing(
        vector[track::new_for_testing(
            recording_id,
            test_helpers::fake_id(ctx),
            10000,
        )],
        ctx,
    );
    let rel_id = object::id(&rel);
    rel.publish(&cap);

    // Each publish appends exactly one release event (after one track event
    // per track), so popping the latest is safe with several releases.
    let mut events = event::events_by_type<ReleasePublishedEvent>();
    assert!(!events.is_empty());
    let (event_rel_id, nonce) = release::release_published_event_fields(events.pop_back());
    assert_eq!(event_rel_id, rel_id.to_address());
    assert_eq!(nonce, 0);
    let mut track_events = event::events_by_type<release::ReleaseTrackAssignedEvent>();
    let (track_rel_id, position, event_recording, event_split) =
        release::release_track_assigned_event_fields(track_events.pop_back());
    assert_eq!(track_rel_id, rel_id.to_address());
    assert_eq!(position, 0);
    assert_eq!(event_recording, recording_id.to_address());
    assert_eq!(event_split, 10000);

    (cap, rel_id)
}

// === Composition ===

#[test, expected_failure(abort_code = ENotInitializedState, location = musicos::composition)]
fun composition_publish_twice_aborts() {
    let mut scenario = test_scenario::begin(OWNER);
    let cap = publish_composition(&mut scenario);

    scenario.next_tx(OWNER);
    let comp = scenario.take_shared<Composition<CompositionShare>>();
    comp.publish(&cap);

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

// Recording and Release have no embedded-field mutators besides `publish`, so
// immutability reduces to publish-twice aborts plus uid_mut-stays-open.

#[test, expected_failure(abort_code = ENotInitializedState, location = musicos::recording)]
fun recording_publish_twice_aborts() {
    let mut scenario = test_scenario::begin(OWNER);
    let cap = publish_recording(&mut scenario);

    scenario.next_tx(OWNER);
    let rec = scenario.take_shared<Recording<RecordingShare>>();
    rec.publish(&cap);

    destroy(cap);
    abort
}

// === Release ===

#[test, expected_failure(abort_code = ENotInitializedState, location = musicos::release)]
fun release_publish_twice_aborts() {
    let mut scenario = test_scenario::begin(OWNER);
    let (cap, _rel_id) = publish_release(&mut scenario);

    scenario.next_tx(OWNER);
    let rel = scenario.take_shared<Release>();
    rel.publish(&cap);

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
    let mut rec = scenario.take_shared<Recording<RecordingShare>>();
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
    let (cap, _rel_id) = publish_release(&mut scenario);

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

/// A cap minted for an unrelated release cannot open `uid_mut` on this one,
/// even after both are published and shared — the realistic cross-actor,
/// post-publish shape of a wrong-cap attempt.
#[test, expected_failure(abort_code = EUnauthorized, location = musicos::release)]
fun release_uid_mut_wrong_cap_aborts() {
    let mut scenario = test_scenario::begin(OWNER);
    let (owner_cap, owner_rel_id) = publish_release(&mut scenario);

    // STRANGER publishes an unrelated release and holds its cap.
    scenario.next_tx(STRANGER);
    let (stranger_cap, _stranger_rel_id) = publish_release(&mut scenario);

    // STRANGER tries to open uid_mut on OWNER's release with that cap.
    scenario.next_tx(STRANGER);
    let mut owner_rel = test_scenario::take_shared_by_id<Release>(&scenario, owner_rel_id);
    let _uid = owner_rel.uid_mut(&stranger_cap); // wrong cap: aborts EUnauthorized

    test_scenario::return_shared(owner_rel);
    destroy(owner_cap);
    destroy(stranger_cap);
    abort
}
