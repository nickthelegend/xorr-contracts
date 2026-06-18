module xorr::xorr;

use enclave::enclave::{Self, Cap, Enclave};
use xorr::pool::{Self, Pool};
use std::string;
use sui::address;
use sui::hash;

const ENotEnclave: u64 = 0;

/// One-time witness pinning every `enclave::*` generic in this package
/// to the XORR instantiation.
public struct XORR has drop {}

fun init(otw: XORR, ctx: &mut TxContext) {
    let cap = enclave::new_cap(otw, ctx);
    cap.create_enclave_config(
        string::utf8(b"xorr confidential enclave"),
        // Placeholder PCRs; admin loads real values post-deploy via
        // `enclave::update_pcrs` once the matching enclave is built.
        x"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        x"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        x"000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        ctx,
    );
    pool::create_pool(ctx);
    transfer::public_transfer(cap, ctx.sender());
}

/// Sui address derived from the enclave's raw ed25519 pubkey:
/// `blake2b256(0x00 || pk)`. The 0x00 byte is Sui's ed25519 scheme flag.
public fun enclave_address(enclave: &Enclave<XORR>): address {
    let mut bytes = vector[0u8];
    bytes.append(*enclave.pk());
    address::from_bytes(hash::blake2b256(&bytes))
}

/// Seal policy gating decryption of a XORR order envelope.
///
/// Released only when the requester is the registered enclave. Seal's
/// key-server dry-run sets `ctx.sender()` to the wallet that signed the
/// fetch_key request, so this check authenticates the enclave by its
/// on-chain-registered signing key.
///
/// `id` is the Seal identity bytes (the per-order nonce the client
/// passed at encrypt time); it is not validated here — Seal already
/// derives a distinct IBE key per `(pkg, id)` pair.
entry fun seal_approve(_id: vector<u8>, enclave: &Enclave<XORR>, ctx: &TxContext) {
    assert!(ctx.sender() == enclave_address(enclave), ENotEnclave);
}

/// Update the treasury address that receives protocol fees.
/// Requires the XORR admin cap (owned by the deployer).
entry fun set_pool_treasury(_cap: &Cap<XORR>, pool: &mut Pool, new_treasury: address) {
    pool::set_treasury(pool, new_treasury);
}

/// Update the protocol fee in basis points (e.g. 10 = 0.1%, 50 = 0.5%).
/// Requires the XORR admin cap (owned by the deployer).
entry fun set_pool_fee_bps(_cap: &Cap<XORR>, pool: &mut Pool, new_fee_bps: u64) {
    pool::set_protocol_fee_bps(pool, new_fee_bps);
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(XORR {}, ctx)
}
