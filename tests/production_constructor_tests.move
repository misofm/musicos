// Copyright (c) Miso Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Tests for the production `composition::new` and `recording::new`
/// constructors, which wire `share::initialize`. Each scenario uses one
/// CoinRegistry with distinct share types, finalized and shared through
/// production APIs. The composition cut is asserted through effects: the
/// creator's balance is `supply - cut`. The composition-side withdrawals
/// exercise the redemption path but, since the unit-test accumulator does
/// not enforce balances, are not by themselves proof of delivery.
#[test_only]
module musicos::production_constructor_tests;

use musicos::composition;
use musicos::recording;
use musicos::share::{Self as test_share, Share};
use other_recording_share::share::{Self as other_recording_share, Share as OtherRecordingShare};
use recording_share::share::{Self as recording_share, Share as RecordingShare};
use std::unit_test::{assert_eq, destroy};
use sui::balance;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::coin_registry::{Self, CoinRegistry, Currency};
use sui::event;
use sui::test_scenario::{Self, Scenario};

/// 100,000,000.000000 tokens at 6 decimals — must match share::SUPPLY.
const SHARE_SUPPLY: u64 = 100_000_000_000_000;

/// One registry per simulated chain, including both recordings' currencies.
fun new_scenario(): Scenario {
    let mut scenario = test_scenario::begin(@0x0);
    let ctx = scenario.ctx();
    let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
    transfer::public_transfer(test_share::register(&mut registry, ctx), @0x0);
    transfer::public_transfer(recording_share::register(&mut registry, ctx), @0x0);
    transfer::public_transfer(other_recording_share::register(&mut registry, ctx), @0x0);
    coin_registry::share_for_testing(registry);
    scenario.next_tx(@0x0);
    scenario
}

fun assert_production_recording_published_event<RecordingShare>(
    event: recording::RecordingPublishedEvent<RecordingShare>,
    expected_recording_id: address,
    expected_composition_id: address,
) {
    let (recording_id, composition_id) = recording::recording_published_event_fields(event);
    assert_eq!(recording_id, expected_recording_id);
    assert_eq!(composition_id, expected_composition_id);
}

#[test, expected_failure(abort_code = coin_registry::ECurrencyAlreadyExists, location = sui::coin_registry)]
fun duplicate_share_currency_registration_aborts() {
    let mut scenario = new_scenario();
    let mut registry = scenario.take_shared<CoinRegistry>();
    let duplicate_cap = test_share::register(&mut registry, scenario.ctx());
    transfer::public_transfer(duplicate_cap, @0x0);
    test_scenario::return_shared(registry);
    scenario.end();
}

#[test]
fun composition_new_initializes_fixed_share_supply() {
    let mut scenario = new_scenario();
    let mut currency = scenario.take_shared<Currency<Share>>();
    let treasury_cap = scenario.take_from_sender<TreasuryCap<Share>>();
    let ctx = scenario.ctx();
    let (comp, cap, shares) = composition::new<Share>(
        1500,
        &mut currency,
        treasury_cap,
        ctx,
    );
    // `share::initialize` fixes the supply; the treasury cap was consumed.
    assert!(currency.is_supply_fixed());
    test_scenario::return_shared(currency);

    // The full fixed supply is returned to the creator.
    assert_eq!(shares.value(), SHARE_SUPPLY);
    assert_eq!(comp.royalty_rate().value(), 1500);
    assert!(comp.is_initialized_state());
    assert!(!comp.is_published_state());
    assert_eq!(event::events_by_type<composition::CompositionPublishedEvent<Share>>().length(), 0);

    let composition_id = object::id(&comp).to_address();
    comp.publish(&cap);

    let mut events = event::events_by_type<composition::CompositionPublishedEvent<Share>>();
    assert_eq!(events.length(), 1);
    let (event_comp_id, rate_bps) =
        composition::composition_published_event_fields(events.pop_back());
    assert_eq!(event_comp_id, composition_id);
    assert_eq!(rate_bps, 1500);

    transfer::public_transfer(cap, @0x0);
    transfer::public_transfer(coin::from_balance(shares, scenario.ctx()), @0x0);
    scenario.next_tx(@0x0);
    let comp = scenario.take_shared<composition::Composition<Share>>();
    let cap = scenario.take_from_sender<composition::CompositionAdminCap<Share>>();
    destroy(comp);
    destroy(cap);
    scenario.end();
}

#[test, expected_failure(abort_code = 0, location = bps::bps)] // bps::EOverflow
fun composition_new_above_100_percent_aborts() {
    let mut scenario = new_scenario();
    let mut currency = scenario.take_shared<Currency<Share>>();
    let treasury_cap = scenario.take_from_sender<TreasuryCap<Share>>();
    let ctx = scenario.ctx();

    let (comp, cap, shares) = composition::new<Share>(
        10001,
        &mut currency,
        treasury_cap,
        ctx,
    );
    test_scenario::return_shared(currency);

    destroy(comp);
    destroy(cap);
    destroy(shares);
    scenario.end();
}

