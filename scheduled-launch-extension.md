# Scheduled token launches

`ScheduledLaunch` deploys a fixed-supply token and initializes its pool atomically.
It releases token inventory linearly between configured start and end times. Before
external swaps, it sells available inventory toward a fixed target price and adds
remaining balances to a launch-owned liquidity position. Once the launch ends, one
final advancement marks it complete and subsequent swap callbacks become no-ops.

## Creating a launch

Call `Core.forward(address(extension))` inside an existing Core lock, appending
`abi.encode(ScheduledLaunch.LaunchConfig)` to its calldata. The authenticated
forwarding handler returns `abi.encode(PoolKey)`. `FlashAccountantLib.forward` handles
this calling convention. See the `LaunchCreator` test helper for a complete example
of forwarding and funding; a production wallet/router integration should also enforce
its own caller authorization and native-value/refund policy.

The configuration includes:

| Field | Meaning |
| --- | --- |
| `owner` | Nonzero beneficiary, authorized to withdraw after completion |
| `quoteToken` | Paired asset; address zero means native ETH |
| `name`, `symbol`, `decimals` | Metadata for the deployed `MintableERC20` |
| `totalSupply` | Entire fixed token supply, initially reserved for this launch |
| `quoteAmount` | Optional quote seed, owed by the forwarding locker to Core |
| `startTime`, `endTime` | Future or current start and strictly later end |
| `targetTick`, `upperTick` | Fixed economic target and upper sell-range boundary |
| `tickSpacing`, `fee` | Concentrated-pool parameters |

Ticks express **raw quote units per raw launch-token unit**, regardless of token
address ordering. The extension negates ticks and reverses bounds when the deployed
token is token1. Account for token decimals when converting a human price to a tick.
Both bounds must align with tick spacing; the target must be below the upper bound.
Initialization occurs exactly at the target. Supply must be positive and supply/seed
must each fit a positive int128. Token metadata uses the existing implementation's
packed-string limits (31 bytes per name/symbol).

Creation deploys `MintableERC20` with the extension as temporary token owner, mints
all inventory, and renounces token ownership. The separately recorded launch owner
has **no further minting authority**. All token inventory is paid into Core and saved
under the extension, token pair, and pool-ID salt. Optional quote funding creates debt
that the forwarding locker must settle before its lock returns. Any failure rolls
back token deployment, minting, state, funding, and pool initialization.

Only `beforeInitializePool` and `beforeSwap` call points are enabled. The initialization
callback always reverts. Core skips it when the extension itself initializes, so
validated forwarding is the only pool-creation path. Core also skips the extension's
swap callback during its own swaps.

## Release, sales, and liquidity

Cumulative released supply is zero before/at start, the entire supply at/after end,
and otherwise:

```text
released = totalSupply * (now - startTime) / (endTime - startTime)
available = released - deployed
```

`deployed` counts launch tokens consumed by both exact-input sales and positive
liquidity additions. It does not count quote assets or tokens circulating inside LP
positions. Remaining saved token inventory equals `totalSupply - deployed`.
Releases depend on elapsed time, never swap count. Swaps before start revert;
permissionless advancement before start leaves the launch unchanged.

On advancement:

1. Sell available inventory only if the economic price is above target. The swap's
   price limit is the target, and its input limit is released, undeployed inventory.
2. Add liquidity in the fixed range from target to upper boundary using available
   released tokens and saved quote proceeds. At/below target this is single-sided
   launch-token liquidity. Above target, an active position needs both assets.
3. Carry forward balances that do not fit. Never use unreleased tokens to pair quote.
4. If time has reached the end, mark complete even when dust, missing counterparts,
   or exhausted tick capacity prevent full deployment.

Quote proceeds remain attributed to the launch. At the target, the chosen position
cannot accept quote assets, so excess proceeds stay reserved. **This implementation
does not place a separate buy position below target.** Quote seed follows the same
rule; seeding quote does not guarantee two-sided depth at the target.

Price can move below target through other liquidity or empty-range traversal. In
that state, skip sales and continue adding token-side liquidity. No price floor or
elimination of sniper profit is promised. Internal sales against launch-owned LPs
move assets between positions and reserves; external funding comes from net buyer
purchases, not from the internal swap itself.

Liquidity additions respect remaining capacity at both boundary ticks, including
liquidity owned by other LPs. A sale is skipped when saved quote already exceeds
int128.max, retaining headroom for a signed swap output in Core's uint128 saved
balance. Sales also cap input at the current price so output fits a signed delta;
liquidity additions and withdrawals are similarly capped. These capacity
conditions leave residual balances, not an endless completion requirement.

## Completion and owner rights

Anyone may call `advance(PoolKey)`; no trade or owner availability is needed to finish.
Reaching target early does not finish the schedule. After end time, the next advance
or external swap performs final management. Completion is irreversible. Normal
subsequent swaps do not load reserves, trade for the launch, or change its positions.

The owner can call `withdraw(PoolKey, recipient)` only after completion, collecting
fees before removing liquidity, then withdrawing saved reserves. Principal withdrawal
is capped to Core's signed token-delta limits; call again if a large position retains
liquidity. Normal-sized positions are removed in one call. The recipient
must be nonzero. **Liquidity is owner-withdrawable, not permanently locked.** This
explicit owner action is separate from automatic management. Before completion,
there is no owner withdrawal, cancellation, schedule mutation, or inventory rescue.
Owner identity is immutable; there are no owner transfers or platform admin powers.

Get configuration/accounting with `getLaunch(PoolId)`, release progress with
`released(PoolId)`, and reserves with `CoreLib.savedBalances` using the extension
address and pool-ID salt. `LaunchCreated` includes configuration, token, owner, and
pool ID; `LaunchAdvanced` includes deployed supply and completion; `LaunchWithdrawn`
records the recipient. Core emits the underlying pool/position/swap events.

## Deployment and validation

`script/DeployScheduledLaunch.s.sol` mines the required extension address prefix and
uses the existing deterministic deployer. Configure `CORE_ADDRESS` (defaults to the
canonical Core), optional starting `SALT`, and optional expected
`SCHEDULED_LAUNCH_ADDRESS`. Run with `forge script --offline`; broadcasting is a
separate deployment decision. No existing deployed contract source is changed.

The test suite covers both asset orderings, fixed supply and ownership, atomic
rollback, hook authentication, release rounding, native/ERC-20 quote funding,
insufficient released inventory, sales to target, below-target releases, reserve
isolation, owner withdrawal, fees, completion, trading/accounting sequences, extreme
prices and supplies, large quote-output bounds, chunked principal withdrawals, third-party
tick capacity, and real CREATE2 deployment with the required prefix.
