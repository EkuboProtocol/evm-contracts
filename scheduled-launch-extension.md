# Scheduled launches with locked liquidity migration

`ScheduledLaunch` creates a fixed-supply token, releases its inventory linearly over
an auction interval, and charges a declining creator fee on external launch swaps.
At the end, principal moves to `LockedLaunchLiquidity`, which balances it against any
existing liquidity and deposits into a **TWAMM-enabled full-range pool**. That pool's
fixed fee equals the launch schedule's final fee.

Principal is permanently locked. The owner can claim launch trading fees and fees
earned by this launch's terminal position, never another LP's fees or the principal.

## Forward-only actions

Neither launch contract ever holds tokens, even transiently. Every action that moves
tokens or changes a position is a `Core.forward` from a locker that settles it, in the
shape of the other forward-only extensions (Ve33 and its periphery). The forwarded
payload's first 32-byte word selects the action; the hashed call types are declared
in `src/interfaces/extensions/IScheduledLaunch.sol`:

| Call type | Forwardee | Payload after the call type | Returns | Who settles |
| --- | --- | --- | --- | --- |
| `LAUNCH_CREATE` | `ScheduledLaunch` | `LaunchConfig` | `(PoolKey, address token)` | nothing: the supply is minted to Core and saved in the same forward |
| `LAUNCH_CLAIM_FEES` | `ScheduledLaunch` | `(PoolKey, address recipient)` | `(uint128, uint128)` | owner withdraws the returned amounts |
| `LAUNCH_FUND` | `LockedLaunchLiquidity` | `(PoolId, uint128, uint128)` | nothing | forwarding locker pays the amounts |
| `LAUNCH_CLAIM_FEES` | `LockedLaunchLiquidity` | `(PoolId, address recipient)` | `(uint128, uint128)` | owner withdraws the returned amounts |
| any other first word | `ScheduledLaunch` | the whole payload is `abi.encode(PoolKey, SwapParameters)` | `(PoolBalanceUpdate, PoolState)` | forwarding locker settles the fee-inclusive update |

A swap payload's first word is a token address, which never equals a hashed call
type. Any other payload to `LockedLaunchLiquidity` must be the extension's own
principal `Registration` at migration and reverts `ExtensionOnly()` from anyone else.
`recipient` in a claim is recorded in the claim event only; the forwarding owner
withdraws to whomever it chooses.

`advance(PoolKey)` and `migrate(launchId)` are direct and permissionless, like TWAMM's
`lockAndExecuteVirtualOrders`: they take their own lock and only move balances inside
Core (released inventory into the launch pool, principal into the terminal pool).

### LaunchRouter

`LaunchRouter` is the small, non-upgradeable, admin-free periphery for these actions.
It holds nothing between calls and has no swap or quote function.

- `create(config)` forwards `LAUNCH_CREATE` with `config.owner` replaced by itself,
  records `creator[launchId] = msg.sender` and emits `LaunchCreatedBy(launchId,
  creator)`. It takes no payment.
- `fund(launchId, amount0, amount1)` forwards `LAUNCH_FUND` and pays the exact amounts
  from `msg.sender`: `msg.value` must equal `amount0` for a native token0 and be zero
  otherwise (`InvalidPayment()`), and ERC-20 amounts are pulled by `transferFrom`. It
  refunds nothing.
- `claimFees(PoolKey, recipient)` is creator-only (`CreatorOnly()`). It forwards both
  fee claims (the locked-liquidity claim once the launch is registered there) and
  withdraws the total to `recipient`.

### Owner of record

`LaunchConfig.owner` is recorded as given and is the only address whose
`LAUNCH_CLAIM_FEES` forward releases fees. It must therefore be a contract that can lock
Core and forward. For launches created through `LaunchRouter` it is the router, which
releases fees only to the recorded creator. A contract may instead create by its own
`LAUNCH_CREATE` forward and name itself owner. Any other owner, such as an EOA, leaves
the fees unclaimable. Creation does not check the owner beyond nonzero, so the field
keeps its name: it is the owner of record, not a recipient.

## Configuration and creation

Creation is the `LAUNCH_CREATE` forward, normally through `LaunchRouter.create`. It
takes no quote: there is no creation seed. Counterpart quote for a launch with no
buyers is added after the end with `LAUNCH_FUND`.

