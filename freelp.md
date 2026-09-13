# FreeLP

FreeLP is an ownerless LP manager with RPC-readable owner enumeration. Deploy it with Core, the shared `PoolKeyIndex`, and a stateless `FreeLPMetadataRenderer`. The renderer is immutable for each manager and uses no hosted assets or URI setter. Keeping rendering in its own contract leaves both runtimes below EIP-170: FreeLP is 17,305 bytes and the renderer is 15,206 bytes with Solidity 0.8.33, via IR, and 9,999,999 optimizer runs.

## Deployment

`script/DeployFreeLP.s.sol` reuses/deploys the canonical index, deploys the renderer, then deploys FreeLP and FreeLPDataFetcher. `FreeLPDeploymentTest` checks the CREATE2 predictions for the protocol salt:

| Contract | Address |
| --- | --- |
| Core | `0x00000000000014aA86C5d3c41765bb24e11bd701` |
| PoolKeyIndex | `0x898956fc2Aed01D5F81F556FF5dcB10534285718` |
| FreeLPMetadataRenderer | `0xAD70a7A70678C57FBB52a9aFF6a2E0884E226f86` |
| FreeLP | `0x7F818932a0963199aFd8778c905972eeFDBF1EE5` |
| FreeLPDataFetcher | `0xC1eDB9fab9C14C07938b4a0FA848B9F51eaC9FF7` |

The manager constructor is `FreeLP(core, index, renderer)`. These predictions replace the previous FreeLP/fetcher deployment predictions; existing NFTs remain in their original manager.

## Position storage and discovery

Each position stores its `PoolId` and owner enumeration index in two storage slots. Signed lower and upper ticks occupy 64 bits of the ERC-721 owner slot's extra data. Transfers preserve those bounds. Owner enumeration uses packed uint64 IDs, four per storage word. There is no global live-token array, `totalSupply`, or `tokenByIndex`, and FreeLP does not advertise ERC721Enumerable. `nextId` starts at 1: IDs below it have been allocated, but burned IDs are holes and `ownerOf` rejects them.

Pool keys are registered once in `PoolKeyIndex`. Registration also populates the registry's global, token, and extension lists. Burning the last NFT for a pool does not unregister its key. `register` is idempotent, so creation calls it directly without a separate external `isRegistered` lookup.

The interface can use the registry's count/indexed-ID getters for bounded discovery, then filter exact pairs and pass keys to FreeLPDataFetcher. Registry coverage includes registered pools, not every initialized pool in Core.

## Writes and callback ordering

The public write arguments are flat apart from the standard protocol `PoolKey`:

```solidity
maybeInitializePool(key, initialTick)
createPosition(key, tickLower, tickUpper, maxAmount0, maxAmount1, minLiquidity)
addLiquidity(id, maxAmount0, maxAmount1, minLiquidity)
withdraw(id, liquidity, recipient)
```

Compose initialization and creation in a payable `multicall`. `maybeInitializePool` leaves existing prices unchanged. `createPosition` requires an initialized pool, emits `PositionCreated` before the deposit, and mints only after Core and token-payment callbacks have completed. During those callbacks, the new NFT cannot be transferred or sold.

Deposits enforce maximum token inputs and minimum liquidity. Withdrawals have no minimum-output/slippage arguments. Passing zero liquidity collects fees and preserves the position. A full withdrawal burns the NFT and clears its storage before any fee-collection or position-update callbacks. Failed withdrawals roll the burn back atomically. Partial withdrawals verify that callbacks did not unexpectedly close or transfer the NFT; deposit settlement still prevents funded orphan positions and liquidity outside the supported signed range.

All write operations are payable. Native deposits spend the manager's shared call balance. Append `refundNativeToken()` to the same manager multicall to return excess ETH; do not make the refund a separate wallet-batch transaction. Native proceeds withdrawn to the manager can fund another deposit in that multicall.

Public ERC-721 transfers to zero already revert in Solady before the owner-enumeration hook. Only an internal burn reaches a zero destination. Self-transfers leave the owner list and position data unchanged; normal ERC-721 approval clearing and transfer events still apply.

## Reads and artwork

The manager exposes `position(id)` and standard NFT ownership. Descriptor resolution, pool state, principal, liquidity, and fees are read through FreeLPDataFetcher. Its descriptor is a read-only DTO; the manager no longer carries a `Descriptor` type. `ownedPositions` returns complete snapshots and metadata in one call, subject to RPC gas/response limits rather than silent truncation.

`tokenURI` checks that the NFT exists, then calls the immutable on-chain renderer. Each ERC-20 name, symbol, and decimals getter is independent, capped at 30,000 gas and 320 return bytes. Standard dynamic strings and bytes32 metadata are supported. Malformed data, gas/return-data bombs, invalid UTF-8, and XML controls cannot break rendering. Symbols and names are bounded; visible labels are shortened at code-point boundaries. XML text and JSON strings are escaped separately.

The SVG emphasizes the token pair, token names, decimals, and price bounds. Symbols use 44px text (28px for long pairs), names 22px, and price bounds 32px. The pool-derived ripple motif is 144px across. Exact token addresses and raw ticks remain visible, with full Core/config/chain identity in the JSON. Prices are approximate display-only values in token1 per token0, adjusted for decimals; unknown decimals produce raw tick bounds instead. Known native chains have native labels; unknown native currencies are explicitly labelled without invented decimals.

Token metadata is self-reported display information, not token-identity verification. No metadata getter participates in deposit or withdrawal accounting.

Regenerate artwork fixtures explicitly:

```sh
UPDATE_SNAPSHOTS=true FOUNDRY_PROFILE=snapshots forge test --offline --match-contract FreeLPMetadataTest
```

Normal tests compare the fixtures read-only. Fixtures cover WETH/USDC, native/WETH stableswap, extreme ticks/decimals/IDs, and long Unicode/escaped names. Consumers should render the embedded image as an image and support escaped XML text; validators that reject every XML entity will reject legitimate token names.

## Gas measurements

Measured with the CI-pinned Foundry 1.5.1 and solc 0.8.33. These are execution-frame measurements, excluding transaction intrinsic gas, from `snapshots/FreeLP.json`:

| Create operation | Before review (`e6da577`) | After review |
| --- | ---: | ---: |
| First position in an existing registered pool | 523,338 | 455,082 |
| Second position in the same pool, cold | 230,516 | 219,160 |
| Second position in the same pool, warm | 182,516 | 179,160 |
| New pool initialization and registration | 833,669 | 770,959 |

The last row measures the new initialize/create multicall. Existing-pool cold measurements call `createPosition` directly after cooling the contracts, so an unmeasured initialization helper cannot accidentally warm the measured operation. The renderer is a separate one-time deployment; token metadata calls are view work, not part of deposit accounting.

```sh
forge test --offline --match-contract '^FreeLP.*Test$'
forge snapshot --offline --match-contract '^FreeLPTest$' --snap snapshots/FreeLP.gas --gas-snapshot-emit true
```

## Frontend migration

The next frontend artifact import must include the renderer and its immutable binding, use the new deployment addresses/constructor, prepend explicit initialization when needed, and remove obsolete withdrawal minimum-output fields. A frontend pinned to the prior ABI should keep using its prior manager until migrated.
