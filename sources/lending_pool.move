/// A yield-earning lending vault. Suppliers deposit `T` and receive shares
/// (a `SupplyReceipt`); they earn yield as borrowers pay interest and as
/// external yield (e.g. DeepBook returns on idle liquidity) is injected.
/// The BNPL engine borrows liquidity from `available` to front purchases and
/// routes repayments / yield back in. This is the "Pay-Never" capital base.
module xorr_contracts::lending_pool;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;

const EInsufficientLiquidity: u64 = 0;
const EZeroAmount: u64 = 1;
const ENotAdmin: u64 = 2;
const EWrongPool: u64 = 3;
const EZeroShares: u64 = 4;

/// Admin capability for a specific lending pool.
public struct PoolAdminCap has key, store {
    id: UID,
    pool_id: ID,
}

public struct LendingPool<phantom T> has key {
    id: UID,
    available: Balance<T>, // lendable liquidity sitting in the vault
    total_shares: u64, // supplier shares outstanding
    total_borrowed: u64, // principal currently lent out to BNPL loans
    borrow_interest_bps: u64, // interest charged on a loan over its term
    treasury: address, // protocol address (receives seized collateral, etc.)
}

/// A supplier's share-based claim on the pool. Redeem via `withdraw`.
public struct SupplyReceipt<phantom T> has key, store {
    id: UID,
    pool_id: ID,
    shares: u64,
}

public struct PoolCreated has copy, drop { pool_id: ID, treasury: address, borrow_interest_bps: u64 }
public struct Supplied has copy, drop { pool_id: ID, supplier: address, amount: u64, shares: u64 }
public struct Withdrawn has copy, drop { pool_id: ID, supplier: address, amount: u64, shares: u64 }
public struct YieldInjected has copy, drop { pool_id: ID, amount: u64 }

/// Create and share a new lending pool; returns the admin cap to the caller.
public fun create_pool<T>(borrow_interest_bps: u64, ctx: &mut TxContext): PoolAdminCap {
    let pool = LendingPool<T> {
        id: object::new(ctx),
        available: balance::zero<T>(),
        total_shares: 0,
        total_borrowed: 0,
        borrow_interest_bps,
        treasury: ctx.sender(),
    };
    let pool_id = object::id(&pool);
    event::emit(PoolCreated { pool_id, treasury: ctx.sender(), borrow_interest_bps });
    transfer::share_object(pool);
    PoolAdminCap { id: object::new(ctx), pool_id }
}

entry fun create_pool_entry<T>(borrow_interest_bps: u64, ctx: &mut TxContext) {
    let cap = create_pool<T>(borrow_interest_bps, ctx);
    transfer::public_transfer(cap, ctx.sender());
}

/// Total assets backing supplier shares = idle liquidity + lent-out principal.
/// Interest and injected yield land in `available`, lifting each share's value.
public fun total_assets<T>(pool: &LendingPool<T>): u64 {
    balance::value(&pool.available) + pool.total_borrowed
}

/// Supply liquidity and receive a share receipt.
public fun supply<T>(pool: &mut LendingPool<T>, deposit: Coin<T>, ctx: &mut TxContext): SupplyReceipt<T> {
    let amount = deposit.value();
    assert!(amount > 0, EZeroAmount);
    let assets = total_assets(pool);
    let shares = if (pool.total_shares == 0 || assets == 0) {
        amount
    } else {
        (((amount as u128) * (pool.total_shares as u128)) / (assets as u128)) as u64
    };
    // Reject deposits that would round to zero shares (share-inflation guard).
    assert!(shares > 0, EZeroShares);
    balance::join(&mut pool.available, deposit.into_balance());
    pool.total_shares = pool.total_shares + shares;
    let pool_id = object::id(pool);
    event::emit(Supplied { pool_id, supplier: ctx.sender(), amount, shares });
    SupplyReceipt<T> { id: object::new(ctx), pool_id, shares }
}

