/// Buy-Now-Pay-Never loan lifecycle — the orchestrator that ties the lending
/// vault, credit profile, collateral lock, and merchant escrow together.
///
/// Flow:
///  1. `open_purchase` — check the credit line, lock the borrower's collateral
///     (over-collateralized: collateral >= amount), borrow the amount from the
///     pool, and pay the merchant escrow immediately.
///  2. `repay` — borrower repays; principal returns to the pool, interest
///     accrues to suppliers, and the credit limit grows.
///  3. `auto_repay_from_yield` — the "Pay-Never" engine: yield earned on the
///     borrower's collateral (e.g. via DeepBook) is routed in to repay the loan
///     for them. Permissionless (a keeper can call it).
///  4. `release_collateral` — once fully repaid, the borrower reclaims collateral.
///  5. `default_loan` — past due: seize collateral to the treasury and write off.
module xorr_contracts::bnpl;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use xorr_contracts::collateral::{Self, CollateralLock};
use xorr_contracts::credit::{Self, CreditProfile};
use xorr_contracts::lending_pool::{Self, LendingPool};
use xorr_contracts::merchant_escrow::{Self, MerchantEscrow};

const EUnderCollateralized: u64 = 0;
const EWrongBorrower: u64 = 1;
const ELoanMismatch: u64 = 2;
const ENotDue: u64 = 3;
const EAlreadyClosed: u64 = 4;
const ENotRepaid: u64 = 5;
const EZeroPayment: u64 = 6;

const BPS_DENOM: u64 = 10_000;

const STATUS_ACTIVE: u8 = 0;
const STATUS_REPAID: u8 = 1;
const STATUS_DEFAULTED: u8 = 2;

/// A BNPL loan. The merchant is paid up-front from the pool; the borrower owes
/// `outstanding` (principal + interest) and has `Coin<C>` collateral locked.
public struct Loan<phantom T, phantom C> has key {
    id: UID,
    borrower: address,
    merchant: address,
    principal: u64,
    principal_repaid: u64,
    outstanding: u64, // principal + interest still owed
    collateral_lock_id: ID,
    opened_epoch: u64,
    due_epoch: u64,
    status: u8,
}

public struct LoanOpened has copy, drop {
    loan_id: ID,
    borrower: address,
    merchant: address,
    principal: u64,
    outstanding: u64,
    due_epoch: u64,
}
public struct LoanRepaid has copy, drop { loan_id: ID, payer: address, amount: u64, outstanding: u64, closed: bool }
public struct YieldRepaid has copy, drop { loan_id: ID, amount: u64, outstanding: u64, closed: bool }
public struct LoanDefaulted has copy, drop { loan_id: ID, borrower: address, seized: u64, written_off: u64 }

/// Open a Buy-Now-Pay-Never purchase.
public fun open_purchase<T, C>(
    pool: &mut LendingPool<T>,
    profile: &mut CreditProfile,
    escrow: &mut MerchantEscrow<T>,
    collateral_coin: Coin<C>,
    amount: u64,
    term_epochs: u64,
    order_id: vector<u8>,
    ctx: &mut TxContext,
) {
    let borrower = ctx.sender();
    assert!(credit::borrower(profile) == borrower, EWrongBorrower);
    // Over-collateralization guard — the honest, demoable working core.
    assert!(collateral_coin.value() >= amount, EUnderCollateralized);

    // Simple interest over the term: principal * bps / 10_000.
    let interest = (((amount as u128) * (lending_pool::borrow_interest_bps(pool) as u128)) / (BPS_DENOM as u128)) as u64;
    let outstanding = amount + interest;

    // Credit check + record (aborts if over the limit).
    credit::record_borrow(profile, amount);

    // Lock collateral.
    let lock = collateral::lock<C>(collateral_coin, borrower, ctx);
    let collateral_lock_id = object::id(&lock);

    // Borrow from the pool and pay the merchant now.
    let funds = lending_pool::borrow_out<T>(pool, amount);
    merchant_escrow::deposit<T>(escrow, funds, borrower, order_id);
    let merchant = merchant_escrow::merchant<T>(escrow);

    let loan = Loan<T, C> {
        id: object::new(ctx),
        borrower,
        merchant,
        principal: amount,
        principal_repaid: 0,
        outstanding,
        collateral_lock_id,
        opened_epoch: ctx.epoch(),
        due_epoch: ctx.epoch() + term_epochs,
        status: STATUS_ACTIVE,
    };
    event::emit(LoanOpened {
        loan_id: object::id(&loan),
        borrower,
        merchant,
        principal: amount,
        outstanding,
        due_epoch: loan.due_epoch,
    });
    transfer::public_share_object(lock);
    transfer::share_object(loan);
}

