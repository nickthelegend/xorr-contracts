/// Collateral lock for BNPL loans. A `CollateralLock<C>` is created when a
/// loan opens (holding the borrower's `Coin<C>`), and consumed when the loan
/// closes — released back to the borrower on repayment, or seized on default.
/// The lock/unlock/seize primitives are package-internal so only the `bnpl`
/// orchestrator drives them.
module xorr_contracts::collateral;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;

public struct CollateralLock<phantom C> has key, store {
    id: UID,
    borrower: address,
    amount: u64,
    locked: Balance<C>,
}

public struct CollateralLocked has copy, drop { lock_id: ID, borrower: address, amount: u64 }
public struct CollateralReleased has copy, drop { lock_id: ID, borrower: address, amount: u64 }
public struct CollateralSeized has copy, drop { lock_id: ID, borrower: address, amount: u64 }

/// Lock `coin` as collateral for `borrower`. The caller (bnpl) shares the
/// returned object and records its id on the loan.
public(package) fun lock<C>(coin: Coin<C>, borrower: address, ctx: &mut TxContext): CollateralLock<C> {
    let amount = coin.value();
    let lock = CollateralLock<C> {
        id: object::new(ctx),
        borrower,
        amount,
        locked: coin.into_balance(),
    };
    event::emit(CollateralLocked { lock_id: object::id(&lock), borrower, amount });
    lock
}

/// Release the full collateral back to the borrower (loan fully repaid).
public(package) fun release<C>(lock: CollateralLock<C>, ctx: &mut TxContext): Coin<C> {
    let lock_id = object::id(&lock);
    let CollateralLock { id, borrower, amount, locked } = lock;
    id.delete();
    event::emit(CollateralReleased { lock_id, borrower, amount });
    coin::from_balance(locked, ctx)
}

/// Seize collateral (loan defaulted). Returns the borrower and the balance so
/// the caller can route it (e.g. to the protocol treasury / liquidator).
public(package) fun seize<C>(lock: CollateralLock<C>): (address, Balance<C>) {
    let lock_id = object::id(&lock);
    let CollateralLock { id, borrower, amount, locked } = lock;
    id.delete();
    event::emit(CollateralSeized { lock_id, borrower, amount });
    (borrower, locked)
}

public fun amount<C>(lock: &CollateralLock<C>): u64 { lock.amount }
public fun borrower<C>(lock: &CollateralLock<C>): address { lock.borrower }
