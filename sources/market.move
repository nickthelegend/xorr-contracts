/// XORR lend/borrow market on top of the lending pool + credit profile.
/// Suppliers provide liquidity via `lending_pool::supply`. Borrowers take loans
/// in two flavors:
///   - **Over-collateralized** (`borrow_collateralized`): backed by >= 150% `Coin<C>`
///     collateral. Open to anyone with collateral; not gated by the credit line.
///   - **Under-collateralized** (`borrow_uncollateralized`): gated by a TEE-attested
///     private credit score (>= MIN_SCORE) and draws down the borrower's credit line.
///     The visionary path — risk priced with a rate premium.
module xorr_contracts::market;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use xorr_contracts::collateral::{Self, CollateralLock};
use xorr_contracts::credit::{Self, CreditProfile};
use xorr_contracts::lending_pool::{Self, LendingPool};

const EUnderCollateralized: u64 = 0;
const EWrongBorrower: u64 = 1;
const EPositionMismatch: u64 = 2;
const ENotDue: u64 = 3;
const EAlreadyClosed: u64 = 4;
const ENotRepaid: u64 = 5;
const EZeroPayment: u64 = 6;
const EScoreTooLow: u64 = 7;

const BPS_DENOM: u64 = 10_000;
/// Over-collateralized loans require collateral >= 150% of the borrowed amount.
const MIN_COLLATERAL_RATIO_BPS: u64 = 15_000;
/// Under-collateralized loans require a TEE credit score of at least this (0..1000).
const MIN_SCORE_UNCOLLAT: u64 = 600;
/// Rate premium (bps) added to the pool base rate for unsecured loans.
const UNCOLLAT_RATE_PREMIUM_BPS: u64 = 500;

const STATUS_ACTIVE: u8 = 0;
const STATUS_REPAID: u8 = 1;
const STATUS_LIQUIDATED: u8 = 2;

/// Over-collateralized borrow position.
public struct CollateralizedPosition<phantom T, phantom C> has key {
    id: UID,
    borrower: address,
    principal: u64,
    principal_repaid: u64,
    outstanding: u64,
    collateral_lock_id: ID,
    opened_epoch: u64,
    due_epoch: u64,
    status: u8,
}

/// Under-collateralized (TEE-score gated) borrow position.
public struct UnsecuredPosition<phantom T> has key {
    id: UID,
    borrower: address,
    principal: u64,
    principal_repaid: u64,
    outstanding: u64,
    opened_epoch: u64,
    due_epoch: u64,
    status: u8,
}

public struct Borrowed has copy, drop { position_id: ID, borrower: address, amount: u64, collateralized: bool, outstanding: u64 }
public struct Repaid has copy, drop { position_id: ID, borrower: address, amount: u64, outstanding: u64, closed: bool }
public struct Liquidated has copy, drop { position_id: ID, borrower: address, seized: u64 }

fun interest_on(amount: u64, bps: u64): u64 {
    (((amount as u128) * (bps as u128)) / (BPS_DENOM as u128)) as u64
}

// ---------------- over-collateralized ----------------

/// Borrow `amount` of T against `collateral` (>= 150%). Returns the borrowed coin.
public fun borrow_collateralized<T, C>(
    pool: &mut LendingPool<T>,
    collateral: Coin<C>,
    amount: u64,
    term_epochs: u64,
    ctx: &mut TxContext,
): Coin<T> {
    let borrower = ctx.sender();
    let needed = (((amount as u128) * (MIN_COLLATERAL_RATIO_BPS as u128)) / (BPS_DENOM as u128)) as u64;
    assert!(coin::value(&collateral) >= needed, EUnderCollateralized);
    let interest = interest_on(amount, lending_pool::borrow_interest_bps(pool));
    let lock = collateral::lock<C>(collateral, borrower, ctx);
    let collateral_lock_id = object::id(&lock);
    let funds = lending_pool::borrow_out<T>(pool, amount);
    let pos = CollateralizedPosition<T, C> {
        id: object::new(ctx),
        borrower,
        principal: amount,
        principal_repaid: 0,
        outstanding: amount + interest,
        collateral_lock_id,
        opened_epoch: ctx.epoch(),
        due_epoch: ctx.epoch() + term_epochs,
        status: STATUS_ACTIVE,
    };
    event::emit(Borrowed { position_id: object::id(&pos), borrower, amount, collateralized: true, outstanding: pos.outstanding });
    transfer::public_share_object(lock);
    transfer::share_object(pos);
    coin::from_balance(funds, ctx)
}

/// Repay (partial or full) a collateralized loan; grows the credit limit as good
/// history. Overpayment refunded. Full repayment marks the position repaid.
public fun repay_collateralized<T, C>(
    pos: &mut CollateralizedPosition<T, C>,
    pool: &mut LendingPool<T>,
    profile: &mut CreditProfile,
    payment: Coin<T>,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(pos.status == STATUS_ACTIVE, EAlreadyClosed);
    assert!(pos.borrower == ctx.sender(), EWrongBorrower);
    assert!(coin::value(&payment) > 0, EZeroPayment);
    let mut bal = coin::into_balance(payment);
    let pay = balance::value(&bal);
    let applied = if (pay > pos.outstanding) { pos.outstanding } else { pay };
    let principal_out = pos.principal - pos.principal_repaid;
    let principal_part = if (applied > principal_out) { principal_out } else { applied };
    let interest_part = applied - principal_part;
    lending_pool::repay_principal<T>(pool, balance::split(&mut bal, principal_part));
    if (interest_part > 0) { lending_pool::add_interest<T>(pool, balance::split(&mut bal, interest_part)); };
    pos.outstanding = pos.outstanding - applied;
    pos.principal_repaid = pos.principal_repaid + principal_part;
    if (principal_part > 0) { credit::reward_repayment(profile, principal_part); };
    if (pos.outstanding == 0) { pos.status = STATUS_REPAID; };
    event::emit(Repaid { position_id: object::id(pos), borrower: pos.borrower, amount: applied, outstanding: pos.outstanding, closed: pos.status == STATUS_REPAID });
    coin::from_balance(bal, ctx)
}

