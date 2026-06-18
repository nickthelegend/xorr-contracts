#[test_only]
module xorr::self_match_tests;

use xorr::attestation;
use xorr::pool::{Self, Pool, OrderCommitment};
use xorr::settlement;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;

const TRADER_A: address = @0xA1;

const ENV: vector<u8> = b"sealed-ciphertext-bytes";
const HASH_MAKER: vector<u8> = b"commit-hash-maker-32-bytes------";
const HASH_TAKER: vector<u8> = b"commit-hash-taker-32-bytes------";
const FAKE_DIGEST: vector<u8> = b"deepbook-tx-digest-32-bytes-----";
const FAKE_SIG: vector<u8> = b"fake-enclave-signature-64-bytes------------------------------------";

/// `settle_v4` must abort with `ESelfMatch` when maker_addr == taker_addr.
#[test, expected_failure(abort_code = settlement::ESelfMatch)]
fun settle_v4_rejects_self_match() {
    let mut s = ts::begin(TRADER_A);
    xorr::xorr::init_for_testing(s.ctx());

    s.next_tx(TRADER_A);
    let maker_coin = coin::mint_for_testing<SUI>(1_000_000, s.ctx());
    pool::submit_order<SUI>(ENV, HASH_MAKER, maker_coin, 5, s.ctx());

    s.next_tx(TRADER_A);
    let taker_coin = coin::mint_for_testing<SUI>(2_000_000, s.ctx());
    pool::submit_order<SUI>(ENV, HASH_TAKER, taker_coin, 5, s.ctx());

    s.next_tx(TRADER_A);
    let maker_order = s.take_shared<OrderCommitment<SUI>>();
    let taker_order = s.take_shared<OrderCommitment<SUI>>();
    let pool = s.take_shared<Pool>();

    let maker_id = object::id(&maker_order);
    let taker_id = object::id(&taker_order);

    let instr = attestation::new_v2_for_testing(
        TRADER_A,
        TRADER_A,
        maker_id,
        taker_id,
        1_000_000,
        1_000_000_000,
        9,
        FAKE_DIGEST,
        FAKE_SIG,
    );

    settlement::settle_v4<SUI, SUI>(instr, maker_order, taker_order, &pool, s.ctx());

    ts::return_shared(pool);
    s.end();
}

/// Legacy `settle_v3` must also block self-match (defense-in-depth).
#[test, expected_failure(abort_code = settlement::ESelfMatch)]
fun settle_v3_rejects_self_match_legacy() {
    let mut s = ts::begin(TRADER_A);
    xorr::xorr::init_for_testing(s.ctx());

    s.next_tx(TRADER_A);
    let maker_coin = coin::mint_for_testing<SUI>(1_000_000, s.ctx());
    pool::submit_order<SUI>(ENV, HASH_MAKER, maker_coin, 5, s.ctx());

    s.next_tx(TRADER_A);
    let taker_coin = coin::mint_for_testing<SUI>(2_000_000, s.ctx());
    pool::submit_order<SUI>(ENV, HASH_TAKER, taker_coin, 5, s.ctx());

    s.next_tx(TRADER_A);
    let maker_order = s.take_shared<OrderCommitment<SUI>>();
    let taker_order = s.take_shared<OrderCommitment<SUI>>();
    let pool = s.take_shared<Pool>();

    let maker_id = object::id(&maker_order);
    let taker_id = object::id(&taker_order);

    let instr = attestation::new_v2_for_testing(
        TRADER_A,
        TRADER_A,
        maker_id,
        taker_id,
        1_000_000,
        1_000_000_000,
        9,
        FAKE_DIGEST,
        FAKE_SIG,
    );

    settlement::settle_v3<SUI, SUI>(instr, maker_order, taker_order, &pool, s.ctx());

    ts::return_shared(pool);
    s.end();
}
