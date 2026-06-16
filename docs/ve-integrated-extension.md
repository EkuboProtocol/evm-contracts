# ve(3,3) Integrated Pool Extension

`Ve33Rewards` is a pool extension paired with `VeToken`, a separate vote-escrow NFT contract.

`VeToken` owns the lock lifecycle:

- `stakeToken` custody
- Solady ERC721 ownership, approvals, and transfers with name/symbol derived from the stake token
- ve NFT mint/burn through `createLock` and `withdrawLock`
- packed `Lock` custom-type storage for amount/end updates
- linear voting-power decay over a maximum four-year lock

`Ve33Rewards` adds the pool-specific ve(3,3) behavior:

- pool voting
- voter-directed swap-fee collection
- single-token LP rewards

The split keeps the extension bytecode focused on pool accounting. The NFT and stake-token lock operations live in `VeToken`, and the extension stores immutable references to both `stakeToken` and `veToken`.

It is intended for pools where LPs do not earn Core swap fees. Pools using this extension must set the Core pool-config fee to `0`; the active swap fee is stored in extension state and is chosen by ve voters.

## Pool Requirements

The extension enables these Core call points:

- `beforeInitializePool`
- `beforeSwap`
- `beforeUpdatePosition`

Pool initialization validates that `poolKey.config.fee() == 0`. The extension stores the pool's default swap fee during initialization. Concentrated pools derive that default from tick spacing with `defaultFeeForTickSpacing(poolKey.config.concentratedTickSpacing())`; stableswap pools derive it from amplification with `defaultFeeForStableswapAmplification(poolKey.config.stableswapAmplification())`.

Direct Core swaps are rejected in `beforeSwap`. Swaps must be made through `Core.forward` to the extension with `VE33_SWAP`.

## Forward And Lock Calls

Forwarded calls run with the extension as the current locker, so Core skips the extension hooks for the nested Core operation. The extension therefore performs the necessary accounting inside `handleForwardData`.

Forward call types:

- `VE33_SWAP`: execute a zero-config-fee Core swap and account voter fees
- `VE33_CLAIM_REWARDS`: claim LP reward-token earnings for the original locker
- `VE33_DONATE_REWARDS`: immediately add reward token to active liquidity
- `VE33_ADD_REWARDS`: schedule reward-token emissions for LPs

Extension lock call types:

- `VE33_LOCK_CLAIM_POOL_FEES`: withdraw saved swap fees to the ve NFT owner
- `VE33_LOCK_TRIGGER_POOL_EMISSIONS`: route accrued emissions to one voted pool

## Dynamic Swap Fees

Votes can provide explicit `uint64` swap fees through `vote`, or tick spacings through `voteWithTickSpacing`. Tick spacing votes are converted by `defaultFeeForTickSpacing`, which prices a `2 * tickSpacing` move and returns:

```text
1 - 1 / 1.000001^(2 * tickSpacing)
```

The fee is a 0.64 fixed-point value and is capped at 50%.

Each pool tracks:

- active vote weight
- vote seconds for emissions
- token0/token1 fee growth for voters
- weighted fee sum
- active swap fee
- default swap fee

When votes change, the active pool fee is recomputed as `feeWeightSum / weight`. If a pool has no active votes, it falls back to its default swap fee.

## Lock Updates And Votes

`VeToken` can be deployed with a `lockObserver`. For the integrated system this observer is the `Ve33Rewards` extension address. Before lock amount changes, lock extensions, or withdrawals, `VeToken` calls `Ve33Rewards.beforeLockUpdate(veId, currentLock)`, passing the packed pre-update lock state.

Only the configured `veToken` may call `beforeLockUpdate`. The callback clears the ve NFT's pool votes before its voting power changes. This keeps vote weights, weighted fee selection, fee-growth snapshots, and vote-second accounting synchronized with the lock's current voting power.

## Forwarded Swap Accounting

The forwarded swap handler uses the supplied `SwapParameters` as-is. Routers and other callers are responsible for setting default sqrt-ratio limits before forwarding swaps.

For exact-input swaps:

1. Compute the voter fee from the specified input amount.
2. Call Core with `amount - fee`.
3. Add the fee back to the returned input delta.
4. Save the fee under the extension and pool id.
5. Increase voter fee growth for the pool.

For exact-output swaps:

1. Call Core with the zero-config-fee exact-output parameters.
2. Gross up the Core-computed input with `amountBeforeFee`.
3. Add the extra input to the returned balance delta.
4. Save the fee under the extension and pool id.
5. Increase voter fee growth for the pool.

Swap fees are stored with:

```text
CORE.updateSavedBalances(token0, token1, PoolId.unwrap(poolId), fee0, fee1)
```

The extension does not call `CORE.accumulateAsFees`, so these swap fees do not enter LP fee growth.

## Voter Fee Claims

Voter fees use fee-growth accounting over each pool's active vote weight. Each ve position snapshots `feeGrowth0X128` and `feeGrowth1X128` for every voted pool.

`claimPoolFees` can be called by an authorized ve NFT operator. It locks the extension, accrues the caller's fee growth, subtracts the claimed amount from the extension's saved balance, and withdraws token0/token1 to the current `VeToken.ownerOf(veId)`.

Because voter fee growth is divided by active vote weight, claims can leave small rounding dust in the extension saved balance.

## LP Reward Token

LPs only earn the immutable reward token, which is the same `stakeToken` locked by `VeToken`. Reward accounting uses reward-per-liquidity accumulators:

- `poolRewardState`
- `rewardsGlobalPerLiquidity`
- `tickRewardsOutsidePerLiquidity`
- `positionRewardsSnapshotPerLiquidity`
- scheduled `rewardRateDeltaAtTime`

`maybeAccumulateRewards` advances `rewardsGlobalPerLiquidity` using the current Core pool liquidity. If liquidity is zero, accrued rewards are not assigned to LPs.

`beforeUpdatePosition` snapshots the position's rewards before liquidity changes. It uses the same snapshot adjustment trick as Core: rewards earned before the update are preserved by moving `positionRewardsSnapshotPerLiquidity` based on the next liquidity value. If the position fully exits, the snapshot is cleared and unclaimed rewards are discarded.

## Tick Reward Snapshots

Reward accounting is range-aware. The extension tracks `tickRewardsOutsidePerLiquidity` for initialized ticks and uses it to compute reward growth inside a position's tick range.

When a position initializes a tick, the outside value is initialized to:

- `rewardsGlobalPerLiquidity` if the current pool tick is at or above that initialized tick
- `0` otherwise

Because forwarded Core swaps skip extension hooks, the forwarded swap path explicitly:

1. accumulates rewards before calling Core
2. records the pre-swap tick
3. calls Core
4. walks crossed initialized ticks after the swap
5. inverts each crossed tick's outside reward value

This prevents out-of-range positions from earning rewards while swaps move the active range.

## Emissions

`fundEmissions` transfers `stakeToken` into the extension and increases the global one-week emission stream. `triggerPoolEmissions` is permissionless and can be called for any pool using the extension.

When triggered, the extension accrues global emissions, accrues total and per-pool vote seconds, and assigns the pool a proportional share of `unallocatedEmissions` based on the pool's time-weighted vote seconds since it was last touched. The assigned amount is scheduled as LP reward-token emissions ending at the next valid time within one week.

## Settlement Model

Forwarded reward funding and donations only update saved balances. The caller's lock must settle the resulting debt with the accountant. Swap fee collection follows the same saved-balance model, but the fees are saved under the extension and later withdrawn by `claimPoolFees`.