| Configuration | Meaning |
| --- | --- |
| `owner` | Immutable nonzero owner of record of creator fees (see above) |
| `quoteToken` | Quote asset; address zero means native ETH |
| `name`, `symbol`, `decimals` | Metadata for the existing `MintableERC20` implementation |
| `totalSupply` | Entire token supply, reserved for this launch |
| `startTime`, `endTime` | Current/future start and strictly later end |
| `targetTick`, `upperTick` | Fixed launch target and upper sell-range boundary |
| `tickSpacing` | Launch concentrated-pool spacing |
| `initialFee`, `finalFee` | Declining creator fee endpoints, in Q0.64 |
| `migrationTickLower`, `migrationTickUpper` | Immutable acceptable terminal-price bounds, at most `MAX_MIGRATION_TICK_WIDTH` (2,302,585 ticks, just under a 10x price ratio) apart |

All configured ticks express **raw quote units per raw launch-token unit**. The
implementation reverses bounds and negates ticks when the launch token is token1.
Convert for token decimals before choosing ticks. Launch bounds must align with tick
spacing. Migration bounds need not align with launch spacing. Choose bounds that
reflect acceptable migration prices: unrestricted bounds do not protect against
migration at a manipulated price.

Supply must be positive and fit a positive int128. At least one raw
token unit must be sellable at the `upperTick` price without overflowing quote
accounting, which rejects ranges ending within about 0.7 million ticks of `MAX_TICK`. Fees are below
100% by construction and must satisfy `initialFee >= finalFee`. Metadata inherits
`MintableERC20`'s 31-byte name/symbol limits. Creation deploys a fresh token through
the extension's immutable liquidity contract, which mints the supply directly to Core
between `startPayments` and `completePayments`, crediting it to the current lock, and
renounces minting authority. The extension saves that supply under its own address,
the token pair, and the launch pool-ID salt in the same forward, so the forwarding
locker's net debt is zero. Creation and initialization revert atomically if anything
fails.

The launch pool starts at its target and has a **zero Core pool fee**. Its three enabled
call points are `beforeInitializePool`, `beforeSwap` and `beforeUpdatePosition`; all
always revert. Core skips these callbacks when the extension itself initializes, swaps
or updates its position. There is no alternative initialization path, no direct swap
path that bypasses creator fees, and no third-party position. A third-party position
at the range bounds could otherwise fill Core's per-tick liquidity cap before the
launch starts, leaving no room for released inventory.

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

