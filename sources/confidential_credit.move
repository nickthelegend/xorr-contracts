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
use sui::clock::Clock;
use sui::ed25519;
use sui::event;
use sui::nitro_attestation::{Self, NitroAttestationDocument};
use xorr_contracts::credit::{Self, CreditProfile};

const EBadSignature: u64 = 0;
const ENotAdmin: u64 = 1;
const ENoEnclaveKey: u64 = 2;
const EPcrsNotSet: u64 = 3;
const EPcrMismatch: u64 = 4;
const ENoAttestedKey: u64 = 5;
const ENotAttestedAdmin: u64 = 6;
const EStaleAttestation: u64 = 7;

/// Max age of a TEE attestation accepted on-chain. An attestation older than
/// this is rejected, so a stale/replayed score (e.g. an old high limit after a
/// default) can't be re-applied — the borrower must fetch a fresh signature
/// that reflects their current state.
const MAX_ATTESTATION_AGE_MS: u64 = 600_000; // 10 minutes

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

// ============================================================================
// On-chain AWS Nitro attestation — PCR-gated key registration (Step 2).
//
// The original `CreditOracle` above trusts an admin-registered key (honest, but
// the chain can't tell a genuine enclave from any signing server). `AttestedOracle`
// instead binds the credit-signing key to a VERIFIED Nitro attestation document:
// `sui::nitro_attestation` checks the AWS cert chain + COSE signature natively,
// we assert the enclave-image PCRs match the pinned audited measurements, and we
// adopt the public key embedded in the attestation. That is the real
// "the audited enclave produced this" guarantee — no trust in the key registrar.
//
// Added as an upgrade-compatible extension (new structs/functions only), so the
// live BNPL/lending package id, pool, escrow, and coin are all undisturbed.
// ============================================================================

/// An enclave key bound to a verified Nitro attestation + pinned PCRs.
public struct AttestedOracle has key {
    id: UID,
    admin: address,
    enclave_pubkey: vector<u8>, // 32-byte ed25519 key, adopted from a verified attestation
    attested: bool,             // true once a real attestation registered the key
    pcr0: vector<u8>,           // expected measurements of the audited enclave image
    pcr1: vector<u8>,
    pcr2: vector<u8>,
}

public struct AttestedOracleCap has key, store { id: UID, oracle_id: ID }

public struct AttestedKeyRegistered has copy, drop { oracle_id: ID, pubkey: vector<u8> }
public struct AttestedPcrsSet has copy, drop { oracle_id: ID }

/// Create + share an `AttestedOracle` (an upgrade can't re-run `init`, so the
/// new object needs an explicit constructor). Returns the admin cap.
public fun create_attested_oracle(ctx: &mut TxContext): AttestedOracleCap {
    let oracle = AttestedOracle {
        id: object::new(ctx),
        admin: ctx.sender(),
        enclave_pubkey: b"",
        attested: false,
        pcr0: b"", pcr1: b"", pcr2: b"",
    };
    let oracle_id = object::id(&oracle);
    transfer::share_object(oracle);
    AttestedOracleCap { id: object::new(ctx), oracle_id }
}

entry fun create_attested_oracle_entry(ctx: &mut TxContext) {
    transfer::public_transfer(create_attested_oracle(ctx), ctx.sender());
}

/// Admin: pin the expected PCR0/1/2 (SHA-384, 48 bytes each) of the audited
/// enclave image. Only an attestation whose PCRs match these can register a key.
public fun set_attested_pcrs(
    cap: &AttestedOracleCap,
    oracle: &mut AttestedOracle,
    pcr0: vector<u8>,
    pcr1: vector<u8>,
    pcr2: vector<u8>,
) {
    assert!(cap.oracle_id == object::id(oracle), ENotAttestedAdmin);
    oracle.pcr0 = pcr0;
    oracle.pcr1 = pcr1;
    oracle.pcr2 = pcr2;
    event::emit(AttestedPcrsSet { oracle_id: object::id(oracle) });
}

