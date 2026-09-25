# Continuous swap-access auction

`ContinuousAuction` sells exclusive access to zero-Core-fee pools. Its immutable
`bidToken` is the asset used for bids, refunds, and LP fees. `address(0)` selects
the native token; other addresses select standard, non-rebasing ERC20s. Incoming
ERC20 funding is checked against the actual received balance, so transfer-tax
deposits are rejected.

## Bids and funding

```solidity
bid(PoolKey key, uint96 rate, uint64 end, address executor)
```

- `rate` is integer bid-token base units per second.
- `start = block.timestamp + 1`.
- `end > start`, and `end` must pass `isTimeValid(block.timestamp, end)` from the
  TWAMM time library. This is an aligned expiration, not a minimum lease duration.
- Full funding is `rate * (end - start)`. For native bids, send at least that
  `msg.value`; excess is credited to the bidder's refund balance. This tolerates
  inclusion delay between constructing and executing the bid. For ERC20 bids,
  approve the extension and send no native value; the exact funding is pulled.
- The bid must beat the rate scheduled at its activation time. Equal bids fail.
- Bids cannot be cancelled or voluntarily reduced. Outbidding permanently
  relinquishes only the covered intervals and credits their unused funding.
- `executor` is the authorized **Core locker contract**. It must authenticate
  its callers. Naming a permissionless router grants that router's users access;
  it does not restrict access to the bidder's EOA.

The future schedule consists of decreasing-rate, increasing-end-time segments,
plus at most one preserved incumbent prefix. New bids may remove several future
segments and trim the first surviving tail. Bidding is O(displaced segments),
and expiry settlement is O(expired segments). TWAMM's expiration grid bounds the
number of distinct surviving future ends; it is unnecessary to retain losing
bids or build a general bid-price heap.

Example, all bids submitted at timestamp 100:

| Bidder | Rate | End | Final funded interval |
| --- | ---: | ---: | --- |
| Alice | 1 | 1024 | [768, 1024) |
| Bob | 2 | 768 | [256, 768) |
| Carol | 3 | 256 | [101, 256) |

Alice can withdraw `1 * (768 - 101)` and Bob `2 * (256 - 101)`.
The remainder funds their tails, which resume automatically. Withdraw credits
with `withdrawRefund(recipient)`; credits belong to the bidder, not its executor.

## Clock and exclusive execution

Access requires both `block.timestamp >= start` and
`block.number >= submissionBlock + 1`. The incumbent retains the current block.
On a strictly increasing one-second timestamp chain, activation is the next
block. Same-timestamp blocks do not activate new bids. If blocks are skipped,
rent still begins at the predetermined economic timestamp, not the first later
interaction. This explicit timestamp convention permits lazy settlement without
historical block-header proofs or per-block keeper transactions.

If no funded bid is active, swaps revert. Expiry transitions to the next funded
tail, if any. There is no privileged free-access executor.

The authorized locker calls `Core.forward(address(extension))` with trailing
`abi.encode(poolKey, swapParameters)`. The extension returns the usual encoded
`(PoolBalanceUpdate, PoolState)`. The locker settles the ordinary swap deltas
with Core. There is no per-swap surcharge. Direct Core swaps revert.

The extension uses the same power-of-four concentrated tick-spacing restriction
as Ve33. Full-range and stableswap configurations are also supported.

## LP accounting

Bid funds are held by the extension, separately from Core liquidity principal.
Elapsed rent is settled before swaps, liquidity changes, claims, and bids. Anyone
may call `accrue(poolKey)` to settle without another operation.

- Rent belongs to liquidity **active over time**, not to every range traversed
  by a swap. Settling before a price move preserves the previous interval's
  attribution.
- Concentrated positions use Q128 growth, per-tick outside growth, and per-position
  snapshots, following Ve33's external reward accounting. Stableswap positions
  use global growth.
- Position changes checkpoint fees into a separate owed balance. Removing all
  liquidity does not discard already-earned fees.
- Rent is charged even with zero active liquidity. Such rent is permanently
  accounted in `unallocatedRent(poolId)`, excluded from bidder refunds and future
  LP claims. This prevents holders avoiding rent by moving price into an empty
  range and prevents later depositors claiming earlier empty-interval rent.
- Integer rounding favors solvency; rounding dust remains in the extension.
  There is no administrator sweep of escrow or LP fee balances.
- `getPositionFees` includes only already-accrued rent. Call `accrue` first to
  include time elapsed since the last pool interaction.

## AuctionPositions

`AuctionPositions(core, auction, metadataOwner)` extends the standard `Positions`
manager with zero protocol fees and auction-fee collection:

```solidity
collectAuctionFees(id, poolKey, tickLower, tickUpper, recipient)
```

The NFT owner and approved operators may collect; the four-argument overload pays
the caller. The metadata owner receives no right to other users' LP fees. Pending
auction fees travel with the NFT on transfer and remain claimable after full
liquidity withdrawal. Collect all balances before burning the NFT, as with the
base manager's other position assets. Burning does not settle Core positions or
auction rent. The original minter can recreate the same deterministic NFT ID and
thereby regain control of any value left under that ID after an authorized burn.

Use the inherited `mintAndDeposit`, `deposit`, and `withdraw` APIs for principal.
Inherited `collectFees` handles ordinary Core token-pair fees; auction fees are
collected separately in `bidToken`. The manager can also manage ordinary pools,
but its auction-fee collector accepts only this immutable extension's pools.

This mechanism is venue-independent. The executor can hedge on Lighter Core,
but asynchronous hedge orders and their inventory/risk management are separate
from the auction contract.

## Economic scope

Rent is a gross payment to liquidity active over time, not a guaranteed net
payment to incumbent LPs. A holder who supplies liquidity can earn LP rent like
any other provider, including recapturing rent when it owns all active liquidity.
The mechanism does not enforce historical LP eligibility, minimum LP duration,
non-recapturable access payments, or protection against price relocation to the
holder's own range. Those require different reward eligibility rules. LPs should
evaluate net strategy returns rather than treating the bid rate as guaranteed yield.

## Deployment and reproducibility

Use `script/DeployContinuousAuction.s.sol` with explicit `CORE_ADDRESS`, `BID_TOKEN`,
`OWNER_ADDRESS`, and a bytes32 `SALT`. `BID_TOKEN=0x0000000000000000000000000000000000000000`
selects native rent. The script uses the repository's canonical CREATE2 deployer
and mines the required extension address prefix (`0x51`). Optional `AUCTION_ADDRESS`
and `AUCTION_POSITIONS_ADDRESS` variables assert the predicted addresses. Repeated
execution reuses the same deployments. The metadata owner can subsequently call
the manager's inherited `setMetadata`.

```bash
forge test --offline --match-contract 'ContinuousAuction(Test|DeploymentTest)'
forge script --offline script/DeployContinuousAuction.s.sol:DeployContinuousAuction \
  --rpc-url "$RPC_URL" --account "$DEPLOYER_ACCOUNT"
```

The script command simulates deployment; add `--broadcast` for an approved launch.
Use the repository-pinned compiler and optimizer settings so CREATE2 addresses
match the reviewed build. The Core and bid-token bytecode must exist on the target
chain (except native address zero). The target chain must support the EVM features
used by Core, including transient storage. Pool fees must be zero; concentrated
spacing must be a power of four. Configure a caller-authenticated executor before
bidding. The general Router does not automatically route through this extension.
