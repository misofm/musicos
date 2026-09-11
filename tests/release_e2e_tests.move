// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// End-to-end test of the production release flow across transaction
/// boundaries and actors, through the canonical shared `ReleaseRegistry`:
///
/// 1. A songwriter publishes a composition.
/// 2. An artist publishes a recording of it.
/// 3. The artist consents to the *predicted* release id (digest-derived via
///    `derive_target_release_id`) by calling `track::new` directly with the
///    recording admin capability — there is no separable authorization
///    object to negotiate over or hand off; that is now an offer extension's
///    job.
/// 4. A label creates the release through `release::new` (claiming the
///    digest-derived UID from the canonical registry) and publishes it — which verifies
///    every track was aimed at exactly this release.
/// 5. Anyone can read the published release and its assigned track.
#[test_only]
module musicos::release_e2e_tests;

use musicos::composition::{Self, Composition};
use musicos::recording::{Self, Recording};
use musicos::release::{Self, Release, ReleaseRegistry};
use musicos::test_helpers::{Self, CompositionShare, RecordingShare};
use musicos::track;
use std::unit_test::{assert_eq, destroy};
use sui::bcs::to_bytes;
use sui::event;
use sui::hash::blake2b256;
use sui::test_scenario;

const SONGWRITER: address = @0xA1;
const ARTIST: address = @0xA2;
const LABEL: address = @0xA3;
const READER: address = @0xBEEF;

const ROYALTY_RATE_BPS: u16 = 1500;
const NONCE: u256 = 42;

fun expected_digest(recording_ids: vector<ID>, track_split_bps: vector<u64>, nonce: u256): vector<u8> {
    let mut bytes = vector<u8>[];
    bytes.append(to_bytes(&recording_ids));
    bytes.append(to_bytes(&track_split_bps));
    bytes.append(to_bytes(&nonce));
    blake2b256(&bytes)
}

/// The package initializer creates and shares the only production registry,
/// with an event whose registry id matches the shared object.
#[test]
fun init_creates_shared_registry_and_emits_event() {
    let mut scenario = test_scenario::begin(SONGWRITER);
    release::init_for_testing(scenario.ctx());

    let mut events = event::events_by_type<release::ReleaseRegistryCreatedEvent>();
    assert_eq!(events.length(), 1);
    let (event_registry_id, created_by, shared_after) =
        release::release_registry_created_event_fields(events.pop_back());
    assert_eq!(created_by, SONGWRITER);
    assert!(shared_after);

    scenario.next_tx(READER);
    let registry = scenario.take_shared<ReleaseRegistry>();
    assert_eq!(registry.id().to_address(), event_registry_id);
    test_scenario::return_shared(registry);
    scenario.end();
}

