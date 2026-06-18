module xorr::settlement;

use xorr::attestation::{Self, MatchInstruction, MatchInstructionV2};
use xorr::pool::{Self, OrderCommitment, Pool};
use sui::balance;
use sui::coin::{Self, Coin};
use sui::clock::Clock;
use deepbook::pool::{Self as deepbook_pool, Pool as DeepBookPool};
use token::deep::DEEP;

const EOrderMismatch: u64 = 0;
const ETraderMismatch: u64 = 1;
const EBadSlippage: u64 = 2;
const EDeprecated: u64 = 3;
const ESelfMatch: u64 = 4;

const BPS_DENOM: u64 = 10_000;
const FLOAT_SCALING: u128 = 1_000_000_000; // retained for deprecated fn lint suppression

fun pow10(exp: u8): u128 {
    let mut result: u128 = 1;
    let mut i: u8 = 0;
    while (i < exp) {
        result = result * 10;
        i = i + 1;
    };
    result
}

/// DEPRECATED — this signature is retained only for Sui
/// upgrade-compatibility (`compatible` policy forbids removing or
/// changing public functions). The body aborts unconditionally;
/// callers must use `settle_direct` instead.
public fun settle<TBase, TQuote>(
    _instruction: MatchInstruction,
    _maker_order: OrderCommitment<TBase>,
    _taker_order: OrderCommitment<TQuote>,
    _pool: &mut DeepBookPool<TBase, TQuote>,
    _deep_in: Coin<DEEP>,
    _slippage_bps: u64,
    _clock: &Clock,
    _ctx: &mut TxContext,
) {
    let _ = BPS_DENOM;
    let _ = FLOAT_SCALING;
    let _ = EBadSlippage;
    abort EDeprecated
}

/// DEPRECATED — retained for upgrade compatibility. Use `settle_v2`.
public fun settle_direct<TBase, TQuote>(
    _instruction: MatchInstruction,
    _maker_order: OrderCommitment<TBase>,
    _taker_order: OrderCommitment<TQuote>,
    _ctx: &mut TxContext,
) {
    abort EDeprecated
}

/// Settle a matched pair with protocol fee collection.
///
/// Buyer pre-deposits `trade_value + fee_each` quote coin. At settlement,
/// `fee_each` is taken from buyer's deposit and another `fee_each` from
/// the remaining trade_value (seller's proceeds); both go to `pool.treasury`.
/// Seller nets `trade_value - fee_each`. Buyer gets the full base amount.
public fun settle_v2<TBase, TQuote>(
    instruction: MatchInstruction,
    maker_order: OrderCommitment<TBase>,
    taker_order: OrderCommitment<TQuote>,
    pool: &Pool,
    ctx: &mut TxContext,
) {
    let maker_order_id = object::id(&maker_order);
    let taker_order_id = object::id(&taker_order);

    let (
        maker,
        taker,
        instr_maker_id,
        instr_taker_id,
        filled_size,
        filled_price,
        deepbook_tx_digest,
        enclave_signature,
    ) = attestation::unpack(instruction);

    assert!(maker_order_id == instr_maker_id, EOrderMismatch);
    assert!(taker_order_id == instr_taker_id, EOrderMismatch);

    let (maker_trader, _, maker_base_balance) = pool::consume(maker_order);
    let (taker_trader, _, mut taker_quote_balance) = pool::consume(taker_order);
    assert!(maker_trader == maker, ETraderMismatch);
    assert!(taker_trader == taker, ETraderMismatch);
    assert!(maker != taker, ESelfMatch);

    let trade_value = (((filled_size as u128) * (filled_price as u128)) / FLOAT_SCALING) as u64;
    let fee_each = (((trade_value as u128) * (pool::protocol_fee_bps(pool) as u128)) / (BPS_DENOM as u128)) as u64;

    // Buyer's fee (from pre-deposited extra)
    let buyer_fee = balance::split(&mut taker_quote_balance, fee_each);
    // Seller's proceeds (exact trade_value); remainder refunded to buyer below
    let mut seller_proceeds = balance::split(&mut taker_quote_balance, trade_value);
    // Seller's fee deducted from their proceeds
    let seller_fee = balance::split(&mut seller_proceeds, fee_each);

    let mut fee_balance = buyer_fee;
    balance::join(&mut fee_balance, seller_fee);
    transfer::public_transfer(coin::from_balance(fee_balance, ctx), pool::treasury(pool));

    // Refund any excess quote to buyer (price improvement when fill < limit price)
    if (balance::value(&taker_quote_balance) > 0) {
        transfer::public_transfer(coin::from_balance(taker_quote_balance, ctx), taker);
    } else {
        balance::destroy_zero(taker_quote_balance);
    };

    transfer::public_transfer(coin::from_balance(seller_proceeds, ctx), maker);
    transfer::public_transfer(coin::from_balance(maker_base_balance, ctx), taker);

    let maker_receipt = pool::new_receipt(
        maker, taker, filled_size, filled_price,
        deepbook_tx_digest, enclave_signature, ctx,
    );
    let taker_receipt = pool::new_receipt(
        taker, maker, filled_size, filled_price,
        deepbook_tx_digest, enclave_signature, ctx,
    );
    transfer::public_transfer(maker_receipt, maker);
    transfer::public_transfer(taker_receipt, taker);
}

