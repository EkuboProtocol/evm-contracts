# ve(3,3) Integrated Pool Extension

`VE33` is a forward-only pool extension that combines voter-selected swap fees, voter fee distribution, and single-token LP rewards. It also contains the canonical vote-escrow lock accounting.

`VeToken` is an optional wrapper around `VE33` lock accounting. It gives users the familiar `createLock`, `increaseLockAmount`, `extendLock`, and `withdrawLock` surface, but the important lock state remains in `VE33`. This keeps the core ve logic independent from any particular NFT or transfer representation.

## Architecture

`VE33` owns:

- pool initialization checks
- forward-only swap execution
- dynamic voter swap fees
- voter fee-growth accounting
- LP reward-token accounting
- ve lock amounts keyed by `(owner, salt, endTime)`
- Core saved balances for locked stake, keyed by the same lock id
- vote clearing when a lock amount or end time changes

`VeToken` owns:

- user-facing lock ids
- local lock ownership checks
- stake-token payment on staking and withdrawal on unstaking
- wrapper vote and pool-fee claim calls
- optional external representation of locks

`VE33Periphery` owns token settlement for generic VE33 actions such as swaps, LP reward claims, reward donations, explicit reward schedules, global emission funding, and emission triggering.

The `owner` in `VE33.LockKey` is the locker that forwarded the stake operation. For `VeToken` locks this is `address(veToken)`, not the user. The user is tracked by `VeToken`, and `VeToken` authorizes wrapper operations before calling into `VE33`.

Because the canonical lock state is independent of the wrapper, the same design can support other representations of locked stake, including a fungible ERC20 representation. This branch includes the `VeToken` wrapper and `VE33Periphery` settlement helper.

## Pool Requirements

Pools using this extension must set the Core pool-config fee to `0`. The active swap fee is stored in extension state and selected by ve voters.

The extension enables these Core call points:

- `beforeInitializePool`
- `beforeSwap`
- `beforeUpdatePosition`

Pool initialization validates `poolKey.config.fee() == 0` and stores the pool's default swap fee. Concentrated pools derive the default from tick spacing. Stableswap pools derive it from amplification. The default fee is capped at 50%.

Direct Core swaps are rejected in `beforeSwap`. Swaps must be made through `Core.forward` to the extension with `VE33_SWAP`.

## Lock Accounting

Locks are stored in:

```text
lockAmounts[owner][salt][endTime]
```

The lock id used for vote accounting is:

```text
keccak256(abi.encode(owner, salt, endTime))
```

Forward lock call types:

- `VE33_STAKE_LOCK`: increases `lockAmounts[originalLocker][salt][endTime]`
- `VE33_UNSTAKE_LOCK`: decreases an expired lock and returns the unlocked amount
- `VE33_MOVE_LOCK`: moves amount from one `(salt, endTime)` to another

`VE33` updates Core saved balances for locked stake under `address(ve33)` and the lock id:

```text
CORE.updateSavedBalances(stakeToken, address(type(uint160).max), lockId, delta, 0)
```

It does not transfer stake tokens for these lock operations. The calling representation handles token settlement: `VeToken` pays the stake token into Core after staking, and withdraws expired stake to the local lock owner after unstaking. Extending is implemented as `VE33_MOVE_LOCK`, which moves saved balance from the old lock id to the new lock id without moving tokens.

## Voting

`VE33.vote` accepts explicit `uint64` swap fees. Tick-spacing votes can be converted with `defaultFeeForTickSpacing`, and the optional `VeToken` wrapper exposes `voteWithTickSpacing` for that convenience path. The conversion prices a `2 * tickSpacing` move and returns:

```text
1 - 1 / 1.000001^(2 * tickSpacing)
```

Each pool tracks active vote weight, vote seconds, voter fee growth, the weighted fee sum, the active swap fee, and the default swap fee. When votes change, the pool fee is recomputed as `feeWeightSum / weight`; with no active votes, the pool uses its default fee.

Changing a lock clears that lock's votes before the amount or end time changes, keeping vote weights, fee-growth snapshots, and vote-second accounting synchronized with voting power.

