# FreeLP

FreeLP is an ownerless LP manager with enumerable ERC-721 positions. Deploy it with the Core and the shared `PoolKeyIndex` for that Core. `script/DeployFreeLP.s.sol` deploys or reuses the canonical index, then deploys FreeLP and FreeLPDataFetcher; its predicted addresses are checked by `FreeLPDeploymentTest`.

## Position storage and pool discovery

Each position stores its `PoolId` and two packed uint64 enumeration indexes in two storage slots. Signed lower and upper ticks occupy 64 bits of the ERC-721 owner slot's extra data. Transfers preserve those bounds. A full withdrawal burns the NFT and clears its position storage and extra data.

Pool keys are registered once in `PoolKeyIndex`, shared by all positions and managers using that index. Registration also populates the index's global, token, and extension lists. Burning the last NFT for a pool does not unregister the pool.

The interface can use `getPoolKeys`, `getPoolKeysByToken` (including address zero for native currency), or `getPoolKeysByExtension` to discover pools, then pass keys to FreeLPDataFetcher's `getQuoteData`. For bounded reads, use the corresponding count and indexed-ID getters. Anyone can register an already initialized Core pool through `register` or `registerMultiple`. Discovery covers registered pools, not every pool ever initialized in Core.

## Writes and native batching

The public write arguments are flat, apart from the standard protocol `PoolKey`:

```solidity
createPosition(key, tickLower, tickUpper, initialTick, maxAmount0, maxAmount1, minLiquidity)
addLiquidity(id, maxAmount0, maxAmount1, minLiquidity)
withdraw(id, liquidity, recipient, minAmount0, minAmount1)
```

There are no deadlines. Deposits enforce maximum token inputs and minimum liquidity; withdrawals enforce minimum outputs including collected fees. Passing zero liquidity to `withdraw` only collects fees.

All three operations are payable and can be combined with the inherited payable `multicall`. Native deposits spend the contract's available balance rather than treating the shared `msg.value` as a separate allowance for every subcall. Append `refundNativeToken()` to the same multicall to return excess ETH. Standalone deposits also require an explicit refund call for any excess; the interface should batch deposit and refund atomically. Core can send native withdrawal proceeds back to the manager to fund another deposit in the batch.

## Reads and metadata

The manager exposes `position(id)` for its stored pool ID and ticks, plus standard ERC-721 ownership and enumeration. `FreeLPDataFetcher.descriptor`, `poolState`, and `positionAmounts` resolve pool keys and calculate principal, liquidity, and accrued fees. `ownedPositions` returns the complete owned position snapshots and metadata in one call. Missing managers and the zero holder return an empty list; results are not silently truncated.

`tokenURI` remains on the NFT for ERC-721 metadata compatibility. Its embedded SVG features pool-derived ripple artwork, the tick range, and exact token addresses. Full token/config/Core/chain identity remains in JSON properties. SVG and decoded JSON fixtures cover concentrated pools, native stableswap, and maximum ID/range/address values, following the VeToken metadata snapshot approach.

Regenerate artwork fixtures explicitly:

```sh
UPDATE_SNAPSHOTS=true FOUNDRY_PROFILE=snapshots forge test --offline --match-contract FreeLPMetadataTest
```

Normal tests have read-only snapshot access. Review the rendered SVGs before accepting fixture changes.

## Gas comparison

Measured with Foundry 1.5.1 and solc 0.8.33 against PR head `fcaf171`, using the same pool, range, amount, and cold-account setup. These are `snapshotGasLastCall` execution measurements, excluding transaction intrinsic gas. The warm case deliberately shares a transaction; cold cases explicitly cool the relevant contracts after setup.

| Create operation | Before | After |
| --- | ---: | ---: |
| First position in an existing pool (registry entry already present after refactor) | 538,274 | 523,338 |
| Second position in the same pool, cold | 245,452 | 230,516 |
| Second position in the same pool, warm | 203,452 | 182,516 |
| First position initializing a new pool, including registry insertion | 605,430 | 833,669 |

The one-time discovery indexes increase first-registration cost. Subsequent positions avoid repeating the full key/descriptor storage, saving 14,936 gas in the cold benchmark and 20,936 gas in the warm benchmark. Reproduce the current measurements with `forge test --offline --match-contract FreeLPTest --match-test test_gas_`.