/// Shared payment accounting for both borrower repayment and yield auto-repay.
/// Routes principal back to the pool and interest to suppliers; returns the
/// amount applied and any leftover balance (overpayment) to refund.
fun apply_payment<T, C>(
    loan: &mut Loan<T, C>,
    pool: &mut LendingPool<T>,
    profile: &mut CreditProfile,
    mut pay_bal: Balance<T>,
): (u64, Balance<T>) {
    let pay_amount = balance::value(&pay_bal);
    let applied = if (pay_amount > loan.outstanding) { loan.outstanding } else { pay_amount };
    let principal_outstanding = loan.principal - loan.principal_repaid;
    let principal_part = if (applied > principal_outstanding) { principal_outstanding } else { applied };
    let interest_part = applied - principal_part;

    let principal_bal = balance::split(&mut pay_bal, principal_part);
    lending_pool::repay_principal<T>(pool, principal_bal);
    if (interest_part > 0) {
        let interest_bal = balance::split(&mut pay_bal, interest_part);
        lending_pool::add_interest<T>(pool, interest_bal);
    };

    loan.outstanding = loan.outstanding - applied;
    loan.principal_repaid = loan.principal_repaid + principal_part;
    if (principal_part > 0) { credit::record_repayment(profile, principal_part); };
    if (loan.outstanding == 0) { loan.status = STATUS_REPAID; };
    (applied, pay_bal)
}

/// Borrower repays (partial or full). Overpayment is refunded.
public fun repay<T, C>(
    loan: &mut Loan<T, C>,
    pool: &mut LendingPool<T>,
    profile: &mut CreditProfile,
    payment: Coin<T>,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(loan.status == STATUS_ACTIVE, EAlreadyClosed);
    assert!(loan.borrower == ctx.sender(), EWrongBorrower);
    assert!(payment.value() > 0, EZeroPayment);
    let (applied, leftover) = apply_payment(loan, pool, profile, payment.into_balance());
    event::emit(LoanRepaid {
        loan_id: object::id(loan),
        payer: ctx.sender(),
        amount: applied,
        outstanding: loan.outstanding,
        closed: loan.status == STATUS_REPAID,
    });
    coin::from_balance(leftover, ctx)
}

/// The "Pay-Never" engine: route realized yield (e.g. from the borrower's
/// collateral deployed to DeepBook) in to repay the loan. Permissionless.
public fun auto_repay_from_yield<T, C>(
    loan: &mut Loan<T, C>,
    pool: &mut LendingPool<T>,
    profile: &mut CreditProfile,
    yield_coin: Coin<T>,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(loan.status == STATUS_ACTIVE, EAlreadyClosed);
    assert!(yield_coin.value() > 0, EZeroPayment);
    let (applied, leftover) = apply_payment(loan, pool, profile, yield_coin.into_balance());
    event::emit(YieldRepaid {
        loan_id: object::id(loan),
        amount: applied,
        outstanding: loan.outstanding,
        closed: loan.status == STATUS_REPAID,
    });
    coin::from_balance(leftover, ctx)
}

/// Reclaim collateral once the loan is fully repaid.
public fun release_collateral<T, C>(
    loan: &Loan<T, C>,
    lock: CollateralLock<C>,
    ctx: &mut TxContext,
): Coin<C> {
    assert!(loan.status == STATUS_REPAID, ENotRepaid);
    assert!(loan.borrower == ctx.sender(), EWrongBorrower);
    assert!(object::id(&lock) == loan.collateral_lock_id, ELoanMismatch);
    collateral::release<C>(lock, ctx)
}

/// Default a past-due loan: seize collateral to the protocol treasury and
/// write off the unrecovered principal. Callable by anyone after the due epoch.
public fun default_loan<T, C>(
    loan: &mut Loan<T, C>,
    lock: CollateralLock<C>,
    pool: &mut LendingPool<T>,
    profile: &mut CreditProfile,
    ctx: &mut TxContext,
) {
    assert!(loan.status == STATUS_ACTIVE, EAlreadyClosed);
    assert!(object::id(&lock) == loan.collateral_lock_id, ELoanMismatch);
    assert!(ctx.epoch() > loan.due_epoch, ENotDue);

    let (borrower, seized_bal) = collateral::seize<C>(lock);
    let seized = balance::value(&seized_bal);
    transfer::public_transfer(coin::from_balance(seized_bal, ctx), lending_pool::treasury<T>(pool));

    let principal_outstanding = loan.principal - loan.principal_repaid;
    lending_pool::write_off_principal<T>(pool, principal_outstanding);
    credit::record_default(profile, principal_outstanding);
    loan.principal_repaid = loan.principal;
    loan.outstanding = 0;
    loan.status = STATUS_DEFAULTED;
    event::emit(LoanDefaulted { loan_id: object::id(loan), borrower, seized, written_off: principal_outstanding });
}

// --- getters ---

public fun outstanding<T, C>(loan: &Loan<T, C>): u64 { loan.outstanding }
public fun principal<T, C>(loan: &Loan<T, C>): u64 { loan.principal }
public fun status<T, C>(loan: &Loan<T, C>): u8 { loan.status }
public fun borrower<T, C>(loan: &Loan<T, C>): address { loan.borrower }
public fun is_repaid<T, C>(loan: &Loan<T, C>): bool { loan.status == STATUS_REPAID }
