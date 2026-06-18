module xorr_contracts::usdt;

use sui::coin::{Self, Coin, TreasuryCap};

const EFaucetLimit: u64 = 0;

/// Max a single faucet call can mint: 10,000 USDT (6 decimals).
const MAX_FAUCET_MINT: u64 = 10_000_000_000;

/// One-time witness for the test USDT currency.
public struct USDT has drop {}

/// Shared faucet wrapping the `TreasuryCap` so the dApp faucet page can mint
/// test USDT permissionlessly (capped per call). Test / hackathon only — a
/// real asset would keep the cap private and gate minting.
public struct Faucet has key {
    id: UID,
    treasury: TreasuryCap<USDT>,
}

fun init(witness: USDT, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        6,
        b"USDT",
        b"Tether USD (Test)",
        b"Test USDT for the XORR Buy-Now-Pay-Never demo on Sui",
        option::none(),
        ctx,
    );
    transfer::public_freeze_object(metadata);
    transfer::share_object(Faucet {
        id: object::new(ctx),
        treasury: treasury_cap,
    });
}

/// Mint up to `MAX_FAUCET_MINT` test USDT and return the coin to the caller.
public fun faucet_mint(faucet: &mut Faucet, amount: u64, ctx: &mut TxContext): Coin<USDT> {
    assert!(amount <= MAX_FAUCET_MINT, EFaucetLimit);
    coin::mint(&mut faucet.treasury, amount, ctx)
}

/// Entry convenience used by the frontend faucet: mint and send to sender.
entry fun faucet_to_sender(faucet: &mut Faucet, amount: u64, ctx: &mut TxContext) {
    let c = faucet_mint(faucet, amount, ctx);
    transfer::public_transfer(c, ctx.sender());
}

/// Burn test USDT back through the faucet treasury.
public fun burn(faucet: &mut Faucet, c: Coin<USDT>) {
    coin::burn(&mut faucet.treasury, c);
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(USDT {}, ctx)
}
