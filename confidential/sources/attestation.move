module xorr::attestation;

use enclave::enclave::Enclave;
use xorr::xorr::XORR;

const MATCH_INTENT: u8 = 0;

const EBadSignature: u64 = 0;

/// The exact struct the enclave BCS-encodes and signs (wrapped in
/// `enclave::IntentMessage` with `MATCH_INTENT` and `timestamp_ms`).
/// Must match the Rust signer in nautilus-server.
public struct MatchPayload has copy, drop {
    maker: address,
    taker: address,
    maker_order: ID,
    taker_order: ID,
    filled_size: u64,
    filled_price: u64,
    deepbook_tx_digest: vector<u8>,
}

/// Hot-potato: no `key`, `store`, `copy`, or `drop`. Only constructed by
/// `verify` after a successful enclave signature check; only consumed by
/// `xorr::settlement::settle`. Cannot escape the PTB.
public struct MatchInstruction {
    maker: address,
    taker: address,
    maker_order: ID,
    taker_order: ID,
    filled_size: u64,
    filled_price: u64,
    deepbook_tx_digest: vector<u8>,
    enclave_signature: vector<u8>,
}

/// V2 payload — adds `base_decimals` so settle_v3 scales correctly for
/// non-9-decimal base coins (e.g. TBILL = 6, SUI = 9).
public struct MatchPayloadV2 has copy, drop {
    maker: address,
    taker: address,
    maker_order: ID,
    taker_order: ID,
    filled_size: u64,
    filled_price: u64,
    base_decimals: u8,
    deepbook_tx_digest: vector<u8>,
}

/// Hot-potato v2 — carries base_decimals from enclave signature through to settle_v3.
public struct MatchInstructionV2 {
    maker: address,
    taker: address,
    maker_order: ID,
    taker_order: ID,
    filled_size: u64,
    filled_price: u64,
    base_decimals: u8,
    deepbook_tx_digest: vector<u8>,
    enclave_signature: vector<u8>,
}

/// Verify a match signed by a registered XORR enclave, returning a
/// hot-potato that `xorr::settlement::settle` must consume in the same
/// PTB. Aborts if the signature does not check.
public fun verify(
    enclave: &Enclave<XORR>,
    timestamp_ms: u64,
    maker: address,
    taker: address,
    maker_order: ID,
    taker_order: ID,
    filled_size: u64,
    filled_price: u64,
    deepbook_tx_digest: vector<u8>,
    signature: vector<u8>,
): MatchInstruction {
    let payload = MatchPayload {
        maker,
        taker,
        maker_order,
        taker_order,
        filled_size,
        filled_price,
        deepbook_tx_digest,
    };
    let ok = enclave.verify_signature(MATCH_INTENT, timestamp_ms, payload, &signature);
    assert!(ok, EBadSignature);

    MatchInstruction {
        maker,
        taker,
        maker_order,
        taker_order,
        filled_size,
        filled_price,
        deepbook_tx_digest,
        enclave_signature: signature,
    }
}

/// V2 verify — signs over MatchPayloadV2 which includes base_decimals.
/// The enclave must include base_decimals in the BCS payload it signs.
public fun verify_v2(
    enclave: &Enclave<XORR>,
    timestamp_ms: u64,
    maker: address,
    taker: address,
    maker_order: ID,
    taker_order: ID,
    filled_size: u64,
    filled_price: u64,
    base_decimals: u8,
    deepbook_tx_digest: vector<u8>,
    signature: vector<u8>,
): MatchInstructionV2 {
    let payload = MatchPayloadV2 {
        maker,
        taker,
        maker_order,
        taker_order,
        filled_size,
        filled_price,
        base_decimals,
        deepbook_tx_digest,
    };
    let ok = enclave.verify_signature(MATCH_INTENT, timestamp_ms, payload, &signature);
    assert!(ok, EBadSignature);

    MatchInstructionV2 {
        maker,
        taker,
        maker_order,
        taker_order,
        filled_size,
        filled_price,
        base_decimals,
        deepbook_tx_digest,
        enclave_signature: signature,
    }
}

public(package) fun unpack(
    instr: MatchInstruction,
): (address, address, ID, ID, u64, u64, vector<u8>, vector<u8>) {
    let MatchInstruction {
        maker,
        taker,
        maker_order,
        taker_order,
        filled_size,
        filled_price,
        deepbook_tx_digest,
        enclave_signature,
    } = instr;
    (
        maker,
        taker,
        maker_order,
        taker_order,
        filled_size,
        filled_price,
        deepbook_tx_digest,
        enclave_signature,
    )
}

public(package) fun unpack_v2(
    instr: MatchInstructionV2,
): (address, address, ID, ID, u64, u64, u8, vector<u8>, vector<u8>) {
    let MatchInstructionV2 {
        maker,
        taker,
        maker_order,
        taker_order,
        filled_size,
        filled_price,
        base_decimals,
        deepbook_tx_digest,
        enclave_signature,
    } = instr;
    (
        maker,
        taker,
        maker_order,
        taker_order,
        filled_size,
        filled_price,
        base_decimals,
        deepbook_tx_digest,
        enclave_signature,
    )
}

#[test_only]
public fun new_for_testing(
    maker: address,
    taker: address,
    maker_order: ID,
    taker_order: ID,
    filled_size: u64,
    filled_price: u64,
    deepbook_tx_digest: vector<u8>,
    enclave_signature: vector<u8>,
): MatchInstruction {
    MatchInstruction {
        maker,
        taker,
        maker_order,
        taker_order,
        filled_size,
        filled_price,
        deepbook_tx_digest,
        enclave_signature,
    }
}

#[test_only]
public fun new_v2_for_testing(
    maker: address,
    taker: address,
    maker_order: ID,
    taker_order: ID,
    filled_size: u64,
    filled_price: u64,
    base_decimals: u8,
    deepbook_tx_digest: vector<u8>,
    enclave_signature: vector<u8>,
): MatchInstructionV2 {
    MatchInstructionV2 {
        maker,
        taker,
        maker_order,
        taker_order,
        filled_size,
        filled_price,
        base_decimals,
        deepbook_tx_digest,
        enclave_signature,
    }
}
