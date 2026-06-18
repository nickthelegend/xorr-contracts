#[test_only]
module xorr_contracts::bnpl_tests;

use sui::coin;
use sui::sui::SUI;
use sui::test_scenario::{Self as ts};
use xorr_contracts::bnpl::{Self, Loan};
use xorr_contracts::collateral::CollateralLock;
use xorr_contracts::confidential_credit::{Self, CreditOracle, OracleAdminCap};
use xorr_contracts::credit::{Self, CreditProfile};
use xorr_contracts::lending_pool::{Self, LendingPool};
use xorr_contracts::merchant_escrow::{Self, MerchantEscrow};
use xorr_contracts::usdt::USDT;

const ADMIN: address = @0xAD;
const SUPPLIER: address = @0x5;
const BORROWER: address = @0xB0;
const MERCHANT: address = @0x3E;

// 6-decimal USDT amounts.
const SUPPLY: u64 = 100_000_000; // 100 USDT
const PURCHASE: u64 = 30_000_000; // 30 USDT
const REPAYMENT: u64 = 31_500_000; // 30 + 5% interest

/// Full Buy-Now-Pay-Never flow: supply -> purchase -> repay -> credit limit
/// grows -> collateral returned.
#[test]
fun bnpl_full_flow() {
    let mut sc = ts::begin(ADMIN);

    // 1. Admin creates the lending pool (5% interest on the term).
    {
        let cap = lending_pool::create_pool<USDT>(500, sc.ctx());
        transfer::public_transfer(cap, ADMIN);
    };

    // 2. Supplier deposits 100 USDT of lendable liquidity.
    sc.next_tx(SUPPLIER);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let usdt = coin::mint_for_testing<USDT>(SUPPLY, sc.ctx());
        let receipt = lending_pool::supply<USDT>(&mut pool, usdt, sc.ctx());
        transfer::public_transfer(receipt, SUPPLIER);
        ts::return_shared(pool);
    };

    // 3. Borrower opens a credit profile (starter limit 50 USDT).
    sc.next_tx(BORROWER);
    { credit::open_profile(sc.ctx()); };

    // 4. Merchant opens a payment escrow.
    sc.next_tx(MERCHANT);
    {
        let cap = merchant_escrow::create_escrow<USDT>(sc.ctx());
        transfer::public_transfer(cap, MERCHANT);
    };

    // 5. Borrower buys 30 USDT now, fully collateralized with 30 SUI, 30-epoch term.
    sc.next_tx(BORROWER);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let mut profile = ts::take_shared<CreditProfile>(&sc);
        let mut escrow = ts::take_shared<MerchantEscrow<USDT>>(&sc);
        assert!(credit::credit_limit(&profile) == 50_000_000, 100);

        let collat = coin::mint_for_testing<SUI>(PURCHASE, sc.ctx());
        bnpl::open_purchase<USDT, SUI>(
            &mut pool,
            &mut profile,
            &mut escrow,
            collat,
            PURCHASE,
            30,
            b"order-1",
            sc.ctx(),
        );
        // Merchant was paid up-front, borrower owes principal.
        assert!(credit::outstanding(&profile) == PURCHASE, 101);
        assert!(merchant_escrow::balance_value(&escrow) == PURCHASE, 102);
        assert!(lending_pool::total_borrowed(&pool) == PURCHASE, 103);

        ts::return_shared(pool);
        ts::return_shared(profile);
        ts::return_shared(escrow);
    };

    // 6. Borrower repays principal + interest -> loan closes, limit grows.
    sc.next_tx(BORROWER);
    {
        let mut pool = ts::take_shared<LendingPool<USDT>>(&sc);
        let mut profile = ts::take_shared<CreditProfile>(&sc);
        let mut loan = ts::take_shared<Loan<USDT, SUI>>(&sc);

        let pay = coin::mint_for_testing<USDT>(REPAYMENT, sc.ctx());
        let refund = bnpl::repay<USDT, SUI>(&mut loan, &mut pool, &mut profile, pay, sc.ctx());
        assert!(coin::value(&refund) == 0, 104);
        coin::burn_for_testing(refund);

        assert!(bnpl::is_repaid(&loan), 105);
        assert!(credit::outstanding(&profile) == 0, 106);
        // Credit limit grew by 10% of the 30 USDT principal repaid: 50 -> 53 USDT.
        assert!(credit::credit_limit(&profile) == 53_000_000, 107);
        // Suppliers earned the 1.5 USDT interest: pool assets = 100 + 1.5.
        assert!(lending_pool::total_assets(&pool) == 101_500_000, 108);

        ts::return_shared(pool);
        ts::return_shared(profile);
        ts::return_shared(loan);
    };

    // 7. Borrower reclaims the locked collateral.
    sc.next_tx(BORROWER);
    {
        let loan = ts::take_shared<Loan<USDT, SUI>>(&sc);
        let lock = ts::take_shared<CollateralLock<SUI>>(&sc);
        let collat_back = bnpl::release_collateral<USDT, SUI>(&loan, lock, sc.ctx());
        assert!(coin::value(&collat_back) == PURCHASE, 109);
        coin::burn_for_testing(collat_back);
        ts::return_shared(loan);
    };

    sc.end();
}

/// Confidential credit verify path: an invalid enclave signature must abort
/// (the on-chain ed25519 check rejects anything not signed by the TEE key).
#[test]
#[expected_failure]
fun confidential_bad_signature_aborts() {
    let mut sc = ts::begin(ADMIN);
    { confidential_credit::init_for_testing(sc.ctx()); };

    sc.next_tx(BORROWER);
    { credit::open_profile(sc.ctx()); };

    // Admin registers a (dummy) 32-byte enclave key.
    sc.next_tx(ADMIN);
    {
        let cap = ts::take_from_sender<OracleAdminCap>(&sc);
        let mut oracle = ts::take_shared<CreditOracle>(&sc);
        let key = filled(32, 17);
        confidential_credit::set_enclave_pubkey(&cap, &mut oracle, key);
        ts::return_shared(oracle);
        ts::return_to_sender(&sc, cap);
    };

    // A bogus 64-byte signature fails ed25519 verification -> EBadSignature.
    sc.next_tx(BORROWER);
    {
        let oracle = ts::take_shared<CreditOracle>(&sc);
        let mut profile = ts::take_shared<CreditProfile>(&sc);
        let sig = filled(64, 34);
        confidential_credit::verify_and_apply_score(&oracle, &mut profile, 800, 200_000_000, 1, 1000, sig);
        ts::return_shared(oracle);
        ts::return_shared(profile);
    };

    sc.end();
}

fun filled(n: u64, val: u8): vector<u8> {
    let mut v = vector::empty<u8>();
    let mut i = 0;
    while (i < n) { v.push_back(val); i = i + 1; };
    v
}