## Forwarded Swap Accounting

The forwarded swap handler uses the supplied `SwapParameters` as-is. Routers and callers are responsible for setting default sqrt-ratio limits before forwarding.

For exact-input swaps, the extension computes the voter fee from the input amount, calls Core with `amount - fee`, adds the fee back to the returned input delta, saves the fee under the extension and pool id, and increases voter fee growth.

For exact-output swaps, the extension calls Core with the zero-config-fee exact-output parameters, grosses up the Core-computed input with `amountBeforeFee`, saves the extra input as voter fees, and increases voter fee growth.

Swap fees are stored with:

```text
CORE.updateSavedBalances(token0, token1, PoolId.unwrap(poolId), fee0, fee1)
```

The extension does not call `CORE.accumulateAsFees`, so LPs do not earn Core swap fees.

## Voter Fee Claims

Voter fees use fee-growth accounting over each pool's active vote weight. Each lock snapshots `feeGrowth0X128` and `feeGrowth1X128` for every voted pool.

`VE33_CLAIM_POOL_FEES` is a forwarded action. It subtracts the claimed amount from the extension's saved balance and returns the loaded token amounts to the forwarding locker.

For wrapper-owned locks, `lockKey.owner` is `address(veToken)`. `VeToken.claimPoolFees(veId, poolKey)` enters a Core lock, forwards the claim to `VE33`, and withdraws token0/token1 directly to the local lock owner.

## LP Reward Token

LPs earn only the immutable reward token, which is the same token used for ve locks. Reward accounting uses reward-per-liquidity accumulators:

- `poolRewardState`
- `rewardsGlobalPerLiquidity`
- `tickRewardsOutsidePerLiquidity`
- `positionRewardsSnapshotPerLiquidity`
- scheduled `rewardRateDeltaAtTime`

`maybeAccumulateRewards` advances `rewardsGlobalPerLiquidity` using current Core pool liquidity. If liquidity is zero, accrued rewards are not assigned to LPs.

`beforeUpdatePosition` snapshots position rewards before liquidity changes. It uses the same snapshot adjustment trick as Core: rewards earned before the update are preserved by moving `positionRewardsSnapshotPerLiquidity` based on the next liquidity value. If the position fully exits, the snapshot is cleared and unclaimed rewards are discarded.

Reward accounting is range-aware. The extension tracks `tickRewardsOutsidePerLiquidity` for initialized ticks and uses it to compute reward growth inside a position's tick range. Forwarded swaps explicitly update crossed tick reward snapshots so out-of-range positions do not earn rewards.

## Emissions

`VE33_FUND_EMISSIONS` is a forwarded action that saves funded `stakeToken` in Core and increases the global one-week emission stream. A periphery such as `VE33Periphery` pays the stake token into Core in the same lock.

`VE33_TRIGGER_POOL_EMISSIONS` is permissionless and can be forwarded for any pool using the extension. Triggering moves saved stake token from the emission reserve bucket into the LP reward reserve bucket and schedules the pool's reward stream; no external token transfer is needed.

When triggered, the extension accrues global emissions, accrues total and per-pool vote seconds, and assigns the pool a proportional share of `unallocatedEmissions` based on time-weighted vote seconds since the pool was last touched. The assigned amount is scheduled as LP reward-token emissions ending at the next valid time within one week.

## Settlement Model

The extension relies on Core saved balances for deferred accounting:

- swap fees are saved under `address(ve33)` and the pool id
- LP rewards are saved under `address(ve33)` and reward reserve salt `bytes32(0)`
- funded-but-unassigned emissions are saved under `address(ve33)` and emission reserve salt `bytes32(uint256(1))`
- ve lock stake is saved under `address(ve33)` and the lock id

`VE33` accounts for staking, unstaking, moving lock balances, reward funding, reward claiming, and fee claiming, but does not directly transfer tokens. Callers that integrate directly with token-moving forwarded actions must settle the corresponding payment or withdrawal in the same Core lock. `VeToken` is the reference implementation for lock-owned fee claims, and `VE33Periphery` is the reference implementation for generic VE33 token settlement.
