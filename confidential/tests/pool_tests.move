#[test_only]
module xorr::pool_tests;

use xorr::pool::{Self, Pool, OrderCommitment};
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;

const ADMIN: address = @0xA;
const TRADER: address = @0xB;
const OTHER: address = @0xC;

const ENV: vector<u8> = b"sealed-ciphertext-bytes";
const HASH: vector<u8> = b"commit-hash-32-bytes-padding----";

#[test]
fun init_shares_pool() {
    let mut s = ts::begin(ADMIN);
    xorr::xorr::init_for_testing(s.ctx());
    s.next_tx(ADMIN);

    let pool = s.take_shared<Pool>();
    ts::return_shared(pool);
    s.end();
}

#[test]
fun submit_order_shares_commitment() {
    let mut s = ts::begin(ADMIN);
    xorr::xorr::init_for_testing(s.ctx());

    s.next_tx(TRADER);
    let coin = coin::mint_for_testing<SUI>(1_000_000, s.ctx());
    pool::submit_order<SUI>(ENV, HASH, coin, /* expiry */ 5, s.ctx());

    s.next_tx(TRADER);
    let order = s.take_shared<OrderCommitment<SUI>>();
    ts::return_shared(order);
    s.end();
}

#[test, expected_failure(abort_code = pool::EOrderExpired)]
fun submit_order_with_past_expiry_aborts() {
    let mut s = ts::begin(ADMIN);
    xorr::xorr::init_for_testing(s.ctx());

    s.next_tx(TRADER);
    let coin = coin::mint_for_testing<SUI>(1_000_000, s.ctx());
    pool::submit_order<SUI>(ENV, HASH, coin, /* expiry */ 0, s.ctx());

    abort 0
}

#[test, expected_failure(abort_code = pool::EZeroCollateral)]
fun submit_order_with_zero_collateral_aborts() {
    let mut s = ts::begin(ADMIN);
    xorr::xorr::init_for_testing(s.ctx());

    s.next_tx(TRADER);
    let coin = coin::mint_for_testing<SUI>(0, s.ctx());
    pool::submit_order<SUI>(ENV, HASH, coin, /* expiry */ 5, s.ctx());

    abort 0
}

#[test]
fun cancel_expired_returns_collateral() {
    let mut s = ts::begin(ADMIN);
    xorr::xorr::init_for_testing(s.ctx());

    s.next_tx(TRADER);
    let coin = coin::mint_for_testing<SUI>(777, s.ctx());
    pool::submit_order<SUI>(ENV, HASH, coin, /* expiry */ 1, s.ctx());

    s.next_epoch(TRADER);
    s.next_epoch(TRADER);

    let order = s.take_shared<OrderCommitment<SUI>>();
    let refund = pool::cancel_expired<SUI>(order, s.ctx());
    assert!(refund.value() == 777);
    refund.burn_for_testing();
    s.end();
}

#[test, expected_failure(abort_code = pool::EWrongTrader)]
fun cancel_by_non_trader_aborts() {
    let mut s = ts::begin(ADMIN);
    xorr::xorr::init_for_testing(s.ctx());

    s.next_tx(TRADER);
    let coin = coin::mint_for_testing<SUI>(100, s.ctx());
    pool::submit_order<SUI>(ENV, HASH, coin, /* expiry */ 1, s.ctx());

    s.next_epoch(OTHER);
    s.next_epoch(OTHER);

    let order = s.take_shared<OrderCommitment<SUI>>();
    let refund = pool::cancel_expired<SUI>(order, s.ctx());
    refund.burn_for_testing();
    abort 0
}

#[test, expected_failure(abort_code = pool::EOrderNotExpired)]
fun cancel_before_expiry_aborts() {
    let mut s = ts::begin(ADMIN);
    xorr::xorr::init_for_testing(s.ctx());

    s.next_tx(TRADER);
    let coin = coin::mint_for_testing<SUI>(100, s.ctx());
    pool::submit_order<SUI>(ENV, HASH, coin, /* expiry */ 10, s.ctx());

    s.next_tx(TRADER);
    let order = s.take_shared<OrderCommitment<SUI>>();
    let refund = pool::cancel_expired<SUI>(order, s.ctx());
    refund.burn_for_testing();
    abort 0
}

#[test]
fun cancel_anytime_refunds_before_expiry() {
    let mut s = ts::begin(ADMIN);
    xorr::xorr::init_for_testing(s.ctx());

    s.next_tx(TRADER);
    let coin = coin::mint_for_testing<SUI>(555, s.ctx());
    pool::submit_order<SUI>(ENV, HASH, coin, /* expiry */ 999, s.ctx());

    s.next_tx(TRADER);
    let order = s.take_shared<OrderCommitment<SUI>>();
    let refund = pool::cancel_anytime<SUI>(order, s.ctx());
    assert!(refund.value() == 555);
    refund.burn_for_testing();
    s.end();
}

#[test, expected_failure(abort_code = pool::EWrongTrader)]
fun cancel_anytime_by_non_trader_aborts() {
    let mut s = ts::begin(ADMIN);
    xorr::xorr::init_for_testing(s.ctx());

    s.next_tx(TRADER);
    let coin = coin::mint_for_testing<SUI>(100, s.ctx());
    pool::submit_order<SUI>(ENV, HASH, coin, /* expiry */ 999, s.ctx());

    s.next_tx(OTHER);
    let order = s.take_shared<OrderCommitment<SUI>>();
    let refund = pool::cancel_anytime<SUI>(order, s.ctx());
    refund.burn_for_testing();
    abort 0
}