/// Same as `settle_v2` but uses `base_decimals` from the signed
/// `MatchInstructionV2` for correct trade-value scaling on non-SUI pairs.
public fun settle_v3<TBase, TQuote>(
    instruction: attestation::MatchInstructionV2,
    maker_order: OrderCommitment<TBase>,
    taker_order: OrderCommitment<TQuote>,
    pool: &Pool,
    ctx: &mut TxContext,
) {
    let maker_order_id = object::id(&maker_order);
    let taker_order_id = object::id(&taker_order);

    let (
        maker,
        taker,
        instr_maker_id,
        instr_taker_id,
        filled_size,
        filled_price,
        base_decimals,
        deepbook_tx_digest,
        enclave_signature,
    ) = attestation::unpack_v2(instruction);

    assert!(maker_order_id == instr_maker_id, EOrderMismatch);
    assert!(taker_order_id == instr_taker_id, EOrderMismatch);

    let (maker_trader, _, maker_base_balance) = pool::consume(maker_order);
    let (taker_trader, _, mut taker_quote_balance) = pool::consume(taker_order);
    assert!(maker_trader == maker, ETraderMismatch);
    assert!(taker_trader == taker, ETraderMismatch);
    assert!(maker != taker, ESelfMatch);

    let float_scaling = pow10(base_decimals);
    let trade_value = (((filled_size as u128) * (filled_price as u128)) / float_scaling) as u64;
    let fee_each = (((trade_value as u128) * (pool::protocol_fee_bps(pool) as u128)) / (BPS_DENOM as u128)) as u64;

    let buyer_fee = balance::split(&mut taker_quote_balance, fee_each);
    let mut seller_proceeds = balance::split(&mut taker_quote_balance, trade_value);
    let seller_fee = balance::split(&mut seller_proceeds, fee_each);

    let mut fee_balance = buyer_fee;
    balance::join(&mut fee_balance, seller_fee);
    transfer::public_transfer(coin::from_balance(fee_balance, ctx), pool::treasury(pool));

    if (balance::value(&taker_quote_balance) > 0) {
        transfer::public_transfer(coin::from_balance(taker_quote_balance, ctx), taker);
    } else {
        balance::destroy_zero(taker_quote_balance);
    };

    transfer::public_transfer(coin::from_balance(seller_proceeds, ctx), maker);
    transfer::public_transfer(coin::from_balance(maker_base_balance, ctx), taker);

    let maker_receipt = pool::new_receipt(
        maker, taker, filled_size, filled_price,
        deepbook_tx_digest, enclave_signature, ctx,
    );
    let taker_receipt = pool::new_receipt(
        taker, maker, filled_size, filled_price,
        deepbook_tx_digest, enclave_signature, ctx,
    );
    transfer::public_transfer(maker_receipt, maker);
    transfer::public_transfer(taker_receipt, taker);
}

/// Canonical self-match-aware settlement entrypoint.
///
/// Same body as `settle_v3` with the explicit `maker != taker` guard.
/// SDK + enclave route new traffic here; `settle_v2` / `settle_v3` remain
/// callable with the same guard for defense-in-depth on legacy callers.
public fun settle_v4<TBase, TQuote>(
    instruction: attestation::MatchInstructionV2,
    maker_order: OrderCommitment<TBase>,
    taker_order: OrderCommitment<TQuote>,
    pool: &Pool,
    ctx: &mut TxContext,
) {
    let maker_order_id = object::id(&maker_order);
    let taker_order_id = object::id(&taker_order);

    let (
        maker,
        taker,
        instr_maker_id,
        instr_taker_id,
        filled_size,
        filled_price,
        base_decimals,
        deepbook_tx_digest,
        enclave_signature,
    ) = attestation::unpack_v2(instruction);

    assert!(maker_order_id == instr_maker_id, EOrderMismatch);
    assert!(taker_order_id == instr_taker_id, EOrderMismatch);
    assert!(maker != taker, ESelfMatch);

    let (maker_trader, _, maker_base_balance) = pool::consume(maker_order);
    let (taker_trader, _, mut taker_quote_balance) = pool::consume(taker_order);
    assert!(maker_trader == maker, ETraderMismatch);
    assert!(taker_trader == taker, ETraderMismatch);

    let float_scaling = pow10(base_decimals);
    let trade_value = (((filled_size as u128) * (filled_price as u128)) / float_scaling) as u64;
    let fee_each = (((trade_value as u128) * (pool::protocol_fee_bps(pool) as u128)) / (BPS_DENOM as u128)) as u64;

    let buyer_fee = balance::split(&mut taker_quote_balance, fee_each);
    let mut seller_proceeds = balance::split(&mut taker_quote_balance, trade_value);
    let seller_fee = balance::split(&mut seller_proceeds, fee_each);

    let mut fee_balance = buyer_fee;
    balance::join(&mut fee_balance, seller_fee);
    transfer::public_transfer(coin::from_balance(fee_balance, ctx), pool::treasury(pool));

    if (balance::value(&taker_quote_balance) > 0) {
        transfer::public_transfer(coin::from_balance(taker_quote_balance, ctx), taker);
    } else {
        balance::destroy_zero(taker_quote_balance);
    };

    transfer::public_transfer(coin::from_balance(seller_proceeds, ctx), maker);
    transfer::public_transfer(coin::from_balance(maker_base_balance, ctx), taker);

    let maker_receipt = pool::new_receipt(
        maker, taker, filled_size, filled_price,
        deepbook_tx_digest, enclave_signature, ctx,
    );
    let taker_receipt = pool::new_receipt(
        taker, maker, filled_size, filled_price,
        deepbook_tx_digest, enclave_signature, ctx,
    );
    transfer::public_transfer(maker_receipt, maker);
    transfer::public_transfer(taker_receipt, taker);
}
