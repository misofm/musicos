// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Tests for the production `composition::new` and `recording::new`
/// constructors — the real entry points that wire `share::initialize`
/// (fixed 10M supply, consumed treasury cap) and, for recordings, the fresh
/// `object::new` id plus the read-only `&Composition` royalty snapshot.
///
/// None of these constructors ever share, transfer, or otherwise dispose of
/// the objects they return — a `Composition`/`Recording` is `key`-only with
/// no `drop`, so tests must (and do) `destroy` every value directly. There is
/// no `publish`, no `take_shared`, no sender-dependent behavior to model
/// here, so `tx_context::dummy()` is sufficient. Ownership-flow behavior
/// lives in `post_publish_tests` and `release_e2e_tests`.
#[test_only]
module musicos::production_constructor_tests;

use musicos::composition;
use musicos::recording;
use musicos::share::{Self as test_share, Share};
use musicos::test_helpers::{Self, CompositionShare};
use std::unit_test::{assert_eq, destroy};

/// 10,000,000.000000 tokens at 6 decimals — must match share::SUPPLY.
const SHARE_SUPPLY: u64 = 10_000_000_000_000;

#[test]
fun composition_new_initializes_fixed_share_supply() {
    let ctx = &mut tx_context::dummy();
    let (mut currency, treasury_cap) = test_share::currency_for_testing(ctx);

    let (comp, cap, shares) = composition::new<Share>(
        b"Production Song".to_string(),
        1500,
        &mut currency,
        treasury_cap,
        ctx,
    );

    // The full fixed supply is returned to the creator.
    assert_eq!(shares.value(), SHARE_SUPPLY);
    assert_eq!(*comp.title(), b"Production Song".to_string());
    assert_eq!(comp.royalty_rate().value(), 1500);
    assert!(comp.is_initialized_state());
    assert!(!comp.is_published_state());

    destroy(comp);
    destroy(cap);
    destroy(shares);
    destroy(currency);
}

#[test, expected_failure(abort_code = 0, location = bps::bps)] // bps::EOverflow
fun composition_new_above_100_percent_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut currency, treasury_cap) = test_share::currency_for_testing(ctx);

    let (comp, cap, shares) = composition::new<Share>(
        b"Greedy Song".to_string(),
        10001,
        &mut currency,
        treasury_cap,
        ctx,
    );

    destroy(comp);
    destroy(cap);
    destroy(shares);
    destroy(currency);
}

#[test]
fun recording_new_settles_composition_cut() {
    let ctx = &mut tx_context::dummy();
    let (comp, comp_cap) =
        composition::new_for_testing<CompositionShare>(b"Song".to_string(), 1500, ctx);
    let (mut currency, treasury_cap) = test_share::currency_for_testing(ctx);

    let (rec, rec_cap, shares) = recording::new<Share, CompositionShare>(
        &comp,
        &mut currency,
        treasury_cap,
        ctx,
    );

    // The creator keeps the full supply minus the composition's royalty-rate
    // cut (15% of 10M), which `recording::new` splits off and sends to the
    // composition's address.
    assert_eq!(shares.value(), SHARE_SUPPLY - 1_500_000_000_000);
    assert_eq!(rec.composition_id(), object::id(&comp));
    assert!(rec.is_initialized_state());
    assert!(!rec.is_published_state());

    let mut events = sui::event::events_by_type<
        recording::CompositionSharesGrantedEvent<Share, CompositionShare>,
    >();
    assert_eq!(events.length(), 1);
    let (recording_id, composition_id, value, rate_bps, granted_by) =
        recording::composition_shares_granted_event_fields(events.pop_back());
    assert_eq!(recording_id, object::id(&rec));
    assert_eq!(composition_id, object::id(&comp));
    assert_eq!(value, 1_500_000_000_000);
    assert_eq!(rate_bps, 1500);
    assert_eq!(granted_by, ctx.sender());

    destroy(comp);
    destroy(comp_cap);
    destroy(rec);
    destroy(rec_cap);
    destroy(shares);
    destroy(currency);
}

#[test]
fun recording_new_zero_rate_grants_no_shares() {
    let ctx = &mut tx_context::dummy();
    let (comp, comp_cap) =
        composition::new_for_testing<CompositionShare>(b"Generative Track".to_string(), 0, ctx);
    let (mut currency, treasury_cap) = test_share::currency_for_testing(ctx);

    let (rec, rec_cap, shares) = recording::new<Share, CompositionShare>(
        &comp,
        &mut currency,
        treasury_cap,
        ctx,
    );

    // A 0% composition royalty grants the composition no recording shares: the
    // split/send is skipped, so the creator retains the entire supply.
    assert_eq!(shares.value(), SHARE_SUPPLY);

    destroy(comp);
    destroy(comp_cap);
    destroy(rec);
    destroy(rec_cap);
    destroy(shares);
    destroy(currency);
}

#[test]
fun composition_new_at_zero_rate_succeeds() {
    let ctx = &mut tx_context::dummy();
    let (mut currency, treasury_cap) = test_share::currency_for_testing(ctx);

    // No floor: a generative composition with no authored work may carry a 0% rate.
    let (comp, cap, shares) = composition::new<Share>(
        b"Generative Work".to_string(),
        0,
        &mut currency,
        treasury_cap,
        ctx,
    );

    assert_eq!(comp.royalty_rate().value(), 0);

    destroy(comp);
    destroy(cap);
    destroy(shares);
    destroy(currency);
}

/// Two recordings under one composition are independent objects with distinct
/// ids and no ordering/derivation between them — the composition is read-only,
/// so this is exactly the concurrency-safe path (no index, no `&mut` contention).
#[test]
fun recording_new_independent_ids_succeed() {
    let ctx = &mut tx_context::dummy();
    let (comp, comp_cap) =
        composition::new_for_testing<CompositionShare>(b"Song".to_string(), 1500, ctx);

    let (mut currency0, treasury_cap0) = test_share::currency_for_testing(ctx);
    let (rec0, rec_cap0, shares0) = recording::new<Share, CompositionShare>(
        &comp,
        &mut currency0,
        treasury_cap0,
        ctx,
    );

    let (mut currency1, treasury_cap1) = test_share::currency_for_testing(ctx);
    let (rec1, rec_cap1, shares1) = recording::new<Share, CompositionShare>(
        &comp,
        &mut currency1,
        treasury_cap1,
        ctx,
    );

    assert!(object::id(&rec0) != object::id(&rec1));

    destroy(comp);
    destroy(comp_cap);
    destroy(rec0);
    destroy(rec_cap0);
    destroy(shares0);
    destroy(currency0);
    destroy(rec1);
    destroy(rec_cap1);
    destroy(shares1);
    destroy(currency1);
}

#[test, expected_failure(abort_code = 35, location = musicos::composition)] // EEmptyString
fun composition_new_empty_title_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut currency, treasury_cap) = test_share::currency_for_testing(ctx);

    let (comp, cap, shares) = composition::new<Share>(
        b"".to_string(),
        1500,
        &mut currency,
        treasury_cap,
        ctx,
    );

    destroy(comp);
    destroy(cap);
    destroy(shares);
    destroy(currency);
}

#[test, expected_failure(abort_code = 33, location = musicos::composition)] // EMaxTitleLengthExceeded
fun composition_new_title_too_long_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut currency, treasury_cap) = test_share::currency_for_testing(ctx);

    let (comp, cap, shares) = composition::new<Share>(
        test_helpers::long_string(301),
        1500,
        &mut currency,
        treasury_cap,
        ctx,
    );

    destroy(comp);
    destroy(cap);
    destroy(shares);
    destroy(currency);
}

