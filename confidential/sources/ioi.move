module xorr::ioi;

use enclave::enclave::Enclave;
use xorr::xorr::{Self as xorr_mod, XORR};
use sui::event;

const ENotEnclave: u64 = 0;

/// Emitted by a trader's agent right after uploading an IOI ciphertext
/// to Walrus. Carries only the public coordinates: the agent that posted
/// it, the Walrus content address, and an absolute expiry.
public struct IoisPosted has copy, drop {
    agent_id: address,
    blob_id: vector<u8>,
    expiry_epoch: u64,
}

/// Emitted by the registered XORR enclave after pairing two IOIs and
/// writing per-side proposal blobs to Walrus. The two agent addresses
/// let each side filter by ownership; the two blob IDs point at the
/// proposal each respective side should read.
public struct MatchProposed has copy, drop {
    buy_agent: address,
    sell_agent: address,
    buy_blob_id: vector<u8>,
    sell_blob_id: vector<u8>,
}

/// Anyone can post an IOI. The ciphertext lives off-chain on Walrus;
/// only the registered enclave can decrypt it (Seal IBE under the same
/// identity used by orders). The on-chain record is just a routing
/// signal so the enclave's poller picks it up.
public fun record_ioi(blob_id: vector<u8>, expiry_epoch: u64, ctx: &mut TxContext) {
    event::emit(IoisPosted {
        agent_id: ctx.sender(),
        blob_id,
        expiry_epoch,
    });
}

/// Only the registered enclave may emit a match proposal. Auth is the
/// same shape used by `seal_approve`: the caller's sender must match
/// the enclave's on-chain-registered pubkey-derived address.
public fun propose_match(
    enclave: &Enclave<XORR>,
    buy_agent: address,
    sell_agent: address,
    buy_blob_id: vector<u8>,
    sell_blob_id: vector<u8>,
    ctx: &TxContext,
) {
    assert!(ctx.sender() == xorr_mod::enclave_address(enclave), ENotEnclave);
    event::emit(MatchProposed {
        buy_agent,
        sell_agent,
        buy_blob_id,
        sell_blob_id,
    });
}