#[test]
fun recording_new_settles_composition_cut() {
    let mut scenario = new_scenario();
    let mut composition_currency = scenario.take_shared<Currency<Share>>();
    let composition_treasury_cap = scenario.take_from_sender<TreasuryCap<Share>>();
    let ctx = scenario.ctx();
    let (comp, comp_cap, comp_shares) = composition::new<Share>(
        1500,
        &mut composition_currency,
        composition_treasury_cap,
        ctx,
    );
    test_scenario::return_shared(composition_currency);

    // Publish the composition so the next transaction can record against it.
    let composition_id = object::id(&comp).to_address();
    comp.publish(&comp_cap);
    transfer::public_transfer(comp_cap, @0x0);
    transfer::public_transfer(coin::from_balance(comp_shares, ctx), @0x0);

    scenario.next_tx(@0x0);
    let comp = scenario.take_shared<composition::Composition<Share>>();
    let mut currency = scenario.take_shared<Currency<RecordingShare>>();
    let treasury_cap = scenario.take_from_sender<TreasuryCap<RecordingShare>>();
    let ctx = scenario.ctx();
    let (rec, rec_cap, shares) = recording::new<RecordingShare, Share>(
        &comp,
        &mut currency,
        treasury_cap,
        ctx,
    );
    assert!(currency.is_supply_fixed());
    test_scenario::return_shared(currency);

    // The creator keeps the supply minus the 15% cut sent to the composition.
    assert_eq!(shares.value(), SHARE_SUPPLY - 15_000_000_000_000);
    assert_eq!(rec.composition_id(), object::id(&comp));
    assert!(rec.is_initialized_state());
    assert!(!rec.is_published_state());
    assert_eq!(event::events_by_type<recording::RecordingPublishedEvent<RecordingShare>>().length(), 0);

    let recording_id = object::id(&rec).to_address();
    rec.publish(&rec_cap);

    let mut events = event::events_by_type<recording::RecordingPublishedEvent<RecordingShare>>();
    assert_eq!(events.length(), 1);
    assert_production_recording_published_event(
        events.pop_back(),
        recording_id,
        composition_id,
    );

    test_scenario::return_shared(comp);
    transfer::public_transfer(rec_cap, @0x0);

    transfer::public_transfer(coin::from_balance(shares, scenario.ctx()), @0x0);
    scenario.next_tx(@0x0);
    let mut comp = scenario.take_shared<composition::Composition<Share>>();
    let rec = scenario.take_shared<recording::Recording<RecordingShare>>();
    let comp_cap = scenario.take_from_sender<composition::CompositionAdminCap<Share>>();
    let rec_cap = scenario.take_from_sender<recording::RecordingAdminCap<RecordingShare>>();
    destroy(rec);
    // cut + remainder == supply, via the composition admin's redemption path.
    let mut creator_shares = scenario.take_from_sender<Coin<RecordingShare>>();
    let withdrawal = balance::withdraw_funds_from_object<RecordingShare>(
        comp.uid_mut(&comp_cap), 15_000_000_000_000,
    );
    let grant = balance::redeem_funds(withdrawal);
    assert_eq!(grant.value(), 15_000_000_000_000);
    creator_shares.join(coin::from_balance(grant, scenario.ctx()));
    assert_eq!(creator_shares.value(), SHARE_SUPPLY);
    scenario.return_to_sender(creator_shares);
    destroy(comp);
    destroy(comp_cap);
    destroy(rec_cap);
    scenario.end();
}