#[test]
fun full_track_release_flow_publishes_at_derived_id() {
    let mut scenario = test_scenario::begin(SONGWRITER);
    release::init_for_testing(scenario.ctx());

    // === Tx 1 (SONGWRITER): create and publish the composition ===
    scenario.next_tx(SONGWRITER);
    let (comp, comp_cap) = composition::new_for_testing<CompositionShare>(
        b"Song".to_string(),
        ROYALTY_RATE_BPS,
        scenario.ctx(),
    );
    let clock = sui::clock::create_for_testing(scenario.ctx());
    comp.publish(&comp_cap, &clock); // shares the composition
    clock.destroy_for_testing();
    destroy(comp_cap);

    // === Tx 2 (ARTIST): create and publish a recording of it ===
    scenario.next_tx(ARTIST);
    let comp = scenario.take_shared<Composition<CompositionShare>>();
    let (rec, rec_cap) = recording::new_for_testing<RecordingShare, CompositionShare>(
        object::id(&comp),
        scenario.ctx(),
    );
    let clock = sui::clock::create_for_testing(scenario.ctx());
    rec.publish(&rec_cap, &clock); // shares the recording
    clock.destroy_for_testing();
    test_scenario::return_shared(comp);

    // === Tx 3 (ARTIST): consent to the predicted release id via track::new ===
    scenario.next_tx(ARTIST);
    let comp = scenario.take_shared<Composition<CompositionShare>>();
    let rec = scenario.take_shared<Recording<RecordingShare, CompositionShare>>();
    let registry = scenario.take_shared<ReleaseRegistry>();
    let composition_id = object::id(&comp);
    let recording_id = object::id(&rec);
    let predicted_release_id = registry.derive_target_release_id(
        vector[recording_id],
        vector[10000u64],
        NONCE,
    );
    let t = track::new(&rec_cap, &rec, predicted_release_id, 10000);
    test_scenario::return_shared(comp);
    test_scenario::return_shared(rec);
    test_scenario::return_shared(registry);

    // === Tx 4 (LABEL): assemble and publish the release ===
    scenario.next_tx(LABEL);
    let mut registry = scenario.take_shared<ReleaseRegistry>();
    let registry_id = registry.id();
    let (rel, rel_cap) = registry.new(
        b"Single".to_string(),
        vector[t],
        NONCE,
    );
    // The claimed UID must equal the prediction the track was bound to.
    assert_eq!(object::id(&rel), predicted_release_id);

    let mut created_events = event::events_by_type<release::ReleaseCreatedEvent>();
    assert_eq!(created_events.length(), 1);
    let (
        event_registry_id,
        event_release_id,
        event_cap_id,
        title_bytes,
        release_digest,
        event_nonce,
        composition_ids,
        recording_ids,
        track_split_bps,
        track_count,
    ) = release::release_created_event_fields(created_events.pop_back());
    assert_eq!(event_registry_id, registry_id.to_address());
    assert_eq!(event_release_id, predicted_release_id.to_address());
    assert_eq!(event_cap_id, object::id(&rel_cap).to_address());
    assert_eq!(title_bytes, b"Single");
    assert_eq!(release_digest, expected_digest(vector[recording_id], vector[10000], NONCE));
    assert_eq!(event_nonce, NONCE);
    assert_eq!(composition_ids, vector[composition_id.to_address()]);
    assert_eq!(recording_ids, vector[recording_id.to_address()]);
    assert_eq!(track_split_bps, vector[10000]);
    assert_eq!(track_count, 1);

    let clock = sui::clock::create_for_testing(scenario.ctx());
    let clock_id = object::id(&clock).to_address();
    rel.publish(&rel_cap, &clock); // verifies track assignment, shares
    clock.destroy_for_testing();

    let mut published_events = event::events_by_type<release::ReleasePublishedEvent>();
    assert_eq!(published_events.length(), 1);
    let (
        event_release_id,
        event_cap_id,
        event_clock_id,
        title_bytes,
        published_at_ms,
        composition_ids,
        recording_ids,
        track_split_bps,
        assigned_track_count,
        shared_after,
    ) = release::release_published_event_fields(published_events.pop_back());
    assert_eq!(event_release_id, predicted_release_id.to_address());
    assert_eq!(event_cap_id, object::id(&rel_cap).to_address());
    assert_eq!(event_clock_id, clock_id);
    assert_eq!(title_bytes, b"Single");
    assert_eq!(published_at_ms, 0);
    assert_eq!(composition_ids, vector[composition_id.to_address()]);
    assert_eq!(recording_ids, vector[recording_id.to_address()]);
    assert_eq!(track_split_bps, vector[10000]);
    assert_eq!(assigned_track_count, 1);
    assert!(shared_after);

    destroy(rel_cap);
    test_scenario::return_shared(registry);

    // === Tx 5 (READER): the published release is publicly consistent ===
    scenario.next_tx(READER);
    let rel = scenario.take_shared<Release>();
    assert!(rel.is_published_state());
    assert_eq!(object::id(&rel), predicted_release_id);
    assert_eq!(*rel.title(), b"Single".to_string());
    assert_eq!(rel.tracks().length(), 1);
    assert!(rel.tracks().any!(|track| track.recording_id() == recording_id));
    let track_ref = &rel.tracks()[0];
    assert!(track_ref.is_assigned_state());
    assert_eq!(track_ref.recording_id(), recording_id);
    assert_eq!(track_ref.split_bps().value(), 10000);
    test_scenario::return_shared(rel);

    destroy(rec_cap);
    scenario.end();
}

/// A track whose creator consented to a different release cannot be
/// published in this one — the digest binding is enforced at
/// `release::publish`.
#[test, expected_failure(abort_code = 0, location = musicos::track)] // EUnauthorizedAssignment
fun publish_aborts_when_track_targets_a_different_release() {
    let mut scenario = test_scenario::begin(SONGWRITER);
    release::init_for_testing(scenario.ctx());

    // One actor for brevity — the binding doesn't depend on senders.
    scenario.next_tx(SONGWRITER);
    let (_comp, _comp_cap) = composition::new_for_testing<CompositionShare>(
        b"Song".to_string(),
        ROYALTY_RATE_BPS,
        scenario.ctx(),
    );
    let (rec, rec_cap) = recording::new_for_testing<RecordingShare, CompositionShare>(
        object::id(&_comp),
        scenario.ctx(),
    );

    scenario.next_tx(SONGWRITER);
    // Track consented to the release that nonce 1 would produce...
    let registry = scenario.take_shared<ReleaseRegistry>();
    let wrong_release_id = registry.derive_target_release_id(
        vector[object::id(&rec)],
        vector[10000u64],
        1,
    );
    let t = track::new(&rec_cap, &rec, wrong_release_id, 10000);
    test_scenario::return_shared(registry);

    scenario.next_tx(SONGWRITER);
    // ...but the release is created with nonce 2: different derived id.
    let mut registry = scenario.take_shared<ReleaseRegistry>();
    let (rel, rel_cap) = registry.new(
        b"Single".to_string(),
        vector[t],
        2,
    );
    let clock = sui::clock::create_for_testing(scenario.ctx());
    rel.publish(&rel_cap, &clock); // aborts: track targets a different release

    // Unreachable, but the compiler requires all non-drop values consumed.
    abort
}
