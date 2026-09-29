#[test_only]
module musicos::production_constructor_tests;

use std::unit_test::{assert_eq, destroy};
use sui::event;
use sui::test_scenario;
use musicos::composition::{Self, Composition, CompositionAdminCap, CompositionPublishedEvent};
use musicos::recording::{Self, Recording, RecordingAdminCap, RecordingPublishedEvent};
use musicos::track;

#[test]
fun identities_publish_without_currencies() {
    let mut scenario = test_scenario::begin(@0xA);
    let (comp, comp_cap) = composition::new(scenario.ctx());
    let composition_id = object::id(&comp);
    let (rec, rec_cap) = recording::new(&comp, scenario.ctx());
    let recording_id = object::id(&rec);
    assert_eq!(rec.composition_id(), composition_id);
    comp.publish(&comp_cap);
    rec.publish(&rec_cap);
    let mut compositions = event::events_by_type<CompositionPublishedEvent>();
    assert_eq!(compositions.length(), 1);
    assert_eq!(composition::composition_published_event_fields(compositions.pop_back()), composition_id);
    let mut recordings = event::events_by_type<RecordingPublishedEvent>();
    assert_eq!(recordings.length(), 1);
    let (event_rec, event_comp) = recording::recording_published_event_fields(recordings.pop_back());
    assert_eq!(event_rec, recording_id);
    assert_eq!(event_comp, composition_id);
    transfer::public_transfer(comp_cap, @0xA);
    transfer::public_transfer(rec_cap, @0xA);

    scenario.next_tx(@0xA);
    let mut comp = scenario.take_shared<Composition>();
    let mut rec = scenario.take_shared<Recording>();
    let comp_cap = scenario.take_from_sender<CompositionAdminCap>();
    let rec_cap = scenario.take_from_sender<RecordingAdminCap>();
    assert_eq!(comp.uid_mut(&comp_cap).to_inner(), composition_id);
    assert_eq!(rec.uid_mut(&rec_cap).to_inner(), recording_id);
    assert!(comp.is_published_state());
    assert!(rec.is_published_state());
    test_scenario::return_shared(comp);
    test_scenario::return_shared(rec);
    scenario.return_to_sender(comp_cap);
    scenario.return_to_sender(rec_cap);
    scenario.end();
}

#[test]
fun multiple_subjects_and_recordings_have_independent_authority() {
    let ctx = &mut tx_context::dummy();
    let (comp, cap) = composition::new(ctx);
    let (other, other_cap) = composition::new(ctx);
    assert!(object::id(&comp) != object::id(&other));
    comp.authorize(&cap);
    other.authorize(&other_cap);
    let (first, first_cap) = recording::new(&comp, ctx);
    let (second, second_cap) = recording::new(&comp, ctx);
    assert!(object::id(&first) != object::id(&second));
    assert_eq!(first.composition_id(), second.composition_id());
    first.authorize(&first_cap);
    second.authorize(&second_cap);
    destroy(comp); destroy(cap); destroy(other); destroy(other_cap);
    destroy(first); destroy(first_cap); destroy(second); destroy(second_cap);
}

#[test, expected_failure(abort_code = composition::EUnauthorized)]
fun foreign_composition_cap_cannot_publish() {
    let ctx = &mut tx_context::dummy();
    let (comp, cap) = composition::new(ctx);
    let (other, other_cap) = composition::new(ctx);
    comp.publish(&other_cap);
    destroy(cap); destroy(other); destroy(other_cap);
}

#[test, expected_failure(abort_code = composition::EUnauthorized)]
fun foreign_composition_cap_cannot_access_uid() {
    let ctx = &mut tx_context::dummy();
    let (mut comp, cap) = composition::new(ctx);
    let (other, other_cap) = composition::new(ctx);
    comp.uid_mut(&other_cap);
    destroy(comp); destroy(cap); destroy(other); destroy(other_cap);
}

#[test, expected_failure(abort_code = recording::EUnauthorized)]
fun foreign_recording_cap_cannot_publish() {
    let ctx = &mut tx_context::dummy();
    let (comp, cap) = composition::new(ctx);
    let (first, first_cap) = recording::new(&comp, ctx);
    let (second, second_cap) = recording::new(&comp, ctx);
    first.publish(&second_cap);
    destroy(comp); destroy(cap); destroy(first_cap); destroy(second); destroy(second_cap);
}

#[test, expected_failure(abort_code = recording::EUnauthorized)]
fun foreign_recording_cap_cannot_access_uid() {
    let ctx = &mut tx_context::dummy();
    let (comp, cap) = composition::new(ctx);
    let (mut first, first_cap) = recording::new(&comp, ctx);
    let (second, second_cap) = recording::new(&comp, ctx);
    first.uid_mut(&second_cap);
    destroy(comp); destroy(cap); destroy(first); destroy(first_cap); destroy(second); destroy(second_cap);
}

#[test, expected_failure(abort_code = recording::EUnauthorized)]
fun foreign_recording_cap_cannot_consent_to_track() {
    let ctx = &mut tx_context::dummy();
    let (comp, cap) = composition::new(ctx);
    let (first, first_cap) = recording::new(&comp, ctx);
    let (second, second_cap) = recording::new(&comp, ctx);
    track::consent(&first, &second_cap, object::id(&comp), 10000);
    destroy(comp); destroy(cap); destroy(first); destroy(first_cap); destroy(second); destroy(second_cap);
}
