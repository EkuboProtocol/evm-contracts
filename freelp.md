# FreeLP

FreeLP is an ownerless LP manager with RPC-readable owner enumeration. Deploy it with Core, the shared `PoolKeyIndex`, and a stateless `FreeLPMetadataRenderer`. The renderer is immutable for each manager and uses no hosted assets or URI setter. Keeping rendering in its own contract leaves both runtimes below EIP-170: FreeLP is 16,734 bytes and the renderer is 14,751 bytes with Solidity 0.8.33, via IR, and 9,999,999 optimizer runs.

## Deployment

`script/DeployFreeLP.s.sol` reuses/deploys the canonical index, deploys the renderer, then deploys FreeLP and FreeLPDataFetcher. `FreeLPDeploymentTest` checks the CREATE2 predictions for the protocol salt:

| Contract | Address |
| --- | --- |
| Core | `0x00000000000014aA86C5d3c41765bb24e11bd701` |
| PoolKeyIndex | `0x827A68AC37AA3715c865F2E0704a63118496986f` |
| FreeLPMetadataRenderer | `0x3E3142aA2143bC05BA92986a9D4867C1409FB8E2` |
| FreeLP | `0x0dB596aF023b61c681c91c39E540829bf81bEcD5` |
| FreeLPDataFetcher | `0x304bDc1869F392740aE879164428ae6A51B71114` |

The manager constructor is `FreeLP(core, index, renderer)`. It assigns immutable references without code-length probes; dependency deployment/configuration is the deployer's responsibility. These predictions replace the previous index/FreeLP/fetcher deployment predictions; existing NFTs remain in their original manager. The pair-index revision deploys a new registry, so previously registered keys must be registered there to appear in its discovery results.

## Position storage and discovery

Pool IDs and owner enumeration indexes live in separate mappings; there is no `StoredPosition` struct. Signed lower and upper ticks occupy 64 bits of the ERC-721 owner slot's extra data. Transfers preserve those bounds. Public NFT IDs and owner indexes use uint256; `nextId` and owner-array entries use uint64, packing four owned IDs per storage word. The checked uint64 counter bounds allocated IDs, so widening to Core's 192-bit position salt requires no checked cast. There is no global live-token array, `totalSupply`, or `tokenByIndex`, and FreeLP does not advertise ERC721Enumerable. `nextId` starts at 1: IDs below it have been allocated, but burned IDs are holes and `ownerOf` rejects them.

Pool keys are registered once in `PoolKeyIndex`. Registration also populates the registry's global, token, exact-pair, and extension lists. Burning the last NFT for a pool does not unregister its key. `register` is idempotent, so creation calls it directly without a separate external `isRegistered` lookup. Core validates pool keys during initialization, and registration requires that exact pool ID to be initialized; FreeLP therefore does not repeat pool-key validation. Position-bound validation remains necessary and is retained.

For bounded exact-pair discovery, use `pairPoolIdCount(tokenA, tokenB)` and `pairPoolIds(tokenA, tokenB, index)`, then pass resolved keys to FreeLPDataFetcher. `getPoolIdsByPair` and `getPoolKeysByPair` return whole pair lists. All pair getters accept either token order, including native-token pairs. Registry coverage includes registered pools, not every initialized pool in Core.

Whole-list getters are convenience reads with linear gas and response size. Permissionless registration can make them exceed an RPC or transaction gas limit; integrations must use the bounded getters rather than depend on atomic full-list availability.

## Writes and callback ordering

The public write arguments are flat apart from the standard protocol `PoolKey`:

```solidity
maybeInitializePool(key, initialTick)
createPosition(key, tickLower, tickUpper, maxAmount0, maxAmount1, minLiquidity)
addLiquidity(id, maxAmount0, maxAmount1, minLiquidity)
withdraw(id, liquidity, recipient)
```

Compose initialization and creation in a payable `multicall`. `maybeInitializePool` leaves existing prices unchanged. `createPosition` requires an initialized pool, emits `PositionCreated` before the deposit, and mints only after Core and token-payment callbacks have completed. During those callbacks, the new NFT cannot be transferred or sold.

`PositionCreated(id, poolId, lower, upper)` records only the NFT-to-pool/bounds association stored by FreeLP. Standard ERC-721 events describe ownership. FreeLP emits no `LiquidityAdded` or `LiquidityRemoved` events: liquidity changes, fee amounts, and principal deltas already appear in Core and token transfer logs. On full withdrawal, the ERC-721 burn and all NFT bookkeeping finish before Core invokes extension callbacks or transfers tokens.

Both creation and liquidity additions require `minLiquidity > 0` and enforce maximum token inputs and minimum liquidity. Withdrawals have no minimum-output/slippage arguments. Passing zero liquidity collects fees and preserves the position. A full withdrawal burns the NFT and clears its storage before any fee-collection or position-update callbacks. Failed withdrawals roll the burn back atomically. Open-position withdrawals verify that callbacks did not unexpectedly close or transfer the NFT; deposit settlement still prevents funded orphan positions and liquidity outside the supported signed range.

The withdrawal check applies only while the NFT remains open. Core runs its before-hooks before updating its accounting: an approved callback can transfer the NFT before the outer withdrawal reduces its liquidity, or perform a nested partial withdrawal that combines with the outer withdrawal to empty an unburned NFT. Removing the open-position guard makes both regression tests fail because these operations no longer revert. Full closes need no equivalent postcheck because the NFT has already been burned before callbacks.

