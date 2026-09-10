# Scheduled launches with locked liquidity migration

`ScheduledLaunch` creates a fixed-supply token, releases its inventory linearly over
an auction interval, and charges a declining creator fee on external launch swaps.
At the end, principal moves to `LockedLaunchLiquidity`, which balances it against any
existing liquidity and deposits into a **no-extension full-range pool**. That pool's
fixed fee equals the launch schedule's final fee.

Principal is permanently locked. The creator can claim launch trading fees and fees
earned by this launch's terminal position, never another LP's fees or the principal.

## Configuration and atomic creation

Inside a Core lock, forward `abi.encode(uint8(0), LaunchConfig)` to `ScheduledLaunch`.
The response is `abi.encode(PoolKey)`. The forwarding locker must settle optional
quote funding before returning. `FlashAccountantLib.forward` handles the calling
convention; the test-only `LaunchActor` shows funding and settlement examples.

| Configuration | Meaning |
| --- | --- |
| `owner` | Immutable nonzero creator and fee beneficiary |
| `quoteToken` | Quote asset; address zero means native ETH |
| `name`, `symbol`, `decimals` | Metadata for the existing `MintableERC20` implementation |
| `totalSupply` | Entire token supply, reserved for this launch |
| `quoteAmount` | Optional quote funding supplied by the forwarding locker |
| `startTime`, `endTime` | Current/future start and strictly later end |
| `targetTick`, `upperTick` | Fixed launch target and upper sell-range boundary |
| `tickSpacing` | Launch concentrated-pool spacing |
| `initialFee`, `finalFee` | Declining creator fee endpoints, in Q0.64 |
| `migrationTickLower`, `migrationTickUpper` | Immutable acceptable terminal-price bounds |

All configured ticks express **raw quote units per raw launch-token unit**. The
implementation reverses bounds and negates ticks when the launch token is token1.
Convert for token decimals before choosing ticks. Launch bounds must align with tick
spacing. Migration bounds need not align with launch spacing. Choose bounds that
reflect acceptable migration prices: unrestricted bounds do not protect against
migration at a manipulated price.

Supply must be positive and supply/seed must fit a positive int128. Fees are below
100% by construction and must satisfy `initialFee >= finalFee`. Metadata inherits
`MintableERC20`'s 31-byte name/symbol limits. Creation deploys a fresh token through
the extension's immutable liquidity contract, mints inventory to the extension, and
renounces minting authority. The extension pays that inventory into Core and saves it
under its own address, the token pair, and the launch pool-ID salt. Creation, funding,
and initialization revert atomically if anything fails.

The launch pool starts at its target and has a **zero Core pool fee**. Its two enabled
call points are `beforeInitializePool` and `beforeSwap`; both always revert. Core
skips these callbacks when the extension itself initializes or swaps. There is no
alternative initialization path and no direct swap path that bypasses creator fees.

## Release and creator fees

Cumulative released tokens are zero at/before start, the whole supply at/after end,
and otherwise:

```text
released = totalSupply * (now - startTime) / (endTime - startTime)
available = released - deployed
fee = initialFee - (initialFee - finalFee) * (now - startTime) / (endTime - startTime)
```

The fee is clamped to its configured endpoints. During the auction, `deployed` counts
released tokens consumed by launch sales and positive liquidity additions. It is not
an accounting measure for post-auction migration. Releases depend on time, never
swap count.

Forward `abi.encode(uint8(1), PoolKey, SwapParameters)` to trade; the result is
`abi.encode(PoolBalanceUpdate, PoolState)`. Before executing the external trade, the
extension advances inventory: sell available tokens toward the target only while
price is above it, then add feasible balances in the launch sell-side range. At or
below target, skip selling and add token-side liquidity. Unreleased tokens cannot be
used to pair quote proceeds. Excess quote remains reserved.

The creator fee applies to the **calculated side** of the actual fill:

- Exact input: deduct the fee from output.
- Exact output: gross up the required input to include the fee.

This preserves the specified amount and handles partial fills. The forwarding
router must settle the returned deltas and enforce the user's slippage constraints
against those fee-inclusive deltas. Raw Core swap events exclude the extension fee.

Internal release sales never pass through this fee-charging path. Their Core pool
fee is zero. Creator fees are saved separately using `creatorFeeSalt(launchPoolId)`;
they never become migration principal. `claimFees(PoolKey, recipient)` lets the owner
claim this ledger without withdrawing inventory or liquidity. Any donated Core fees
on the launch-owned position are collected before its final removal and attributed
to the creator as position fees.

## End of auction and principal custody

At/after end, launch swaps revert. Anyone may call `advance(PoolKey)` to end the
auction; this does not depend on an owner transaction or another trade. It transfers
saved principal and removes launch-owned liquidity into the immutable
`LockedLaunchLiquidity` contract through Core forwarding. Other LPs' launch positions
are not removed. Core token-delta and saved-balance limits can require multiple
advances for unusually large positions.