#[test]
fun recording_new_zero_rate_grants_no_shares() {
    let mut scenario = new_scenario();
    let mut composition_currency = scenario.take_shared<Currency<Share>>();
    let composition_treasury_cap = scenario.take_from_sender<TreasuryCap<Share>>();
    let ctx = scenario.ctx();
    let (comp, comp_cap, comp_shares) = composition::new<Share>(
        0,
        &mut composition_currency,
        composition_treasury_cap,
        ctx,
    );
    test_scenario::return_shared(composition_currency);
    let composition_id = object::id(&comp).to_address();
    comp.publish(&comp_cap);
    transfer::public_transfer(comp_cap, @0x0);
    transfer::public_transfer(coin::from_balance(comp_shares, ctx), @0x0);

    scenario.next_tx(@0x0);
    let comp = scenario.take_shared<composition::Composition<Share>>();
    let comp_cap = scenario.take_from_sender<composition::CompositionAdminCap<Share>>();
    let mut currency = scenario.take_shared<Currency<RecordingShare>>();
    let treasury_cap = scenario.take_from_sender<TreasuryCap<RecordingShare>>();
    let ctx = scenario.ctx();

    let (rec, rec_cap, shares) = recording::new<RecordingShare, Share>(
        &comp,
        &mut currency,
        treasury_cap,
        ctx,
    );
    test_scenario::return_shared(currency);

    // A 0% rate skips the split: the creator keeps the entire supply.
    assert_eq!(shares.value(), SHARE_SUPPLY);

    assert_eq!(event::events_by_type<recording::RecordingPublishedEvent<RecordingShare>>().length(), 0);

    let recording_id = object::id(&rec).to_address();
    rec.publish(&rec_cap);

    let mut events = event::events_by_type<recording::RecordingPublishedEvent<RecordingShare>>();
    assert_eq!(events.length(), 1);
    assert_production_recording_published_event(
        events.pop_back(),
        recording_id,
        composition_id,
    );

    test_scenario::return_shared(comp);
    transfer::public_transfer(comp_cap, @0x0);
    transfer::public_transfer(coin::from_balance(shares, scenario.ctx()), @0x0);
    transfer::public_transfer(rec_cap, @0x0);
    scenario.next_tx(@0x0);
    let mut comp = scenario.take_shared<composition::Composition<Share>>();
    let rec = scenario.take_shared<recording::Recording<RecordingShare>>();
    let comp_cap = scenario.take_from_sender<composition::CompositionAdminCap<Share>>();
    let mut creator_shares = scenario.take_from_sender<Coin<RecordingShare>>();
    // Nothing was split off, so there is nothing for the composition to redeem.
    let withdrawal = balance::withdraw_funds_from_object<RecordingShare>(
        comp.uid_mut(&comp_cap), 0,
    );
    let grant = balance::redeem_funds(withdrawal);
    assert_eq!(grant.value(), 0);
    creator_shares.join(coin::from_balance(grant, scenario.ctx()));
    assert_eq!(creator_shares.value(), SHARE_SUPPLY);
    scenario.return_to_sender(creator_shares);
    destroy(comp);
    destroy(comp_cap);
    let rec_cap = scenario.take_from_sender<recording::RecordingAdminCap<RecordingShare>>();
    destroy(rec_cap);
    destroy(rec);
    scenario.end();
}

#[test]
fun recording_new_full_rate_grants_full_supply() {
    let mut scenario = new_scenario();
    let mut composition_currency = scenario.take_shared<Currency<Share>>();
    let composition_treasury_cap = scenario.take_from_sender<TreasuryCap<Share>>();
    let ctx = scenario.ctx();
    let (comp, comp_cap, comp_shares) = composition::new<Share>(
        10000,
        &mut composition_currency,
        composition_treasury_cap,
        ctx,
    );
    test_scenario::return_shared(composition_currency);
    let composition_id = object::id(&comp).to_address();
    comp.publish(&comp_cap);
    transfer::public_transfer(comp_cap, @0x0);
    transfer::public_transfer(coin::from_balance(comp_shares, ctx), @0x0);

    scenario.next_tx(@0x0);
    let comp = scenario.take_shared<composition::Composition<Share>>();
    let comp_cap = scenario.take_from_sender<composition::CompositionAdminCap<Share>>();
    let mut currency = scenario.take_shared<Currency<RecordingShare>>();
    let treasury_cap = scenario.take_from_sender<TreasuryCap<RecordingShare>>();
    let ctx = scenario.ctx();

    let (rec, rec_cap, shares) = recording::new<RecordingShare, Share>(
        &comp,
        &mut currency,
        treasury_cap,
        ctx,
    );
    test_scenario::return_shared(currency);
    // A 100% rate is a legitimate choice: the creator keeps nothing.
    assert_eq!(shares.value(), 0);

    assert_eq!(event::events_by_type<recording::RecordingPublishedEvent<RecordingShare>>().length(), 0);

    let recording_id = object::id(&rec).to_address();
    rec.publish(&rec_cap);

    let mut events = event::events_by_type<recording::RecordingPublishedEvent<RecordingShare>>();
    assert_eq!(events.length(), 1);
    assert_production_recording_published_event(
        events.pop_back(),
        recording_id,
        composition_id,
    );

    test_scenario::return_shared(comp);
    transfer::public_transfer(comp_cap, @0x0);
    transfer::public_transfer(coin::from_balance(shares, scenario.ctx()), @0x0);
    transfer::public_transfer(rec_cap, @0x0);
    scenario.next_tx(@0x0);
    let mut comp = scenario.take_shared<composition::Composition<Share>>();
    let rec = scenario.take_shared<recording::Recording<RecordingShare>>();
    let comp_cap = scenario.take_from_sender<composition::CompositionAdminCap<Share>>();
    let mut creator_shares = scenario.take_from_sender<Coin<RecordingShare>>();
    // The entire supply was split off for the composition (creator kept 0).
    let withdrawal = balance::withdraw_funds_from_object<RecordingShare>(
        comp.uid_mut(&comp_cap), SHARE_SUPPLY,
    );
    let grant = balance::redeem_funds(withdrawal);
    assert_eq!(grant.value(), SHARE_SUPPLY);
    creator_shares.join(coin::from_balance(grant, scenario.ctx()));
    assert_eq!(creator_shares.value(), SHARE_SUPPLY);
    scenario.return_to_sender(creator_shares);
    destroy(comp);
    destroy(comp_cap);
    let rec_cap = scenario.take_from_sender<recording::RecordingAdminCap<RecordingShare>>();
    destroy(rec_cap);
    destroy(rec);
    scenario.end();
}

