#[test_only]
/// Workload + integration coverage across the XORR contract suite: lending pool
/// yield math, credit-limit growth, BNPL lifecycle (purchase/repay/default/
/// yield-auto-repay), the lend/borrow market (over- & under-collateralized,
/// liquidation), merchant escrow, and confidential-credit guards.
module xorr_contracts::integration_tests;

use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts};
use xorr_contracts::bnpl::{Self, Loan};
use xorr_contracts::collateral::CollateralLock;
use xorr_contracts::confidential_credit::{Self, CreditOracle};
use xorr_contracts::credit::{Self, CreditProfile};
use xorr_contracts::lending_pool::{Self, LendingPool};
use xorr_contracts::market::{Self, CollateralizedPosition};
use xorr_contracts::merchant_escrow::{Self, MerchantEscrow, MerchantCap};
use xorr_contracts::usdt::USDT;

const ADMIN: address = @0xA1;
const LP: address = @0x11;
const BORROWER: address = @0xB1;
const MERCHANT: address = @0x3E;
const M: u64 = 1_000_000;

fun usdt(amt: u64, ctx: &mut TxContext): Coin<USDT> { coin::mint_for_testing<USDT>(amt, ctx) }

// 1. Lending pool: suppliers earn injected yield (share value appreciates).
#[test]
fun lending_pool_supply_yield_withdraw() {
    let mut sc = ts::begin(ADMIN);
    { let cap = lending_pool::create_pool<USDT>(500, sc.ctx()); transfer::public_transfer(cap, ADMIN); };
    sc.next_tx(LP);
    let receipt;
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let c = usdt(100 * M, sc.ctx());
        receipt = lending_pool::supply<USDT>(&mut pool, c, sc.ctx());
        let y = usdt(20 * M, sc.ctx());
        lending_pool::inject_yield<USDT>(&mut pool, y);
        assert!(lending_pool::total_assets(&pool) == 120 * M, 1);
        ts::return_shared(pool);
    };
    sc.next_tx(LP);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let out = lending_pool::withdraw<USDT>(&mut pool, receipt, sc.ctx());
        assert!(coin::value(&out) == 120 * M, 2);
        coin::burn_for_testing(out);
        ts::return_shared(pool);
    };
    sc.end();
}

// 2. Credit limit compounds across repayments (50 -> 53 -> 56).
#[test]
fun credit_limit_compounds() {
    let mut sc = ts::begin(BORROWER);
    { credit::open_profile(sc.ctx()); };
    sc.next_tx(BORROWER);
    {
        let mut p = ts::take_shared<CreditProfile>(&sc);
        credit::record_borrow(&mut p, 30 * M);
        credit::record_repayment(&mut p, 30 * M);
        assert!(credit::credit_limit(&p) == 53 * M, 1);
        credit::record_borrow(&mut p, 30 * M);
        credit::record_repayment(&mut p, 30 * M);
        assert!(credit::credit_limit(&p) == 56 * M, 2);
        assert!(credit::repaid_total(&p) == 60 * M, 3);
        ts::return_shared(p);
    };
    sc.end();
}

// 3. Over-limit borrow aborts.
#[test, expected_failure]
fun credit_over_limit_aborts() {
    let mut sc = ts::begin(BORROWER);
    { credit::open_profile(sc.ctx()); };
    sc.next_tx(BORROWER);
    {
        let mut p = ts::take_shared<CreditProfile>(&sc);
        credit::record_borrow(&mut p, 60 * M);
        ts::return_shared(p);
    };
    sc.end();
}

fun setup_pool_profile_escrow(sc: &mut ts::Scenario) {
    { let cap = lending_pool::create_pool<USDT>(500, sc.ctx()); transfer::public_transfer(cap, ADMIN); };
    sc.next_tx(LP);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(sc);
        let c = usdt(1000 * M, sc.ctx());
        let r = lending_pool::supply<USDT>(&mut pool, c, sc.ctx());
        transfer::public_transfer(r, LP);
        ts::return_shared(pool);
    };
    sc.next_tx(BORROWER);
    { credit::open_profile(sc.ctx()); };
    sc.next_tx(MERCHANT);
    { let cap = merchant_escrow::create_escrow<USDT>(sc.ctx()); transfer::public_transfer(cap, MERCHANT); };
}

