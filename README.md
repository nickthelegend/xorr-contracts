# xorr-contracts
Sui Move smart contract package for Xorr Finance.

## Contracts
- `xorr.move` — XORR utility token
- `usdo.move` — USDO stable token
- `liquidity_pool.move` — AMM pools as shared objects
- `swap_router.move` — Single-hop swaps; multi-hop via PTBs client-side
- `registry.move` — Shared on-chain pool registry

## Deploy to testnet
sui client publish --gas-budget 200000000

## Run tests
sui move test
