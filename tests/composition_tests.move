#[test_only]
module musicos::composition_tests;

use musicos::composition::{Self, Composition};
use std::unit_test::destroy;
use sui::test_scenario;

const OWNER: address = @0xA1;

// === Lifecycle ===

#[test]
fun test_new_composition() {
    let ctx = &mut tx_context::dummy();
    let (comp, cap) = composition::new(ctx);
    assert!(comp.is_initialized_state());
    assert!(!comp.is_published_state());
    destroy(comp);
    destroy(cap);
}

/// `publish` shares the composition: publish in one transaction, re-fetch it
/// via `take_shared` in the next.
#[test]
fun test_publish_composition() {
    let mut scenario = test_scenario::begin(OWNER);
    let ctx = scenario.ctx();
    let (comp, cap) = composition::new(ctx);
    comp.publish(&cap); // shares the composition

    scenario.next_tx(OWNER);
    let comp = scenario.take_shared<Composition>();
    assert!(comp.is_published_state());
    test_scenario::return_shared(comp);

    destroy(cap);
    scenario.end();
}