`Launch.complete` means all launch-owned principal has left the auction pool.
It does **not** imply every reserve has already been deposited into the destination.
After completion, `advance` makes no further launch-pool changes. All pending
principal remains locked and anyone may retry terminal migration separately.

The liquidity contract exposes no principal withdrawal, approval, arbitrary call,
upgrade, or ownership-transfer entry point. Its only token-deployment method is
extension-only and creates new fixed-supply tokens; it cannot mint existing tokens.
Creator identity, fee schedule, destination pool fee, and migration bounds are fixed
at launch creation.

## Full-range migration

The destination key uses the same token pair,
`createFullRangePoolConfig(finalFee, address(0))`: the unamplified, full-range
stableswap configuration, with XYK price movement and no initialized-tick traversal.
Each launch receives its own full-range position owned by the liquidity contract.

**Existing liquidity:** use its current liquidity and square-root price to solve the
fee-adjusted XYK balancing trade. For token0 input `x`, liquidity `L`, and square-root
price `s`, the idealized price movement is:

```text
net = x - inputFee(x)
s' = L*s / (L + net*s)
token1Out = L * (s - s')
```

The solver uses Core's actual rounding for these equations and the finite full-range
endpoints. It bisects the input amount until both remaining assets support equal
deposit liquidity, checks adjacent integer candidates, and compares against no swap.
There are at most 127 input-search iterations; cost does not depend on tick history.
The solver includes the position's own internal-fee rebate when predicting remaining
balances. Compact-price precision and integer rounding can still leave small reserves.
It caps swap output, deposits, and arithmetic at Core's amount/liquidity limits.

The current and resulting prices must remain within the launch's migration bounds.
Migration at an out-of-bounds existing price is deferred; it does not force a bad
swap or unlock the funds. Bounds restrict acceptable prices but are not an oracle.

**Empty destination:** with both assets available, choose the full-range deposit
price implied by those balances, including finite endpoint corrections. Initialize
if necessary, and reset any preexisting empty-pool price before depositing. The price
search uses fixed-point values because compact `SqrtRatio` encodings have gaps.
The selected price must also satisfy migration bounds.

**Missing counterpart:** if there is neither existing liquidity to swap against nor
both assets to seed a pool, retain locked reserves. This includes a launch with no
buyers and no quote seed. Once the launch is registered in the liquidity contract,
anyone can fund it by forwarding `abi.encode(uint8(1), launchPoolId, amount0, amount1)`
to that contract and settling the resulting Core debt. Funding is an irrevocable
contribution to principal. Then call `migrate(launchPoolId)` to retry. Dust, capacity
limits, or price bounds may also leave reserves pending; they are never paid out as
creator fees.

A migration swap pays the destination's normal fixed pool fee to its LPs; there is
no additional creator surcharge. Before a rebalance, existing earned position fees
are preserved in a separate creator ledger. Fees the launch's own terminal position
earns from that internal rebalance are recycled into locked principal, preventing
migration retries from turning principal into creator income.

## Terminal fees and observability

`LockedLaunchLiquidity.claimFees(launchPoolId, recipient)` is owner-only. It collects
only that launch's position fees, plus any external-trade fees saved before a
rebalance. Position liquidity and principal reserves are untouched. Other LPs retain
their own fee claims. The terminal pool's fixed fee persists after migration; no
extension stays in its swap path.

Use `getLaunch`, `released`, `feeAt`, and `terminalPool` on the extension. Use
`getTerminal` and `positionId` on the liquidity contract. Query Core saved balances
with the holder contract, token pair, and launch pool-ID salt for principal; use
that holder's `creatorFeeSalt` for creator fees. Query the terminal position's Core
liquidity to distinguish a pending migration from an established position.
`LaunchCreated`, `LaunchAdvanced`, `PrincipalReceived`, `LiquidityLocked`, and fee
claim events accompany Core's normal pool, swap, and position events.

## Deployment and validation

`script/DeployScheduledLaunch.s.sol` mines the extension's required address prefix
and deploys it with its immutable liquidity contract. Configure `CORE_ADDRESS`,
optional starting `SALT`, and optional expected `SCHEDULED_LAUNCH_ADDRESS`. Use
`forge script --offline`; broadcasting is a separate action. No existing deployed
contract source is modified.

Tests cover fee decay and fee-inclusive fills, internal-fee exemption, atomic
creation, ownership, both token orders, native quote assets, source and destination
accounting, existing/empty terminal pools, no-counterpart retries, price bounds,
locked principal, per-position fees, internal-fee recycling, chunked migration,
CREATE2 deployment and size limits, and the balancing solver against brute force.
