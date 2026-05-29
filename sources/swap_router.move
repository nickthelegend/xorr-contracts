module xorr_contracts::swap_router {
    use sui::coin::{Self, Coin};
    use sui::tx_context::TxContext;
    use xorr_contracts::liquidity_pool::{Self, Pool};

    // Single-hop swap: Coin<A> → Coin<B>
    // For multi-hop, chain calls in a Programmable Transaction Block client-side.
    // e.g. swap_a_to_b(pool_AB, coinA) → coinB → swap_a_to_b(pool_BC, coinB) → coinC
    public fun swap_a_to_b<A, B>(
        pool: &mut Pool<A, B>,
        coin_in: Coin<A>,
        min_out: u64,
        ctx: &mut TxContext
    ): Coin<B> {
        let amount_in = coin::value(&coin_in);
        let (reserve_a, reserve_b) = liquidity_pool::get_tvl(pool);
        let fee = amount_in * 30 / 10_000; // 0.3%
        let amount_after_fee = amount_in - fee;
        // Constant product: out = (reserve_b * amount_in) / (reserve_a + amount_in)
        let amount_out = (reserve_b * amount_after_fee) / (reserve_a + amount_after_fee);
        assert!(amount_out >= min_out, 0); // slippage guard
        // complete with balance deposit/withdraw operations
        abort 0 // placeholder
    }
}