/// Reclaim collateral after a collateralized loan is fully repaid.
public fun release_collateral<T, C>(pos: &CollateralizedPosition<T, C>, lock: CollateralLock<C>, ctx: &mut TxContext): Coin<C> {
    assert!(pos.status == STATUS_REPAID, ENotRepaid);
    assert!(pos.borrower == ctx.sender(), EWrongBorrower);
    assert!(object::id(&lock) == pos.collateral_lock_id, EPositionMismatch);
    collateral::release<C>(lock, ctx)
}

/// Liquidate a past-due collateralized loan: seize collateral to the treasury.
public fun liquidate<T, C>(pos: &mut CollateralizedPosition<T, C>, lock: CollateralLock<C>, pool: &mut LendingPool<T>, ctx: &mut TxContext) {
    assert!(pos.status == STATUS_ACTIVE, EAlreadyClosed);
    assert!(object::id(&lock) == pos.collateral_lock_id, EPositionMismatch);
    assert!(ctx.epoch() > pos.due_epoch, ENotDue);
    let (borrower, seized) = collateral::seize<C>(lock);
    let amt = balance::value(&seized);
    transfer::public_transfer(coin::from_balance(seized, ctx), lending_pool::treasury<T>(pool));
    lending_pool::write_off_principal<T>(pool, pos.principal - pos.principal_repaid);
    pos.principal_repaid = pos.principal;
    pos.outstanding = 0;
    pos.status = STATUS_LIQUIDATED;
    event::emit(Liquidated { position_id: object::id(pos), borrower, seized: amt });
}

// ---------------- under-collateralized (TEE-score gated) ----------------

/// Borrow `amount` of T with no collateral, gated by a TEE-attested credit score
/// and the borrower's credit line. Carries a rate premium. Returns the coin.
public fun borrow_uncollateralized<T>(
    pool: &mut LendingPool<T>,
    profile: &mut CreditProfile,
    amount: u64,
    term_epochs: u64,
    ctx: &mut TxContext,
): Coin<T> {
    let borrower = ctx.sender();
    assert!(credit::borrower(profile) == borrower, EWrongBorrower);
    assert!(credit::score(profile) >= MIN_SCORE_UNCOLLAT, EScoreTooLow);
    credit::record_borrow(profile, amount); // asserts amount <= credit line
    let bps = lending_pool::borrow_interest_bps(pool) + UNCOLLAT_RATE_PREMIUM_BPS;
    let interest = interest_on(amount, bps);
    let funds = lending_pool::borrow_out<T>(pool, amount);
    let pos = UnsecuredPosition<T> {
        id: object::new(ctx),
        borrower,
        principal: amount,
        principal_repaid: 0,
        outstanding: amount + interest,
        opened_epoch: ctx.epoch(),
        due_epoch: ctx.epoch() + term_epochs,
        status: STATUS_ACTIVE,
    };
    event::emit(Borrowed { position_id: object::id(&pos), borrower, amount, collateralized: false, outstanding: pos.outstanding });
    transfer::share_object(pos);
    coin::from_balance(funds, ctx)
}

/// Repay an unsecured loan; releases the credit line and grows the limit.
public fun repay_uncollateralized<T>(
    pos: &mut UnsecuredPosition<T>,
    pool: &mut LendingPool<T>,
    profile: &mut CreditProfile,
    payment: Coin<T>,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(pos.status == STATUS_ACTIVE, EAlreadyClosed);
    assert!(pos.borrower == ctx.sender(), EWrongBorrower);
    assert!(coin::value(&payment) > 0, EZeroPayment);
    let mut bal = coin::into_balance(payment);
    let pay = balance::value(&bal);
    let applied = if (pay > pos.outstanding) { pos.outstanding } else { pay };
    let principal_out = pos.principal - pos.principal_repaid;
    let principal_part = if (applied > principal_out) { principal_out } else { applied };
    let interest_part = applied - principal_part;
    lending_pool::repay_principal<T>(pool, balance::split(&mut bal, principal_part));
    if (interest_part > 0) { lending_pool::add_interest<T>(pool, balance::split(&mut bal, interest_part)); };
    pos.outstanding = pos.outstanding - applied;
    pos.principal_repaid = pos.principal_repaid + principal_part;
    if (principal_part > 0) { credit::record_repayment(profile, principal_part); };
    if (pos.outstanding == 0) { pos.status = STATUS_REPAID; };
    event::emit(Repaid { position_id: object::id(pos), borrower: pos.borrower, amount: applied, outstanding: pos.outstanding, closed: pos.status == STATUS_REPAID });
    coin::from_balance(bal, ctx)
}

// ---------------- getters ----------------

public fun outstanding_collat<T, C>(p: &CollateralizedPosition<T, C>): u64 { p.outstanding }
public fun status_collat<T, C>(p: &CollateralizedPosition<T, C>): u8 { p.status }
public fun outstanding_unsecured<T>(p: &UnsecuredPosition<T>): u64 { p.outstanding }
public fun status_unsecured<T>(p: &UnsecuredPosition<T>): u8 { p.status }
public fun min_score_uncollat(): u64 { MIN_SCORE_UNCOLLAT }
public fun min_collateral_ratio_bps(): u64 { MIN_COLLATERAL_RATIO_BPS }