Native deposits use `PayableMulticallable` and spend the manager's shared ETH balance. Refunds are optional and caller-managed: append `refundNativeToken()` to the same manager multicall when recovering leftovers is worth the gas, or deliberately leave small leftovers. There is no automatic refund, forced zero-ending balance, or per-caller native-payment scope. Native proceeds withdrawn to the manager can fund another deposit in that multicall. Shared ETH remains permissionlessly spendable/refundable, including by callbacks; this is not a custody contract. A caller wanting an atomic refund must include it in the manager multicall rather than a separate wallet-batch transaction.

Deposits snapshot existing ownership and liquidity before Core callbacks. After settlement, ownership must be unchanged and liquidity must be at least the prior amount plus the requested addition (and within the signed limit). This prevents callback-time withdrawals from consuming the addition while the payer is charged.

Withdrawals return `uint256` totals. Fees and principal are added at that width, then paid through bounded `uint128` accountant withdrawals; only totals above `uint128.max` require additional payout calls. The input ABI remains `withdraw(uint256,uint128,address)`.

Public ERC-721 transfers to zero already revert in Solady before the owner-enumeration hook. Only an internal burn reaches a zero destination. Self-transfers leave the owner list and position data unchanged; normal ERC-721 approval clearing and transfer events still apply.

## Reads and artwork

The manager exposes `position(id)` and standard NFT ownership. Descriptor resolution, pool state, principal, liquidity, and fees are read through FreeLPDataFetcher. Its descriptor is a read-only DTO; the manager no longer carries a `Descriptor` type. `ownedPositions` returns complete snapshots and metadata in one call, subject to RPC gas/response limits rather than silent truncation.

`tokenURI` checks that the NFT exists, then calls the immutable on-chain renderer. Each ERC-20 name, symbol, and decimals getter is independent, capped at 30,000 gas and 320 return bytes. Standard dynamic strings and bytes32 metadata are supported. Malformed data, gas/return-data bombs, invalid UTF-8, and XML controls cannot break rendering. Symbols and names are bounded; visible labels are shortened at code-point boundaries. XML text and JSON strings are escaped separately.

The SVG emphasizes the token pair, token names, decimals, and price bounds. The heading shows token1 / token0, with names and decimals in the same display order. Symbols use 44px text (28px for long pairs), names 22px, and the minimum and maximum prices each have a full-width row with 44px values. The pool-derived ripple motif is 144px across. Exact token addresses and raw ticks are kept in JSON rather than printed on the SVG, alongside Core/config/chain identity. Prices are approximate display-only values in token1 per token0, adjusted for decimals; unknown decimals show unavailable price bounds instead of raw ticks. Known native chains have native labels; unknown native currencies are explicitly labelled without invented decimals.

Token metadata is self-reported display information, not token-identity verification. No metadata getter participates in deposit or withdrawal accounting.

Regenerate artwork fixtures explicitly:

```sh
UPDATE_SNAPSHOTS=true FOUNDRY_PROFILE=snapshots forge test --offline --match-contract FreeLPMetadataTest
```

Normal tests compare the fixtures read-only. Fixtures cover WETH/USDC, native/WETH stableswap, extreme ticks/decimals/IDs, and long Unicode/escaped names. Consumers should render the embedded image as an image and support escaped XML text; validators that reject every XML entity will reject legitimate token names.

## Gas measurements

Measured with the CI-pinned Foundry 1.5.1 and solc 0.8.33. These are execution-frame measurements, excluding transaction intrinsic gas, from `snapshots/FreeLP.json`:

| Create operation | Full-word IDs (`4fccdc6`) | Packed IDs, pair index, and audit fixes |
| --- | ---: | ---: |
| First position in an existing registered pool | 452,209 | 453,920 |
| Second position in the same pool, cold | 236,187 | 217,998 |
| Second position in the same pool, warm | 198,187 | 177,998 |
| New pool initialization and registration | 768,086 | 814,476 |

The last row measures the initialize/create multicall. Existing-pool cold measurements call `createPosition` directly after cooling the contracts, so an unmeasured initialization helper cannot accidentally warm the measured operation. This revision's first-registration path costs 46,390 more gas overall, primarily for the pair list's new length and first entry; subsequent registrations of the same pool are idempotent. These end-to-end comparisons include the other contract changes too.

`FreeLPOwnerPackingTest` isolates packing with an otherwise identical ERC-721 harness: a cold second mint to the same owner costs **56,463 gas packed versus 76,313 full-word**, saving **19,850 gas**. It verifies slot reuse directly. The renderer is a separate one-time deployment; token metadata calls are view work, not part of deposit accounting.

```sh
forge test --offline --match-contract '^FreeLP.*Test$'
forge snapshot --offline --match-contract '^FreeLPTest$' --snap snapshots/FreeLP.gas --gas-snapshot-emit true
```

## Frontend migration

The next frontend artifact import must include the renderer and its immutable binding, use the new deployment addresses/constructor and pair getters, prepend explicit initialization when needed, supply positive deposit minimum liquidity, and decode withdrawal totals as uint256. Withdrawal minimum-output fields remain absent. A frontend pinned to the prior ABI should keep using its prior manager until migrated. See [V12 triage](docs/FreeLP-audit-7806.md) for the scoped audit results and remaining tradeoffs.
