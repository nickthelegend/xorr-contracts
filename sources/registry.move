module xorr_contracts::registry {
    use sui::object::{Self, UID};
    use sui::dynamic_field;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    struct XorrRegistry has key {
        id: UID,
        pool_count: u64,
        protocol_version: u8,
    }

    public fun create_registry(ctx: &mut TxContext) {
        let registry = XorrRegistry {
            id: object::new(ctx),
            pool_count: 0,
            protocol_version: 1,
        };
        transfer::share_object(registry);
    }

    public fun register_pool(
        registry: &mut XorrRegistry,
        pool_key: vector<u8>,
        pool_id: address
    ) {
        dynamic_field::add(&mut registry.id, pool_key, pool_id);
        registry.pool_count = registry.pool_count + 1;
    }

    public fun get_pool(registry: &XorrRegistry, pool_key: vector<u8>): address {
        *dynamic_field::borrow(&registry.id, pool_key)
    }
}
