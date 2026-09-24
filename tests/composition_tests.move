/// Royalty-rate boundary and lifecycle tests for `composition::new`. Only
/// `test_publish_composition` touches ownership and runs as a scenario; the
/// fuller publish/uid_mut/wrong-cap flows live in `post_publish_tests`.
#[test_only]
module musicos::composition_tests;

use musicos::composition::{Self, Composition};
use musicos::test_helpers::CompositionShare;
use std::unit_test::{assert_eq, destroy};
use sui::clock;
use sui::test_scenario;

const OWNER: address = @0xA1;

// === Lifecycle ===

#[test]
fun test_new_composition() {
    let ctx = &mut tx_context::dummy();
    let (comp, cap) = composition::new_for_testing<CompositionShare>(1500, ctx);
    assert!(comp.is_initialized_state());
    assert!(!comp.is_published_state());
    assert_eq!(comp.royalty_rate().value(), 1500);
    destroy(comp);
    destroy(cap);
}

/// `publish` shares the composition: publish in one transaction, re-fetch it
/// via `take_shared` in the next.
#[test]
fun test_publish_composition() {
    let mut scenario = test_scenario::begin(OWNER);
    let ctx = scenario.ctx();
    let (comp, cap) = composition::new_for_testing<CompositionShare>(1500, ctx);
    let clock = clock::create_for_testing(ctx);
    comp.publish(&cap, &clock); // shares the composition
    clock.destroy_for_testing();

    scenario.next_tx(OWNER);
    let comp = scenario.take_shared<Composition<CompositionShare>>();
    assert!(comp.is_published_state());
    assert_eq!(comp.royalty_rate().value(), 1500);
    test_scenario::return_shared(comp);

    destroy(cap);
    scenario.end();
}

// === Royalty rate ===

// The rate is set once in `new`; these pin the accepted range: [0, 10000].

/// No protocol ceiling: any rate up to 100% is valid.
#[test]
fun test_new_above_former_cap() {
    let ctx = &mut tx_context::dummy();
    let (comp, cap) = composition::new_for_testing<CompositionShare>(8000, ctx);
    assert_eq!(comp.royalty_rate().value(), 8000);
    destroy(comp);
    destroy(cap);
}

#[test]
fun test_new_at_zero_and_max() {
    let ctx = &mut tx_context::dummy();
    let (comp_zero, cap_zero) = composition::new_for_testing<CompositionShare>(0, ctx);
    let (comp_max, cap_max) = composition::new_for_testing<CompositionShare>(10000, ctx);
    assert_eq!(comp_zero.royalty_rate().value(), 0);
    assert_eq!(comp_max.royalty_rate().value(), 10000);
    destroy(comp_zero);
    destroy(cap_zero);
    destroy(comp_max);
    destroy(cap_max);
}

#[test, expected_failure(abort_code = 0, location = bps::bps)] // bps::EOverflow
fun test_new_above_100_percent() {
    let ctx = &mut tx_context::dummy();
    let (comp, cap) = composition::new_for_testing<CompositionShare>(10001, ctx);
    destroy(comp);
    destroy(cap);
}
