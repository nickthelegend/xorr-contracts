#[test_only]
module xorr_contracts::xorr_tests {
    use sui::test_scenario::{Self};
    use xorr_contracts::registry::{Self, XorrRegistry};
    use xorr_contracts::usdo::{USDO};
    use xorr_contracts::xorr::{XORR};
    use xorr_contracts::liquidity_pool::{Self};

    #[test]
    fun test_e2e_flow() {
        let admin = @0xAD;
        let mut scenario = test_scenario::begin(admin);

        // 1. Test Registry creation
        test_scenario::next_tx(&mut scenario, admin);
        {
            registry::create_registry(test_scenario::ctx(&mut scenario));
        };

        // 2. Verify Registry exists and we can register a pool
        test_scenario::next_tx(&mut scenario, admin);
        {
            let mut reg = test_scenario::take_shared<XorrRegistry>(&scenario);
            let pool_key = b"SUI_USDC";
            let pool_addr = @0x1234;

            registry::register_pool(&mut reg, pool_key, pool_addr);
            assert!(registry::get_pool(&reg, pool_key) == pool_addr, 0);

            test_scenario::return_shared(reg);
        };

        // 3. Test Pool creation and liquidity snapshot
        test_scenario::next_tx(&mut scenario, admin);
        {
            let pool = liquidity_pool::create_pool<XORR, USDO>(30, test_scenario::ctx(&mut scenario));
            let (a, b) = liquidity_pool::get_tvl(&pool);
            assert!(a == 0 && b == 0, 1);

            liquidity_pool::share_pool(pool);
        };

        test_scenario::end(scenario);
    }
}