// 4. BNPL under-collateralized purchase aborts (collateral < amount).
#[test, expected_failure]
fun bnpl_under_collateralized_aborts() {
    let mut sc = ts::begin(ADMIN);
    setup_pool_profile_escrow(&mut sc);
    sc.next_tx(BORROWER);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let mut profile = ts::take_shared<CreditProfile>(&sc);
        let mut escrow = ts::take_shared<MerchantEscrow<USDT>>(&sc);
        let collat = coin::mint_for_testing<SUI>(10 * M, sc.ctx());
        bnpl::open_purchase<USDT, SUI>(&mut pool, &mut profile, &mut escrow, collat, 30 * M, 30, b"o", sc.ctx());
        ts::return_shared(pool); ts::return_shared(profile); ts::return_shared(escrow);
    };
    sc.end();
}

// 5. BNPL "Pay-Never" yield auto-repay reduces outstanding.
#[test]
fun bnpl_yield_auto_repay() {
    let mut sc = ts::begin(ADMIN);
    setup_pool_profile_escrow(&mut sc);
    sc.next_tx(BORROWER);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let mut profile = ts::take_shared<CreditProfile>(&sc);
        let mut escrow = ts::take_shared<MerchantEscrow<USDT>>(&sc);
        let collat = coin::mint_for_testing<SUI>(50 * M, sc.ctx());
        bnpl::open_purchase<USDT, SUI>(&mut pool, &mut profile, &mut escrow, collat, 30 * M, 30, b"o", sc.ctx());
        ts::return_shared(pool); ts::return_shared(profile); ts::return_shared(escrow);
    };
    sc.next_tx(BORROWER);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let mut profile = ts::take_shared<CreditProfile>(&sc);
        let mut loan = ts::take_shared<Loan<USDT, SUI>>(&sc);
        let y = usdt(10 * M, sc.ctx());
        let leftover = bnpl::auto_repay_from_yield<USDT, SUI>(&mut loan, &mut pool, &mut profile, y, sc.ctx());
        coin::burn_for_testing(leftover);
        assert!(bnpl::outstanding(&loan) == 21_500_000, 1);
        ts::return_shared(pool); ts::return_shared(profile); ts::return_shared(loan);
    };
    sc.end();
}

// 6. BNPL default after due epoch.
#[test]
fun bnpl_default_after_due() {
    let mut sc = ts::begin(ADMIN);
    setup_pool_profile_escrow(&mut sc);
    sc.next_tx(BORROWER);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let mut profile = ts::take_shared<CreditProfile>(&sc);
        let mut escrow = ts::take_shared<MerchantEscrow<USDT>>(&sc);
        let collat = coin::mint_for_testing<SUI>(50 * M, sc.ctx());
        bnpl::open_purchase<USDT, SUI>(&mut pool, &mut profile, &mut escrow, collat, 30 * M, 1, b"o", sc.ctx());
        ts::return_shared(pool); ts::return_shared(profile); ts::return_shared(escrow);
    };
    sc.next_epoch(ADMIN); sc.next_epoch(ADMIN);
    sc.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let mut profile = ts::take_shared<CreditProfile>(&sc);
        let mut loan = ts::take_shared<Loan<USDT, SUI>>(&sc);
        let lock = ts::take_shared<CollateralLock<SUI>>(&sc);
        bnpl::default_loan<USDT, SUI>(&mut loan, lock, &mut pool, &mut profile, sc.ctx());
        assert!(bnpl::status(&loan) == 2, 1);
        ts::return_shared(pool); ts::return_shared(profile); ts::return_shared(loan);
    };
    sc.end();
}

// 7. Market over-collateralized borrow aborts below 150%.
#[test, expected_failure]
fun market_collat_insufficient_aborts() {
    let mut sc = ts::begin(ADMIN);
    { let cap = lending_pool::create_pool<USDT>(500, sc.ctx()); transfer::public_transfer(cap, ADMIN); };
    sc.next_tx(LP);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let c = usdt(1000 * M, sc.ctx());
        let r = lending_pool::supply<USDT>(&mut pool, c, sc.ctx());
        transfer::public_transfer(r, LP);
        ts::return_shared(pool);
    };
    sc.next_tx(BORROWER);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let collat = coin::mint_for_testing<SUI>(100 * M, sc.ctx());
        let funds = market::borrow_collateralized<USDT, SUI>(&mut pool, collat, 100 * M, 30, sc.ctx());
        coin::burn_for_testing(funds);
        ts::return_shared(pool);
    };
    sc.end();
}