#[test]
fun composition_new_at_zero_rate_succeeds() {
    let mut scenario = new_scenario();
    let mut currency = scenario.take_shared<Currency<Share>>();
    let treasury_cap = scenario.take_from_sender<TreasuryCap<Share>>();
    let ctx = scenario.ctx();

    // No floor: a generative composition with no authored work may carry a 0% rate.
    let (comp, cap, shares) = composition::new<Share>(
        0,
        &mut currency,
        treasury_cap,
        ctx,
    );
    test_scenario::return_shared(currency);

    assert_eq!(comp.royalty_rate().value(), 0);

    destroy(comp);
    destroy(cap);
    destroy(shares);
    scenario.end();
}

/// Two recordings under one composition are independent objects with distinct
/// ids: the composition is read-only, so there is no index or `&mut` contention.
#[test]
fun recording_new_independent_ids_succeed() {
    let mut scenario = new_scenario();
    let mut composition_currency = scenario.take_shared<Currency<Share>>();
    let composition_treasury_cap = scenario.take_from_sender<TreasuryCap<Share>>();
    let ctx = scenario.ctx();
    let (comp, comp_cap, comp_shares) = composition::new<Share>(
        1500,
        &mut composition_currency,
        composition_treasury_cap,
        ctx,
    );
    test_scenario::return_shared(composition_currency);
    let composition_id = object::id(&comp).to_address();
    comp.publish(&comp_cap);
    transfer::public_transfer(comp_cap, @0x0);
    transfer::public_transfer(coin::from_balance(comp_shares, ctx), @0x0);

    scenario.next_tx(@0x0);
    let comp = scenario.take_shared<composition::Composition<Share>>();
    let comp_cap = scenario.take_from_sender<composition::CompositionAdminCap<Share>>();
    let mut currency0 = scenario.take_shared<Currency<RecordingShare>>();
    let treasury_cap0 = scenario.take_from_sender<TreasuryCap<RecordingShare>>();
    let mut currency1 = scenario.take_shared<Currency<OtherRecordingShare>>();
    let treasury_cap1 = scenario.take_from_sender<TreasuryCap<OtherRecordingShare>>();
    let ctx = scenario.ctx();
    let (rec0, rec_cap0, shares0) = recording::new<RecordingShare, Share>(
        &comp,
        &mut currency0,
        treasury_cap0,
        ctx,
    );
    test_scenario::return_shared(currency0);
    let rec0_id = object::id(&rec0).to_address();
    rec0.publish(&rec_cap0);

    let (rec1, rec_cap1, shares1) = recording::new<OtherRecordingShare, Share>(
        &comp,
        &mut currency1,
        treasury_cap1,
        ctx,
    );
    test_scenario::return_shared(currency1);
    let rec1_id = object::id(&rec1).to_address();
    rec1.publish(&rec_cap1);

    assert!(rec0_id != rec1_id);
    // Each recording settled its own 15% cut independently.
    assert_eq!(shares0.value(), SHARE_SUPPLY - 15_000_000_000_000);
    assert_eq!(shares1.value(), SHARE_SUPPLY - 15_000_000_000_000);
    let mut events0 = event::events_by_type<recording::RecordingPublishedEvent<RecordingShare>>();
    let mut events1 = event::events_by_type<recording::RecordingPublishedEvent<OtherRecordingShare>>();
    assert_eq!(events0.length(), 1);
    assert_eq!(events1.length(), 1);
    assert_production_recording_published_event(
        events0.pop_back(),
        rec0_id,
        composition_id,
    );
    assert_production_recording_published_event(
        events1.pop_back(),
        rec1_id,
        composition_id,
    );

    test_scenario::return_shared(comp);
    transfer::public_transfer(comp_cap, @0x0);
    destroy(rec_cap0);
    destroy(shares0);
    destroy(rec_cap1);
    destroy(shares1);
    scenario.next_tx(@0x0);
    let comp = scenario.take_shared<composition::Composition<Share>>();
    let comp_cap = scenario.take_from_sender<composition::CompositionAdminCap<Share>>();
    destroy(comp);
    destroy(comp_cap);
    scenario.end();
}
