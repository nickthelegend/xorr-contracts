module xorr_contracts::usdc;

use sui::coin::{Self, Coin, TreasuryCap};

const EFaucetLimit: u64 = 0;

/// Max a single faucet call can mint: 10,000 USDC (6 decimals).
const MAX_FAUCET_MINT: u64 = 10_000_000_000;

/// One-time witness for the test USDC currency.
public struct USDC has drop {}

/// Shared faucet wrapping the `TreasuryCap` so the dApp faucet page can mint
/// test USDC permissionlessly (capped per call). Test / hackathon only — a
/// real asset would keep the cap private and gate minting.
public struct Faucet has key {
    id: UID,
    treasury: TreasuryCap<USDC>,
}

fun init(witness: USDC, ctx: &mut TxContext) {
    let (treasury_cap, metadata) = coin::create_currency(
        witness,
        6,
        b"USDC",
        b"USD Coin (Test)",
        b"Test USDC for the XORR Buy-Now-Pay-Never demo on Sui",
        option::none(),
        ctx,
    );
    transfer::public_freeze_object(metadata);
    transfer::share_object(Faucet {
        id: object::new(ctx),
        treasury: treasury_cap,
    });
}

/// Mint up to `MAX_FAUCET_MINT` test USDC and return the coin to the caller.
public fun faucet_mint(faucet: &mut Faucet, amount: u64, ctx: &mut TxContext): Coin<USDC> {
    assert!(amount <= MAX_FAUCET_MINT, EFaucetLimit);
    coin::mint(&mut faucet.treasury, amount, ctx)
}

/// Entry convenience used by the frontend faucet: mint and send to sender.
entry fun faucet_to_sender(faucet: &mut Faucet, amount: u64, ctx: &mut TxContext) {
    let c = faucet_mint(faucet, amount, ctx);
    transfer::public_transfer(c, ctx.sender());
}

/// Burn test USDC back through the faucet treasury.
public fun burn(faucet: &mut Faucet, c: Coin<USDC>) {
    coin::burn(&mut faucet.treasury, c);
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(USDC {}, ctx)
}