/// Redeem a supply receipt for the current value of its shares.
public fun withdraw<T>(pool: &mut LendingPool<T>, receipt: SupplyReceipt<T>, ctx: &mut TxContext): Coin<T> {
    let pool_id = object::id(pool);
    let SupplyReceipt { id, pool_id: rcpt_pool, shares } = receipt;
    assert!(rcpt_pool == pool_id, EWrongPool);
    id.delete();
    let assets = total_assets(pool);
    let amount = (((shares as u128) * (assets as u128)) / (pool.total_shares as u128)) as u64;
    assert!(balance::value(&pool.available) >= amount, EInsufficientLiquidity);
    pool.total_shares = pool.total_shares - shares;
    let out = balance::split(&mut pool.available, amount);
    event::emit(Withdrawn { pool_id, supplier: ctx.sender(), amount, shares });
    coin::from_balance(out, ctx)
}

/// Partially redeem a supply receipt for `amount` of `T` (the receipt stays,
/// with its shares reduced). Lets a supplier pull just enough liquidity (e.g. to
/// repay a loan) without closing their whole position. Aborts if the pool
/// doesn't have `amount` idle.
public fun withdraw_amount<T>(pool: &mut LendingPool<T>, receipt: &mut SupplyReceipt<T>, amount: u64, ctx: &mut TxContext): Coin<T> {
    assert!(amount > 0, EZeroAmount);
    let assets = total_assets(pool);
    let shares_to_burn = (((amount as u128) * (pool.total_shares as u128)) / (assets as u128)) as u64;
    assert!(shares_to_burn > 0 && shares_to_burn <= receipt.shares, EInsufficientLiquidity);
    assert!(balance::value(&pool.available) >= amount, EInsufficientLiquidity);
    receipt.shares = receipt.shares - shares_to_burn;
    pool.total_shares = pool.total_shares - shares_to_burn;
    let pool_id = object::id(pool);
    event::emit(Withdrawn { pool_id, supplier: ctx.sender(), amount, shares: shares_to_burn });
    coin::from_balance(balance::split(&mut pool.available, amount), ctx)
}

/// Inject external yield (e.g. realized DeepBook returns) into the pool.
/// Lifts every supplier's share value. Permissionless — funds speak.
public fun inject_yield<T>(pool: &mut LendingPool<T>, c: Coin<T>) {
    let amount = c.value();
    balance::join(&mut pool.available, c.into_balance());
    event::emit(YieldInjected { pool_id: object::id(pool), amount });
}

// --- package hooks used by the bnpl orchestrator ---

/// Lend `amount` out of the vault for a BNPL loan.
public(package) fun borrow_out<T>(pool: &mut LendingPool<T>, amount: u64): Balance<T> {
    assert!(balance::value(&pool.available) >= amount, EInsufficientLiquidity);
    pool.total_borrowed = pool.total_borrowed + amount;
    balance::split(&mut pool.available, amount)
}

/// Return repaid principal to the vault.
public(package) fun repay_principal<T>(pool: &mut LendingPool<T>, principal: Balance<T>) {
    let amt = balance::value(&principal);
    pool.total_borrowed = if (amt > pool.total_borrowed) { 0 } else { pool.total_borrowed - amt };
    balance::join(&mut pool.available, principal);
}

/// Add interest to the vault — accrues to suppliers as yield.
public(package) fun add_interest<T>(pool: &mut LendingPool<T>, interest: Balance<T>) {
    balance::join(&mut pool.available, interest);
}

/// Write off unrecoverable principal on default (keeps `total_assets` honest).
public(package) fun write_off_principal<T>(pool: &mut LendingPool<T>, amount: u64) {
    pool.total_borrowed = if (amount > pool.total_borrowed) { 0 } else { pool.total_borrowed - amount };
}

// --- admin ---

public fun set_interest_bps<T>(cap: &PoolAdminCap, pool: &mut LendingPool<T>, new_bps: u64) {
    assert!(cap.pool_id == object::id(pool), ENotAdmin);
    pool.borrow_interest_bps = new_bps;
}

// --- getters ---

public fun available_value<T>(pool: &LendingPool<T>): u64 { balance::value(&pool.available) }
public fun total_borrowed<T>(pool: &LendingPool<T>): u64 { pool.total_borrowed }
public fun total_shares<T>(pool: &LendingPool<T>): u64 { pool.total_shares }
public fun borrow_interest_bps<T>(pool: &LendingPool<T>): u64 { pool.borrow_interest_bps }
public fun treasury<T>(pool: &LendingPool<T>): address { pool.treasury }
public fun shares<T>(receipt: &SupplyReceipt<T>): u64 { receipt.shares }
