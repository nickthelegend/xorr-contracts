/// Per-borrower credit profile and credit-limit logic. The headline mechanic:
/// **the credit limit grows with every repayment** (rewarding good history),
/// and can be lifted by a TEE-attested private credit score (see
/// `confidential_credit`). The over-collateralized BNPL core does not depend
/// on the unsecured headroom; the score/history simply expands it.
module xorr_contracts::credit;

use sui::event;

const EOverLimit: u64 = 0;
const ERepayTooMuch: u64 = 1;

/// Each repayment raises the limit by this fraction (bps) of principal repaid.
const REPAY_REWARD_BPS: u64 = 1_000; // 10%
const BPS_DENOM: u64 = 10_000;
/// Hard ceiling so the limit can't grow unbounded. 1,000,000 USDT (6 dp).
const MAX_CREDIT_LIMIT: u64 = 1_000_000_000_000;
/// Starter line every new profile gets. 50 USDT (6 dp).
const STARTER_LIMIT: u64 = 50_000_000;

/// Shared per-borrower profile. The BNPL engine and the confidential credit
/// oracle (same package) update it via package-internal hooks.
public struct CreditProfile has key {
    id: UID,
    borrower: address,
    credit_limit: u64, // max principal that may be outstanding at once
    outstanding: u64, // principal currently borrowed
    repaid_total: u64, // lifetime principal repaid
    repayments: u64, // number of repayments (credit-history depth)
    score: u64, // TEE-attested private credit score (0..1000), 0 = unscored
}

public struct ProfileOpened has copy, drop { profile_id: ID, borrower: address, starting_limit: u64 }
public struct LimitChanged has copy, drop { borrower: address, new_limit: u64, reason: vector<u8> }
public struct Borrowed has copy, drop { borrower: address, amount: u64, outstanding: u64 }
public struct Repaid has copy, drop { borrower: address, amount: u64, outstanding: u64, new_limit: u64 }

/// Open (and share) a credit profile for the caller.
public fun open_profile(ctx: &mut TxContext) {
    let profile = CreditProfile {
        id: object::new(ctx),
        borrower: ctx.sender(),
        credit_limit: STARTER_LIMIT,
        outstanding: 0,
        repaid_total: 0,
        repayments: 0,
        score: 0,
    };
    event::emit(ProfileOpened {
        profile_id: object::id(&profile),
        borrower: ctx.sender(),
        starting_limit: STARTER_LIMIT,
    });
    transfer::share_object(profile);
}

/// Headroom still available on the credit line.
public fun available_credit(p: &CreditProfile): u64 {
    if (p.credit_limit > p.outstanding) { p.credit_limit - p.outstanding } else { 0 }
}

/// Record new borrowing. Aborts if it would exceed the credit limit.
public(package) fun record_borrow(p: &mut CreditProfile, amount: u64) {
    assert!(p.outstanding + amount <= p.credit_limit, EOverLimit);
    p.outstanding = p.outstanding + amount;
    event::emit(Borrowed { borrower: p.borrower, amount, outstanding: p.outstanding });
}

/// Record a principal repayment: decrease outstanding and **raise the limit**
/// as a reward for repaying (credit grows with good behaviour).
public(package) fun record_repayment(p: &mut CreditProfile, amount: u64) {
    assert!(amount <= p.outstanding, ERepayTooMuch);
    p.outstanding = p.outstanding - amount;
    p.repaid_total = p.repaid_total + amount;
    p.repayments = p.repayments + 1;
    let reward = (((amount as u128) * (REPAY_REWARD_BPS as u128)) / (BPS_DENOM as u128)) as u64;
    let mut new_limit = p.credit_limit + reward;
    if (new_limit > MAX_CREDIT_LIMIT) { new_limit = MAX_CREDIT_LIMIT };
    p.credit_limit = new_limit;
    event::emit(Repaid { borrower: p.borrower, amount, outstanding: p.outstanding, new_limit });
}

/// Reward repayment of a collateral-backed loan: grow the limit as good credit
/// history, WITHOUT touching `outstanding` (those loans don't draw the unsecured
/// line). Used by the over-collateralized path in `market`.
public(package) fun reward_repayment(p: &mut CreditProfile, principal: u64) {
    p.repaid_total = p.repaid_total + principal;
    p.repayments = p.repayments + 1;
    let reward = (((principal as u128) * (REPAY_REWARD_BPS as u128)) / (BPS_DENOM as u128)) as u64;
    let mut new_limit = p.credit_limit + reward;
    if (new_limit > MAX_CREDIT_LIMIT) { new_limit = MAX_CREDIT_LIMIT };
    p.credit_limit = new_limit;
    event::emit(Repaid { borrower: p.borrower, amount: principal, outstanding: p.outstanding, new_limit });
}

/// Apply a TEE-attested private score: record the score and lift the limit to
/// the enclave-approved line (never below current outstanding).
public(package) fun apply_attested_score(p: &mut CreditProfile, score: u64, approved_limit: u64) {
    p.score = score;
    let mut lim = approved_limit;
    if (lim > MAX_CREDIT_LIMIT) { lim = MAX_CREDIT_LIMIT };
    if (lim < p.outstanding) { lim = p.outstanding };
    p.credit_limit = lim;
    event::emit(LimitChanged { borrower: p.borrower, new_limit: lim, reason: b"tee_score" });
}

/// Clear outstanding on default and forfeit the unsecured headroom.
public(package) fun record_default(p: &mut CreditProfile, principal_outstanding: u64) {
    p.outstanding = if (principal_outstanding > p.outstanding) { 0 } else { p.outstanding - principal_outstanding };
    p.credit_limit = p.outstanding;
    event::emit(LimitChanged { borrower: p.borrower, new_limit: p.credit_limit, reason: b"default" });
}

// --- getters ---

public fun credit_limit(p: &CreditProfile): u64 { p.credit_limit }
public fun outstanding(p: &CreditProfile): u64 { p.outstanding }
public fun repaid_total(p: &CreditProfile): u64 { p.repaid_total }
public fun repayments(p: &CreditProfile): u64 { p.repayments }
public fun score(p: &CreditProfile): u64 { p.score }
public fun borrower(p: &CreditProfile): address { p.borrower }