/// Permissionless: verify a genuine AWS Nitro attestation on-chain, require its
/// PCRs match the pinned audited image, and adopt the embedded enclave key.
/// The `NitroAttestationDocument` is produced by `sui::nitro_attestation::
/// load_nitro_attestation` (which verifies the AWS PKI cert chain + COSE sig) in
/// a preceding PTB command.
public fun register_enclave_key(oracle: &mut AttestedOracle, document: NitroAttestationDocument) {
    assert!(oracle.pcr0.length() == 48, EPcrsNotSet);
    let pcrs = nitro_attestation::pcrs(&document);
    assert!(*pcrs[0].value() == oracle.pcr0, EPcrMismatch);
    assert!(*pcrs[1].value() == oracle.pcr1, EPcrMismatch);
    assert!(*pcrs[2].value() == oracle.pcr2, EPcrMismatch);
    let pk_opt = nitro_attestation::public_key(&document);
    assert!(pk_opt.is_some(), ENoAttestedKey);
    oracle.enclave_pubkey = *pk_opt.borrow();
    oracle.attested = true;
    event::emit(AttestedKeyRegistered { oracle_id: object::id(oracle), pubkey: oracle.enclave_pubkey });
}

/// Verify a TEE-signed credit score against the ATTESTATION-bound key and apply
/// it. Identical message format to `verify_and_apply_score`, but the key is
/// provably the audited enclave's, not an admin's assertion.
public fun verify_and_apply_score_attested(
    oracle: &AttestedOracle,
    profile: &mut CreditProfile,
    score: u64,
    approved_limit: u64,
    nonce: u64,
    timestamp_ms: u64,
    signature: vector<u8>,
) {
    assert!(oracle.attested && oracle.enclave_pubkey.length() == 32, ENoEnclaveKey);
    let msg = CreditAttestation {
        intent: CREDIT_INTENT,
        timestamp_ms,
        borrower: credit::borrower(profile),
        score,
        approved_limit,
        nonce,
    };
    let ok = ed25519::ed25519_verify(&signature, &oracle.enclave_pubkey, &bcs::to_bytes(&msg));
    assert!(ok, EBadSignature);
    credit::apply_attested_score(profile, score, approved_limit);
    event::emit(ScoreApplied { borrower: credit::borrower(profile), score, approved_limit, nonce });
}

/// Like `verify_and_apply_score_attested` but with on-chain FRESHNESS: rejects
/// attestations older than `MAX_ATTESTATION_AGE_MS` (and any future-dated ones).
/// This is the replay-safe entrypoint — an old signed score can't be re-applied.
public fun verify_and_apply_score_attested_v2(
    oracle: &AttestedOracle,
    profile: &mut CreditProfile,
    clock: &Clock,
    score: u64,
    approved_limit: u64,
    nonce: u64,
    timestamp_ms: u64,
    signature: vector<u8>,
) {
    assert!(oracle.attested && oracle.enclave_pubkey.length() == 32, ENoEnclaveKey);
    let now = clock.timestamp_ms();
    assert!(timestamp_ms <= now && now - timestamp_ms <= MAX_ATTESTATION_AGE_MS, EStaleAttestation);
    let msg = CreditAttestation {
        intent: CREDIT_INTENT,
        timestamp_ms,
        borrower: credit::borrower(profile),
        score,
        approved_limit,
        nonce,
    };
    let ok = ed25519::ed25519_verify(&signature, &oracle.enclave_pubkey, &bcs::to_bytes(&msg));
    assert!(ok, EBadSignature);
    credit::apply_attested_score(profile, score, approved_limit);
    event::emit(ScoreApplied { borrower: credit::borrower(profile), score, approved_limit, nonce });
}

public fun attested_pubkey(o: &AttestedOracle): vector<u8> { o.enclave_pubkey }
public fun attested_is_set(o: &AttestedOracle): bool { o.attested }
public fun attested_pcr0(o: &AttestedOracle): vector<u8> { o.pcr0 }

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(CONFIDENTIAL_CREDIT {}, ctx)
}
