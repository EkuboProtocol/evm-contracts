# ve(3,3) Integrated Pool Extension

`Ve33Rewards` is a forward-only pool extension that combines voter-selected swap fees, voter fee distribution, and single-token LP rewards. It also contains the canonical vote-escrow lock accounting.

`VeToken` is an optional wrapper around `Ve33Rewards` lock accounting. It gives users the familiar `createLock`, `increaseLockAmount`, `extendLock`, and `withdrawLock` surface, but the important lock state remains in `Ve33Rewards`. This keeps the core ve logic independent from any particular NFT or transfer representation.

## Architecture

`Ve33Rewards` owns:

- pool initialization checks
- forward-only swap execution
- dynamic voter swap fees
- voter fee-growth accounting
- LP reward-token accounting
- ve lock amounts keyed by `(owner, salt, endTime)`
- vote clearing when a lock amount or end time changes

`VeToken` owns:

- user-facing lock ids
- local lock ownership checks
- stake-token payment and withdrawal settlement
- wrapper vote and pool-fee claim calls
- optional external representation of locks

The `owner` in `Ve33Rewards.LockKey` is the locker that forwarded the stake operation. For `VeToken` locks this is `address(veToken)`, not the user. The user is tracked by `VeToken`, and `VeToken` authorizes wrapper operations before calling into `Ve33Rewards`.

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

- `VE33_DEPOSIT_LOCK`: increases `lockAmounts[originalLocker][salt][endTime]`
- `VE33_WITHDRAW_LOCK`: decreases an expired lock and returns the unlocked amount
- `VE33_MOVE_LOCK`: moves amount from one `(salt, endTime)` to another

`Ve33Rewards` does not transfer stake tokens for these lock operations. It also does not update Core saved balances for the stake token, because forwarded calls execute with the extension as the temporary locker. The calling locker must settle the returned amount in its own lock context.

`VeToken` does this by updating saved balances under `address(veToken)` with salt `keccak256(abi.encode(address(veToken), salt, endTime))`, then paying to Core on deposit or withdrawing to the user on unlock. Extending is implemented as `VE33_MOVE_LOCK`: the wrapper loads saved balance from the old lock key and saves it under the new lock key without moving tokens.

## Voting

Votes can provide explicit `uint64` swap fees through `vote`, or tick spacings through `voteWithTickSpacing`. Tick-spacing votes are converted by `defaultFeeForTickSpacing`, which prices a `2 * tickSpacing` move and returns:

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

`Ve33Rewards.claimPoolFees(lockKey, poolKey)` subtracts the claimed amount from the extension's saved balance and withdraws token0/token1 to `lockKey.owner`.

For wrapper-owned locks, `lockKey.owner` is `address(veToken)`. `VeToken.claimPoolFees(veId, poolKey)` calls the extension, receives the claimed fees, and transfers them to the local lock owner.

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

`fundEmissions` transfers `stakeToken` into the extension and increases the global one-week emission stream. `triggerPoolEmissions` is permissionless and can be called for any pool using the extension.

When triggered, the extension accrues global emissions, accrues total and per-pool vote seconds, and assigns the pool a proportional share of `unallocatedEmissions` based on time-weighted vote seconds since the pool was last touched. The assigned amount is scheduled as LP reward-token emissions ending at the next valid time within one week.

## Settlement Model

The extension relies on Core saved balances for deferred accounting:

- swap fees are saved under `address(ve33Rewards)` and the pool id
- LP rewards are saved under `address(ve33Rewards)` and the reward reserve salt
- ve lock stake is saved by the calling locker, not by `Ve33Rewards`

Callers that integrate directly with `VE33_DEPOSIT_LOCK`, `VE33_WITHDRAW_LOCK`, or `VE33_MOVE_LOCK` must update their own saved balances and settle any payment or withdrawal in the same Core lock. `VeToken` is the reference implementation of that pattern.
