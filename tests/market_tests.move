#[test_only]
module xorr_contracts::market_tests;

use sui::coin;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts};
use xorr_contracts::collateral::CollateralLock;
use xorr_contracts::credit::{Self, CreditProfile};
use xorr_contracts::lending_pool::{Self, LendingPool};
use xorr_contracts::market::{Self, CollateralizedPosition, UnsecuredPosition};
use xorr_contracts::usdt::USDT;

const ADMIN: address = @0xA1;
const LP: address = @0x11;
const BORROWER: address = @0xB1;
const M: u64 = 1_000_000;

/// Over-collateralized: borrow 100 USDT against 150 SUI, repay 105, reclaim collateral,
/// credit limit grows as good history.
#[test]
fun over_collateralized_cycle() {
    let mut sc = ts::begin(ADMIN);
    { let cap = lending_pool::create_pool<USDT>(500, sc.ctx()); transfer::public_transfer(cap, ADMIN); };

    sc.next_tx(LP);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let c = coin::mint_for_testing<USDT>(1000 * M, sc.ctx());
        let r = lending_pool::supply<USDT>(&mut pool, c, sc.ctx());
        transfer::public_transfer(r, LP);
        ts::return_shared(pool);
    };

    sc.next_tx(BORROWER);
    { credit::open_profile(sc.ctx()); };

    sc.next_tx(BORROWER);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let collat = coin::mint_for_testing<SUI>(150 * M, sc.ctx());
        let funds = market::borrow_collateralized<USDT, SUI>(&mut pool, collat, 100 * M, 30, sc.ctx());
        assert!(coin::value(&funds) == 100 * M, 1);
        coin::burn_for_testing(funds);
        ts::return_shared(pool);
    };

    sc.next_tx(BORROWER);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let mut profile = ts::take_shared<CreditProfile>(&sc);
        let mut pos = ts::take_shared<CollateralizedPosition<USDT, SUI>>(&sc);
        let pay = coin::mint_for_testing<USDT>(105 * M, sc.ctx()); // 100 + 5%
        let refund = market::repay_collateralized<USDT, SUI>(&mut pos, &mut pool, &mut profile, pay, sc.ctx());
        assert!(coin::value(&refund) == 0, 2);
        coin::burn_for_testing(refund);
        assert!(market::status_collat(&pos) == 1, 3); // repaid
        // limit grew by 10% of 100 USDT principal: 50 -> 60
        assert!(credit::credit_limit(&profile) == 60 * M, 4);
        ts::return_shared(pool);
        ts::return_shared(profile);
        ts::return_shared(pos);
    };

    sc.next_tx(BORROWER);
    {
        let pos = ts::take_shared<CollateralizedPosition<USDT, SUI>>(&sc);
        let lock = ts::take_shared<CollateralLock<SUI>>(&sc);
        let back = market::release_collateral<USDT, SUI>(&pos, lock, sc.ctx());
        assert!(coin::value(&back) == 150 * M, 5);
        coin::burn_for_testing(back);
        ts::return_shared(pos);
    };
    sc.end();
}

/// Under-collateralized: a TEE score lifts the line, borrow 50 USDT unsecured, repay 55.
#[test]
fun under_collateralized_cycle() {
    let mut sc = ts::begin(ADMIN);
    { let cap = lending_pool::create_pool<USDT>(500, sc.ctx()); transfer::public_transfer(cap, ADMIN); };

    sc.next_tx(LP);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let c = coin::mint_for_testing<USDT>(1000 * M, sc.ctx());
        let r = lending_pool::supply<USDT>(&mut pool, c, sc.ctx());
        transfer::public_transfer(r, LP);
        ts::return_shared(pool);
    };

    sc.next_tx(BORROWER);
    { credit::open_profile(sc.ctx()); };

    // Simulate a TEE attestation lifting the score + line to 100 USDT.
    sc.next_tx(BORROWER);
    {
        let mut profile = ts::take_shared<CreditProfile>(&sc);
        credit::apply_attested_score(&mut profile, 700, 100 * M);
        ts::return_shared(profile);
    };

    sc.next_tx(BORROWER);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let mut profile = ts::take_shared<CreditProfile>(&sc);
        let funds = market::borrow_uncollateralized<USDT>(&mut pool, &mut profile, 50 * M, 30, sc.ctx());
        assert!(coin::value(&funds) == 50 * M, 1);
        assert!(credit::outstanding(&profile) == 50 * M, 2);
        coin::burn_for_testing(funds);
        ts::return_shared(pool);
        ts::return_shared(profile);
    };

    sc.next_tx(BORROWER);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let mut profile = ts::take_shared<CreditProfile>(&sc);
        let mut pos = ts::take_shared<UnsecuredPosition<USDT>>(&sc);
        // base 5% + 5% premium = 10% interest -> 55 USDT
        let pay = coin::mint_for_testing<USDT>(55 * M, sc.ctx());
        let refund = market::repay_uncollateralized<USDT>(&mut pos, &mut pool, &mut profile, pay, sc.ctx());
        assert!(coin::value(&refund) == 0, 3);
        coin::burn_for_testing(refund);
        assert!(market::status_unsecured(&pos) == 1, 4); // repaid
        assert!(credit::outstanding(&profile) == 0, 5);
        // line was 100, repaid 50 principal -> +10% reward = 105
        assert!(credit::credit_limit(&profile) == 105 * M, 6);
        ts::return_shared(pool);
        ts::return_shared(profile);
        ts::return_shared(pos);
    };
    sc.end();
}
