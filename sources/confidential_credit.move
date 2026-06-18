/// Confidential credit scoring — the TEE-attested half of XORR's privacy story.
///
/// A credit-scoring enclave (AWS Nitro) computes a borrower's credit score
/// privately off-chain (their income/debts/history never hit the public
/// ledger) and signs `(borrower, score, approved_limit)`. This module verifies
/// that ed25519 signature on-chain against a registered enclave public key and
/// lifts the borrower's credit line accordingly.
///
/// This mirrors `shell::attestation::verify_v2` (the dark-pool match verifier
/// preserved on the `confidential-defi` branch), reduced to the primitive that
/// matters here: an enclave-signed intent message verified with `sui::ed25519`.
/// The full Nautilus PCR-attestation wrapper can be layered back in when the
/// credit enclave is built — the signing key registered here becomes the
/// enclave's attested key.
module xorr_contracts::confidential_credit;

use std::bcs;
use sui::ed25519;
use sui::event;
use xorr_contracts::credit::{Self, CreditProfile};

const EBadSignature: u64 = 0;
const ENotAdmin: u64 = 1;
const ENoEnclaveKey: u64 = 2;

/// Intent-scope byte distinguishing credit attestations from other signed
/// payloads (matches the enclave's signing convention).
const CREDIT_INTENT: u8 = 1;

/// One-time witness for this module's init.
public struct CONFIDENTIAL_CREDIT has drop {}

/// Shared oracle pinning the credit-scoring enclave's ed25519 public key.
public struct CreditOracle has key {
    id: UID,
    admin: address,
    enclave_pubkey: vector<u8>, // 32-byte ed25519 key; empty until registered
}

/// Admin capability to register / rotate the enclave key.
public struct OracleAdminCap has key, store {
    id: UID,
    oracle_id: ID,
}

/// The exact message the enclave BCS-encodes and signs. The Rust signer in the
/// credit enclave MUST serialize a struct with these fields, in this order.
public struct CreditAttestation has copy, drop {
    intent: u8,
    timestamp_ms: u64,
    borrower: address,
    score: u64,
    approved_limit: u64,
    nonce: u64,
}

public struct EnclaveKeySet has copy, drop { oracle_id: ID, pubkey: vector<u8> }
public struct ScoreApplied has copy, drop { borrower: address, score: u64, approved_limit: u64, nonce: u64 }

fun init(_otw: CONFIDENTIAL_CREDIT, ctx: &mut TxContext) {
    let oracle = CreditOracle {
        id: object::new(ctx),
        admin: ctx.sender(),
        enclave_pubkey: b"",
    };
    let oracle_id = object::id(&oracle);
    transfer::share_object(oracle);
    transfer::public_transfer(OracleAdminCap { id: object::new(ctx), oracle_id }, ctx.sender());
}

/// Register (or rotate) the enclave's ed25519 public key. Admin-gated.
public fun set_enclave_pubkey(cap: &OracleAdminCap, oracle: &mut CreditOracle, pubkey: vector<u8>) {
    assert!(cap.oracle_id == object::id(oracle), ENotAdmin);
    oracle.enclave_pubkey = pubkey;
    event::emit(EnclaveKeySet { oracle_id: object::id(oracle), pubkey });
}

/// Verify a TEE-signed private credit score and apply it to the borrower's
/// profile, lifting their credit line. Aborts if the signature is invalid.
public fun verify_and_apply_score(
    oracle: &CreditOracle,
    profile: &mut CreditProfile,
    score: u64,
    approved_limit: u64,
    nonce: u64,
    timestamp_ms: u64,
    signature: vector<u8>,
) {
    assert!(oracle.enclave_pubkey.length() == 32, ENoEnclaveKey);
    let msg = CreditAttestation {
        intent: CREDIT_INTENT,
        timestamp_ms,
        borrower: credit::borrower(profile),
        score,
        approved_limit,
        nonce,
    };
    let bytes = bcs::to_bytes(&msg);
    let ok = ed25519::ed25519_verify(&signature, &oracle.enclave_pubkey, &bytes);
    assert!(ok, EBadSignature);

    credit::apply_attested_score(profile, score, approved_limit);
    event::emit(ScoreApplied { borrower: credit::borrower(profile), score, approved_limit, nonce });
}

public fun enclave_pubkey(oracle: &CreditOracle): vector<u8> { oracle.enclave_pubkey }

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(CONFIDENTIAL_CREDIT {}, ctx)
}
