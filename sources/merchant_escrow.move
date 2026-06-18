/// Merchant payment escrow — the Move port of `PolarisMerchantEscrow.sol`.
/// A `MerchantEscrow<T>` is a shared object holding settled funds in `T`. The
/// merchant holds a `MerchantCap` and withdraws. Payments arrive either
/// directly (a shopper calling `settle_payment`) or via a BNPL disbursement
/// from the lending pool (`deposit`, package-internal).
module xorr_contracts::merchant_escrow;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;

const ENotMerchant: u64 = 0;
const EZeroAmount: u64 = 1;

public struct MerchantEscrow<phantom T> has key {
    id: UID,
    merchant: address,
    balance: Balance<T>,
    total_settled: u64,
}

/// Bearer capability authorizing withdrawal from a specific escrow.
public struct MerchantCap has key, store {
    id: UID,
    escrow_id: ID,
}

public struct EscrowCreated has copy, drop { escrow_id: ID, merchant: address }
public struct PaymentSettled has copy, drop { escrow_id: ID, payer: address, amount: u64, order_id: vector<u8> }
public struct MerchantWithdrawn has copy, drop { escrow_id: ID, merchant: address, amount: u64 }

/// Create and share an escrow for the caller; returns the merchant cap.
public fun create_escrow<T>(ctx: &mut TxContext): MerchantCap {
    let escrow = MerchantEscrow<T> {
        id: object::new(ctx),
        merchant: ctx.sender(),
        balance: balance::zero<T>(),
        total_settled: 0,
    };
    let escrow_id = object::id(&escrow);
    event::emit(EscrowCreated { escrow_id, merchant: ctx.sender() });
    transfer::share_object(escrow);
    MerchantCap { id: object::new(ctx), escrow_id }
}

entry fun create_escrow_entry<T>(ctx: &mut TxContext) {
    let cap = create_escrow<T>(ctx);
    transfer::public_transfer(cap, ctx.sender());
}

/// Direct settlement: a shopper pays `payment` into the merchant escrow.
public fun settle_payment<T>(
    escrow: &mut MerchantEscrow<T>,
    payment: Coin<T>,
    order_id: vector<u8>,
    ctx: &TxContext,
) {
    let amount = payment.value();
    assert!(amount > 0, EZeroAmount);
    escrow.total_settled = escrow.total_settled + amount;
    balance::join(&mut escrow.balance, payment.into_balance());
    event::emit(PaymentSettled { escrow_id: object::id(escrow), payer: ctx.sender(), amount, order_id });
}

/// BNPL disbursement: the lending engine pays the merchant up-front with a
/// balance split out of the pool. Package-internal — only `bnpl` calls it.
public(package) fun deposit<T>(
    escrow: &mut MerchantEscrow<T>,
    funds: Balance<T>,
    payer: address,
    order_id: vector<u8>,
) {
    let amount = balance::value(&funds);
    escrow.total_settled = escrow.total_settled + amount;
    balance::join(&mut escrow.balance, funds);
    event::emit(PaymentSettled { escrow_id: object::id(escrow), payer, amount, order_id });
}

/// Merchant withdraws the full escrow balance.
public fun withdraw<T>(escrow: &mut MerchantEscrow<T>, cap: &MerchantCap, ctx: &mut TxContext): Coin<T> {
    assert!(cap.escrow_id == object::id(escrow), ENotMerchant);
    let amount = balance::value(&escrow.balance);
    let out = balance::split(&mut escrow.balance, amount);
    event::emit(MerchantWithdrawn { escrow_id: object::id(escrow), merchant: escrow.merchant, amount });
    coin::from_balance(out, ctx)
}

public fun balance_value<T>(escrow: &MerchantEscrow<T>): u64 { balance::value(&escrow.balance) }
public fun total_settled<T>(escrow: &MerchantEscrow<T>): u64 { escrow.total_settled }
public fun merchant<T>(escrow: &MerchantEscrow<T>): address { escrow.merchant }
