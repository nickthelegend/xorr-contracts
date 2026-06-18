module xorr::pool;

use sui::balance::Balance;
use sui::coin::{Self, Coin};
use sui::event;

const EOrderExpired: u64 = 0;
const EOrderNotExpired: u64 = 1;
const EWrongTrader: u64 = 2;
const EZeroCollateral: u64 = 3;

public struct Pool has key {
    id: UID,
    epoch_window_ms: u64,
    protocol_fee_bps: u64,
    treasury: address,
}

public struct OrderCommitment<phantom T> has key {
    id: UID,
    trader: address,
    sealed_envelope: vector<u8>,
    commit_hash: vector<u8>,
    collateral: Balance<T>,
    expiry_epoch: u64,
}

public struct SettlementReceipt has key, store {
    id: UID,
    trader: address,
    counterparty: address,
    filled_size: u64,
    filled_price: u64,
    deepbook_tx_digest: vector<u8>,
    enclave_signature: vector<u8>,
}

public struct OrderSubmitted has copy, drop {
    order_id: ID,
    trader: address,
    commit_hash: vector<u8>,
    expiry_epoch: u64,
}

public(package) fun create_pool(ctx: &mut TxContext) {
    transfer::share_object(Pool {
        id: object::new(ctx),
        epoch_window_ms: 10_000,
        protocol_fee_bps: 10,
        treasury: ctx.sender(),
    });
}

public fun submit_order<T>(
    sealed_envelope: vector<u8>,
    commit_hash: vector<u8>,
    collateral: Coin<T>,
    expiry_epoch: u64,
    ctx: &mut TxContext,
) {
    assert!(expiry_epoch > ctx.epoch(), EOrderExpired);
    assert!(collateral.value() > 0, EZeroCollateral);
    let order = OrderCommitment<T> {
        id: object::new(ctx),
        trader: ctx.sender(),
        sealed_envelope,
        commit_hash,
        collateral: collateral.into_balance(),
        expiry_epoch,
    };
    event::emit(OrderSubmitted {
        order_id: object::id(&order),
        trader: ctx.sender(),
        commit_hash: order.commit_hash,
        expiry_epoch,
    });
    transfer::share_object(order);
}

public fun cancel_expired<T>(order: OrderCommitment<T>, ctx: &mut TxContext): Coin<T> {
    assert!(order.trader == ctx.sender(), EWrongTrader);
    assert!(ctx.epoch() >= order.expiry_epoch, EOrderNotExpired);
    let OrderCommitment {
        id,
        trader: _,
        sealed_envelope: _,
        commit_hash: _,
        collateral,
        expiry_epoch: _,
    } = order;
    id.delete();
    coin::from_balance(collateral, ctx)
}

/// Trader-initiated cancel that works at any time. Refunds the
/// escrowed collateral. The enclave matcher will try to settle the
/// commitment until this is called or the expiry passes.
public fun cancel_anytime<T>(order: OrderCommitment<T>, ctx: &mut TxContext): Coin<T> {
    assert!(order.trader == ctx.sender(), EWrongTrader);
    let OrderCommitment {
        id,
        trader: _,
        sealed_envelope: _,
        commit_hash: _,
        collateral,
        expiry_epoch: _,
    } = order;
    id.delete();
    coin::from_balance(collateral, ctx)
}

public(package) fun consume<T>(order: OrderCommitment<T>): (address, vector<u8>, Balance<T>) {
    let OrderCommitment {
        id,
        trader,
        sealed_envelope: _,
        commit_hash,
        collateral,
        expiry_epoch: _,
    } = order;
    id.delete();
    (trader, commit_hash, collateral)
}

public(package) fun new_receipt(
    trader: address,
    counterparty: address,
    filled_size: u64,
    filled_price: u64,
    deepbook_tx_digest: vector<u8>,
    enclave_signature: vector<u8>,
    ctx: &mut TxContext,
): SettlementReceipt {
    SettlementReceipt {
        id: object::new(ctx),
        trader,
        counterparty,
        filled_size,
        filled_price,
        deepbook_tx_digest,
        enclave_signature,
    }
}

public fun protocol_fee_bps(pool: &Pool): u64 { pool.protocol_fee_bps }
public fun treasury(pool: &Pool): address { pool.treasury }

public(package) fun set_treasury(pool: &mut Pool, new_treasury: address) {
    pool.treasury = new_treasury;
}

public(package) fun set_protocol_fee_bps(pool: &mut Pool, new_fee_bps: u64) {
    pool.protocol_fee_bps = new_fee_bps;
}