Trade with the standard forwarded swap that routers use for any forward-only extension:
inside a Core lock, forward `abi.encode(PoolKey, SwapParameters)` to the extension (the
pool config's extension address); the result is `abi.encode(PoolBalanceUpdate,
PoolState)` and the forwarding locker settles the update. The forward channel accepts
nothing else. Before executing the external trade, the
extension advances inventory: sell available tokens toward the target only while
price is above it, then add feasible balances in the launch sell-side range. At or
below target, skip selling and add token-side liquidity. Unreleased tokens cannot be
used to pair quote proceeds. Excess quote remains reserved.

External buys stop at the top of the launch range (`upperTick`): a price limit
beyond it, including the default limit, is replaced by the top. Above the range the
pool holds nothing of the launch's, and an empty pool (for example in the
start-timestamp block, before any release) would let a buy move the price to the
maximum for free. From there no release could be sold back toward the target and
released inventory would never be offered. Bounding buys keeps the price at or below
the top, where every release can sell at least one unit back toward the target, so
releases are always offered. Exact-input buys larger than the offered inventory fill
partially. Sells are not bounded; releases below the target add token-side liquidity.

The creator fee applies to the **calculated side** of the actual fill:

- Exact input: deduct the fee from output.
- Exact output: gross up the required input to include the fee.

This preserves the specified amount and handles partial fills. The forwarding
locker must settle the returned deltas and enforce the user's slippage constraints
against those fee-inclusive deltas. Raw Core swap events exclude the extension fee
and show the extension as locker, so every external swap also emits
`LaunchSwapped(poolId, locker, delta0, delta1, feeAmount, feeIsToken1)` with the
original forwarding locker, the fee-inclusive deltas returned to it, and the creator
fee. Internal release sales emit no `LaunchSwapped`.

Internal release sales never pass through this fee-charging path. Their Core pool
fee is zero. Creator fees are saved separately using `creatorFeeSalt(launchPoolId)`;
they never become migration principal. The owner's `LAUNCH_CLAIM_FEES` forward releases
this ledger to the owner without touching inventory or liquidity. Any donated Core fees
on the launch-owned position are collected before its final removal and attributed
to the creator as position fees.

## End of auction and principal custody

At/after end, launch swaps revert. Anyone may call `advance(PoolKey)` to end the
auction; this does not depend on an owner transaction or another trade. It transfers
saved principal and removes launch-owned liquidity into the immutable
`LockedLaunchLiquidity` contract through Core forwarding. Other LPs' launch positions
are not removed. Core token-delta and saved-balance limits can require multiple
advances for unusually large positions.

A swap does not complete the launch. Ending runs `_finish`: it removes the launch
position, forwards principal to the liquidity contract and attempts terminal
migration, including TWAMM virtual-order execution and a balancing swap in another
pool. A swap at or after `endTime` that did this would be a new path for routers'
quoters to model, so such swaps keep reverting `LaunchEnded()` and completion stays a
separate permissionless `advance`.

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
`createFullRangePoolConfig(finalFee, TWAMM)`: the unamplified, full-range
stableswap configuration, with XYK price movement, no initialized-tick traversal,
and the TWAMM extension enabled. `TWAMM` is immutable per extension deployment.
Each launch receives its own full-range position owned by the liquidity contract.
Each migration attempt first executes the terminal pool's pending TWAMM virtual
orders through Core's nested-lock support, then reads the price. The bounds check
and the balancing trade use that executed price, and the bounds are checked again
immediately before the deposit. If the executed price is outside the bounds the
attempt defers and principal stays locked; it never reverts because of pending
orders. With no open orders execution is a no-op beyond virtual-order bookkeeping.

**Existing liquidity:** use its current liquidity and square-root price to solve the
fee-adjusted XYK balancing trade. For token0 input `x`, liquidity `L`, and square-root
price `s`, the idealized price movement is:

```text
net = x - inputFee(x)
s' = L*s / (L + net*s)
token1Out = L * (s - s')
```

The solver uses Core's actual rounding for these equations and the finite full-range
endpoints. It computes the equal-deposit input in closed form — the balance
condition reduces to a quadratic in the swap input, solved with scaled integer
arithmetic — and bisects for the exact balance flip over the narrowed range up to
that root, falling back to the full input range when the root is degenerate or the
flip lands on the narrowed edge. Cost does not depend on tick history. The solver
includes the position's own internal-fee rebate when predicting remaining
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
buyers. Once the launch is registered in the liquidity contract, any locker can
forward `LAUNCH_FUND(launchPoolId, amount0, amount1)` and pay the amounts, normally
through `LaunchRouter.fund`. Funding is an irrevocable contribution to principal. Then
call `migrate(launchPoolId)` to retry. Dust, capacity
limits, or price bounds may also leave reserves pending; they are never paid out as
creator fees.

A migration swap pays the destination's normal fixed pool fee to its LPs; there is
no additional creator surcharge. Before a rebalance, existing earned position fees
are preserved in a separate creator ledger. Fees the launch's own terminal position
earns from that internal rebalance are recycled into locked principal, preventing
migration retries from turning principal into creator income.

## Terminal fees and observability

The `LAUNCH_CLAIM_FEES` forward to `LockedLaunchLiquidity` is owner-only. It collects
only that launch's position fees, plus any external-trade fees saved before a
rebalance, and credits them to the owner to withdraw. Position liquidity and principal reserves are untouched. Other LPs retain
their own fee claims. The terminal pool's fixed fee persists after migration; the
TWAMM extension stays in its swap path, so canonical liquidity doubles as
time-distributed execution venue.

Use `getLaunch`, `released`, `feeAt`, and `terminalPool` on the extension. Use
`getTerminal` and `positionId` on the liquidity contract. Query Core saved balances
with the holder contract, token pair, and launch pool-ID salt for principal; use
that holder's `creatorFeeSalt` for creator fees. Query the terminal position's Core
liquidity to distinguish a pending migration from an established position.
`LaunchCreated`, `LaunchAdvanced`, `LaunchSwapped`, `PrincipalReceived`,
`LiquidityLocked`, and fee claim events accompany Core's normal pool, swap, and
position events. `LaunchCreated(poolId, token, owner, config)` records the owner of
record; `LaunchRouter`'s `LaunchCreatedBy(launchId, creator)` records the creator.
`PrincipalReceived(launchId, from, amount0, amount1)` records the extension for
migrated principal and the forwarding locker for funding (the router for
`LaunchRouter.fund`).

Attribution: trades attribute to the forwarding router's locker (`LaunchSwapped.locker`),
creation and funding to the periphery's events plus the transaction sender.

## Routing and quoting

Trading needs no launch-specific periphery. A router reaches launch pools with its generic
forwarded hop: `Core.forward(poolKey.config.extension(), abi.encode(poolKey, params))`,
reading the `PoolBalanceUpdate` from the first returned word. The Yul router's
`forwarded` hop does exactly this, so a launch pool is one hop in an ordinary route; the
Solidity `Router` does it for the forward-only extension it is deployed with. Routers
apply their usual slippage checks to the fee-inclusive deltas, and their reverting
quote paths quote launch swaps unchanged. `LaunchSwapped.locker` is the router, not the
end user.

An exact-input buy larger than the offered inventory fills partially at the top of the
range. A router that requires full fills rejects it; one that allows partial fills
settles the fill. An exact-input sell at or below the target fills zero, because
nothing is offered below it.

The next swap's result is a function of the launch config (from `LaunchCreated`), the
launch state after the last advance (`LaunchAdvanced(poolId, deployed, reserve0,
reserve1, complete)`), Core pool state (from Core's swap and position events; the
launch position is the pool's only liquidity), the block timestamp, and the swap
parameters. An indexer can therefore mirror launch state and quote without `eth_call`.
`test/vectors/scheduled-launch-swaps.json`, written by `ScheduledLaunchVectorsTest`,
gives conformance cases for that function: both token orders, a native quote, exact
input and output, buys and sells, a partial fill at the range top, and the first and
last second of the schedule. There is no creation seed, so launch reserves start with
the supply alone. Regenerate it with
`WRITE_LAUNCH_VECTORS=true forge test --match-contract ScheduledLaunchVectorsTest`
after an intended behavior change; otherwise the test checks it.

## Deployment and validation

`script/DeployScheduledLaunch.s.sol` deploys three contracts through the deterministic
deployer on any chain: it mines the extension's required address prefix and deploys
it, which deploys its immutable liquidity contract, then deploys `LaunchRouter` with
CREATE2 bound to that extension. `CORE_ADDRESS` and `TWAMM_ADDRESS` are required; `SALT`
(the starting salt, also the router's salt), `SCHEDULED_LAUNCH_ADDRESS` and
`LAUNCH_ROUTER_ADDRESS` (expected addresses) are optional. It checks that Core and TWAMM
have code, that Core has the TWAMM registered and that the router is bound to the
extension and its liquidity contract, and logs all three addresses and code hashes. It is a dry run unless `BROADCAST=true` is set, and
forge sends transactions only with `--broadcast` as well. No existing deployed
contract source is modified.

`script/launchpad-local.sh` starts an anvil fork, deploys the extension, its
liquidity contract and `LaunchRouter` with `script/DeployLaunchpadLocal.s.sol`, and
writes `launchpad-manifest.json` with addresses, runtime code hashes, fork block, and
git revision. Its `launch_router` entry is the periphery and its `router` entry is the
fork's existing Yul router (`ROUTER_ADDRESS`). It
is for local forks only and signs with anvil's development key.

Tests cover fee decay and fee-inclusive fills, internal-fee exemption, atomic
creation through `LaunchRouter` and direct forwards, forward dispatch, exact payment
for `LaunchRouter.fund`, creator-only claims, a self-owned forwarding owner, no token
custody by either launch contract or the router, both token orders, native
quote assets, swaps and quotes through the unmodified `Router` and a generic forwarded
hop, non-standard quote tokens and reentrant token callbacks, source and destination
accounting, existing/empty terminal pools, no-counterpart retries, price bounds and the
migration width cap, locked principal, per-position fees, internal-fee recycling,
chunked migration, live TWAMM orders during migration, TWAMM deployment wiring,
CREATE2 deployment and size limits, and the balancing solver against brute force.
