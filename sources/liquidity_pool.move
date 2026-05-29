module xorr_contracts::liquidity_pool {
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::object::{Self, UID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    struct Pool<phantom A, phantom B> has key {
        id: UID,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
        lp_supply: u64,
        fee_bps: u64,      // e.g. 30 = 0.3%
        tvl_snapshot: u64,
    }

    public fun create_pool<A, B>(fee_bps: u64, ctx: &mut TxContext): Pool<A, B> {
        Pool {
            id: object::new(ctx),
            balance_a: balance::zero<A>(),
            balance_b: balance::zero<B>(),
            lp_supply: 0,
            fee_bps,
            tvl_snapshot: 0,
        }
    }

    public fun add_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        ctx: &mut TxContext
    ): u64 {
        let amount_a = coin::value(&coin_a);
        let amount_b = coin::value(&coin_b);
        balance::join(&mut pool.balance_a, coin::into_balance(coin_a));
        balance::join(&mut pool.balance_b, coin::into_balance(coin_b));
        let lp_minted = (amount_a + amount_b) / 2; // replace with sqrt(a*b) in prod
        pool.lp_supply = pool.lp_supply + lp_minted;
        lp_minted
    }

    public fun remove_liquidity<A, B>(
        pool: &mut Pool<A, B>,
        lp_amount: u64,
        ctx: &mut TxContext
    ): (Coin<A>, Coin<B>) {
        let ratio = lp_amount * 1_000_000 / pool.lp_supply;
        let out_a = balance::value(&pool.balance_a) * ratio / 1_000_000;
        let out_b = balance::value(&pool.balance_b) * ratio / 1_000_000;
        pool.lp_supply = pool.lp_supply - lp_amount;
        (
            coin::from_balance(balance::split(&mut pool.balance_a, out_a), ctx),
            coin::from_balance(balance::split(&mut pool.balance_b, out_b), ctx),
        )
    }

    public fun get_tvl<A, B>(pool: &Pool<A, B>): (u64, u64) {
        (balance::value(&pool.balance_a), balance::value(&pool.balance_b))
    }
}
