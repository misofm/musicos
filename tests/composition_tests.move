/// Royalty-rate boundary and lifecycle tests for `composition::new`.
/// These construct and inspect `Composition` values without ever sharing or
/// re-taking one across a transaction boundary, so `tx_context::dummy()` is
/// sufficient — the one exception is `test_publish_composition`, which does
/// touch object ownership (`publish` calls `share_object`) and runs as a
/// `test_scenario` accordingly. The fuller publish/uid_mut/wrong-cap
/// ownership flows live in `post_publish_tests`.
///
/// A composition carries no title (display titles live in the metadata
/// extension), so the royalty rate is the only configurable embedded field.
#[test_only]
module musicos::composition_tests;

use musicos::composition::{Self, Composition};
use musicos::test_helpers::CompositionShare;
use std::unit_test::{assert_eq, destroy};
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

/// `publish` shares the composition — an ownership-affecting op — so this
/// runs as a scenario: publish in one transaction, confirm the object is
/// genuinely shared and re-fetchable via `take_shared` in the next.
#[test]
fun test_publish_composition() {
    let mut scenario = test_scenario::begin(OWNER);
    let ctx = scenario.ctx();
    let (comp, cap) = composition::new_for_testing<CompositionShare>(1500, ctx);
    let clock = sui::clock::create_for_testing(ctx);
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

// The royalty rate is immutable — set once in `new`, no setter exists. The
// tests below pin the accepted range at creation: [0, 10000], no floor, no
// protocol ceiling; whether a rate is acceptable is a recorder's client-side
// concern.

/// There is no protocol ceiling on the rate — any value up to 100% is valid.
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