// 8. Market liquidation after due seizes collateral.
#[test]
fun market_liquidate_past_due() {
    let mut sc = ts::begin(ADMIN);
    { let cap = lending_pool::create_pool<USDT>(500, sc.ctx()); transfer::public_transfer(cap, ADMIN); };
    sc.next_tx(LP);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let c = usdt(1000 * M, sc.ctx());
        let r = lending_pool::supply<USDT>(&mut pool, c, sc.ctx());
        transfer::public_transfer(r, LP);
        ts::return_shared(pool);
    };
    sc.next_tx(BORROWER);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let collat = coin::mint_for_testing<SUI>(150 * M, sc.ctx());
        let funds = market::borrow_collateralized<USDT, SUI>(&mut pool, collat, 100 * M, 1, sc.ctx());
        coin::burn_for_testing(funds);
        ts::return_shared(pool);
    };
    sc.next_epoch(ADMIN); sc.next_epoch(ADMIN);
    sc.next_tx(ADMIN);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let mut pos = ts::take_shared<CollateralizedPosition<USDT, SUI>>(&sc);
        let lock = ts::take_shared<CollateralLock<SUI>>(&sc);
        market::liquidate<USDT, SUI>(&mut pos, lock, &mut pool, sc.ctx());
        assert!(market::status_collat(&pos) == 2, 1);
        ts::return_shared(pool); ts::return_shared(pos);
    };
    sc.end();
}

// 9. Unsecured borrow without a TEE score aborts.
#[test, expected_failure]
fun market_uncollat_no_score_aborts() {
    let mut sc = ts::begin(ADMIN);
    { let cap = lending_pool::create_pool<USDT>(500, sc.ctx()); transfer::public_transfer(cap, ADMIN); };
    sc.next_tx(LP);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let c = usdt(1000 * M, sc.ctx());
        let r = lending_pool::supply<USDT>(&mut pool, c, sc.ctx());
        transfer::public_transfer(r, LP);
        ts::return_shared(pool);
    };
    sc.next_tx(BORROWER);
    { credit::open_profile(sc.ctx()); };
    sc.next_tx(BORROWER);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let mut profile = ts::take_shared<CreditProfile>(&sc);
        let funds = market::borrow_uncollateralized<USDT>(&mut pool, &mut profile, 20 * M, 30, sc.ctx());
        coin::burn_for_testing(funds);
        ts::return_shared(pool); ts::return_shared(profile);
    };
    sc.end();
}

// 10. Merchant escrow: settle a payment + merchant withdraws it.
#[test]
fun merchant_escrow_settle_withdraw() {
    let mut sc = ts::begin(MERCHANT);
    { let cap = merchant_escrow::create_escrow<USDT>(sc.ctx()); transfer::public_transfer(cap, MERCHANT); };
    sc.next_tx(BORROWER);
    {
        let mut escrow = ts::take_shared<MerchantEscrow<USDT>>(&sc);
        let c = usdt(40 * M, sc.ctx());
        merchant_escrow::settle_payment<USDT>(&mut escrow, c, b"order-9", sc.ctx());
        assert!(merchant_escrow::balance_value(&escrow) == 40 * M, 1);
        ts::return_shared(escrow);
    };
    sc.next_tx(MERCHANT);
    {
        let mut escrow = ts::take_shared<MerchantEscrow<USDT>>(&sc);
        let cap = ts::take_from_sender<MerchantCap>(&sc);
        let out = merchant_escrow::withdraw<USDT>(&mut escrow, &cap, sc.ctx());
        assert!(coin::value(&out) == 40 * M, 2);
        coin::burn_for_testing(out);
        ts::return_to_sender(&sc, cap);
        ts::return_shared(escrow);
    };
    sc.end();
}

// 11. Confidential credit: verifying before a key is registered aborts.
#[test, expected_failure]
fun confidential_no_key_aborts() {
    let mut sc = ts::begin(ADMIN);
    { confidential_credit::init_for_testing(sc.ctx()); };
    sc.next_tx(BORROWER);
    { credit::open_profile(sc.ctx()); };
    sc.next_tx(BORROWER);
    {
        let oracle = ts::take_shared<CreditOracle>(&sc);
        let mut profile = ts::take_shared<CreditProfile>(&sc);
        let mut sig = vector::empty<u8>();
        let mut i = 0; while (i < 64) { sig.push_back(0); i = i + 1; };
        confidential_credit::verify_and_apply_score(&oracle, &mut profile, 700, 100 * M, 1, 1000, sig);
        ts::return_shared(oracle); ts::return_shared(profile);
    };
    sc.end();
}
