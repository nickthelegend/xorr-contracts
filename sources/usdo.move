module xorr_contracts::usdo {
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    public struct USDO has drop {}

    fun init(witness: USDO, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness,
            6,
            b"USDO",
            b"Xorr USD Stable",
            b"Decentralized stablecoin for the Xorr Finance agentic trading platform",
            option::none(),
            ctx
        );
        transfer::public_freeze_object(metadata);
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    }

    public fun mint(
        treasury_cap: &mut TreasuryCap<USDO>,
        amount: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        coin::mint_and_transfer(treasury_cap, amount, recipient, ctx)
    }

    public fun burn(treasury_cap: &mut TreasuryCap<USDO>, coin: Coin<USDO>) {
        coin::burn(treasury_cap, coin);
    }

    // stub field / function for future oracle integration
    public fun get_price_feed(): u64 {
        1000000 // 1.000000 USD (6 decimals precision)
    }
}
