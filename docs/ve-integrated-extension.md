# ve(3,3) Integrated Pool Extension

`Ve33` is a forward-only pool extension that combines voter-selected swap fees, voter fee distribution, and single-token LP rewards. It also contains the canonical vote-escrow stake accounting.

`VeToken` is an optional ERC721 wrapper around `Ve33` stake accounting. It gives users the familiar `createStake`, `increaseStakeAmount`, `extendStake`, and `withdrawStake` surface, but the important stake state remains in `Ve33`. This keeps the core ve logic independent from any particular external representation while still allowing transferable NFT-based stake control.

For role-oriented user documentation, see [Ve33 User Guide](./ve33-user-guide.md).

## Architecture

`Ve33` owns:

- pool initialization checks
- forward-only swap execution
- dynamic voter swap fees
- voter fee-growth accounting
- LP reward-token accounting
- ve stake amounts keyed by `(owner, salt, endTime)`
- Core saved balances for staked tokens, keyed by the same stake id
- vote clearing when a stake amount or end time changes
- storage exposure through `ExposedStorage`, with typed read helpers in `Ve33Lib`

`VeToken` owns:

- transferable ERC721 stake ownership and approvals
- user-facing stake ids, used directly as the `Ve33` stake salt
- the stake end timestamp in Solady ERC721 token `extraData`
- stake-token payment on staking and withdrawal on unstaking
- wrapper vote and pool-fee claim calls
- on-chain ERC721 JSON metadata derived from the staked token and current stake state

`Ve33Positions` is the ERC721 LP position manager. It owns Core positions for Ve33 LPs, settles liquidity token payments, and forwards LP reward claims to `Ve33`. `Ve33Periphery` owns token settlement for generic Ve33 actions such as reward donations, explicit reward schedules, global emission funding, and emission triggering. Swaps are settled by the configured router. `Ve33` itself accounts balances only with Core saved balances and does not transfer ERC20s.

For LP positions, `Ve33Positions` derives the Core `PositionId` from `(tokenId, tickLower, tickUpper)` and owns the resulting Core position as the locker contract. ERC721 ownership and approvals authorize deposits, withdrawals, and reward claims. This keeps LP position ownership explicit without inheriting the standard `BasePositions` swap-fee collection assumptions.

The `owner` in `Ve33.StakeKey` is the locker that forwarded the stake operation. For `VeToken` stakes this is `address(veToken)`, not the user. The user is tracked by `VeToken`, and `VeToken` authorizes wrapper operations before calling into `Ve33`.

Because the canonical stake state is independent of the wrapper, the same design can support other representations of staked tokens, including a fungible ERC20 representation. This branch includes the transferable `VeToken` ERC721 wrapper, `Ve33Positions` LP NFT manager, and `Ve33Periphery` settlement helper.

## Pool Requirements

Pools using this extension must set the Core pool-config fee to `0`. The active swap fee is stored in extension state and selected by ve voters.

The extension enables these Core call points:

- `beforeInitializePool`
- `afterInitializePool`
- `beforeSwap`
- `beforeUpdatePosition`

Pool initialization validates `poolKey.config.fee() == 0` and concentrated power-of-4 tick spacing in `beforeInitializePool`. It stores the pool's default swap fee and emits the current `PoolSwapFeeUpdated` value in `afterInitializePool`, after Core has initialized the pool. With Core's current max tick spacing, the power-of-4 rule allows 10 concentrated pools per pair: `1`, `4`, `16`, `64`, `256`, `1024`, `4096`, `16384`, `65536`, and `262144`. This reduces near-duplicate pool fragmentation and preserves the gas benefits of binary-aligned spacing. Stableswap pools derive the default fee from amplification by converting amplification to an active-range width and then using the same tick-spacing fee formula. The default fee is capped at 50%. If voters have already selected a fee for a pool before it is initialized, initialization records the default fee without overwriting the active voted fee.

Direct Core swaps are rejected in `beforeSwap`. Swaps must be made through `Core.forward` to the extension with `VE33_SWAP`.

## Stake Accounting

Stakes are stored in:

```text
stakeAmounts[owner][salt][endTime]
```

For `VeToken`, `salt = bytes32(veId)`. The current stake amount is fetched from `Ve33Lib.stakeAmount(ve33, address(veToken), bytes32(veId), endTime)` whenever the wrapper needs it, so the NFT does not store the amount. The stake end timestamp is stored in Solady ERC721 `extraData`, which is large enough for the `uint64` end time.

The stake id used for vote accounting is:

```text
keccak256(abi.encode(owner, salt, endTime))
```

Forward stake call types:

- `VE33_STAKE`: increases `stakeAmounts[originalLocker][salt][endTime]`
- `VE33_UNSTAKE`: decreases an expired stake and returns the unstaked amount
- `VE33_MOVE_STAKE`: moves amount from one `(salt, endTime)` to another

`Ve33` updates Core saved balances for staked tokens under `address(ve33)` and the stake id:

```text
CORE.updateSavedBalances(stakeToken, address(type(uint160).max), stakeId, delta, 0)
```

It does not transfer stake tokens for these stake operations. The calling representation handles token settlement: `VeToken` pays the stake token into Core after staking, and withdraws expired stake to the current ERC721 owner after unstaking. Approved ERC721 operators can manage a represented stake, but unstaked tokens and claimed pool fees settle to the current NFT owner. Extending is implemented as `VE33_MOVE_STAKE`, which moves saved balance from the old stake id to the new stake id without moving tokens.

## Voting

`Ve33.vote` accepts explicit `uint64` swap fees. Fees are 0.64 fixed point, so `1 << 64` is 100%, and `capFee` caps voter-selected fees to `1 << 63` or 50%. The optional `VeToken` wrapper exposes `voteWithDefaultFees` for users who want to vote with each pool's default fee derived from the pool key, and `poke(veId)` as a permissionless convenience for refreshing stale represented stakes. Concentrated-pool defaults price a `2 * tickSpacing` move and return:

```text
1 - 1 / 1.000001^(2 * tickSpacing)
```

Each pool tracks active vote weight, vote seconds, voter fee growth, the weighted fee sum, the active swap fee, and the default swap fee. When votes change, each selected fee is capped, the pool fee is recomputed as `feeWeightSum / weight`, and integer division rounds down. With no active votes, the pool uses its default fee.

Voting power is sampled when `vote` or `poke` is called:

```text
stakeAmount * (endTime - block.timestamp) / VE33_MAX_STAKE_DURATION
```

That current power is split across the supplied relative weights and written into `PoolVoteState.weight` and each stake's `VePoolPosition.weight`. Stored pool weights do not continuously decay on their own. They change when the stake votes again, when a stake operation clears votes, or when anyone calls `poke` for the stake. Emission allocation uses these stored active weights over elapsed time.

Changing a stake clears that stake's votes before the amount or end time changes, keeping vote weights, fee-growth snapshots, and vote-second accounting synchronized with voting power.

`poke` is a permissionless stale-vote cleanup path. It accrues total vote seconds, pool vote seconds, and the stake's voter fees using the existing stored weights up to the poke timestamp, then reduces the stake's active pool weights to current decayed voting power. If the stake has expired, `poke` clears its votes and the affected pools fall back to their default fees when no other votes remain. `VeToken.poke(veId)` calls the same extension logic for ERC721-represented stakes. Claiming pool fees does not poke automatically, so users who intend to extend or restake can avoid redundant weight-refresh gas.

`vote` is not a forwarded action because it does not require token settlement. It must be called by `stakeKey.owner`; for the ERC721 wrapper that means `VeToken` authorizes the user or approved operator, then calls `Ve33.vote` as the stake owner.

## Forwarded Swap Accounting

The forwarded swap handler uses the supplied `SwapParameters` as-is. Routers and callers are responsible for setting default sqrt-ratio limits before forwarding.

For exact-input swaps, the extension computes the maximum voter fee from `params.amount()`, calls Core with `amount - fee`, then computes the actual charged fee from the executed input delta returned by Core. If the swap executes partially, for example because it hits `sqrtRatioLimit`, the charged fee is capped to the maximum fee removed before the Core swap. The fee is added back to the returned input delta, saved under the extension and pool id, and accounted to voter fee growth.

For exact-output swaps, the extension calls Core with the zero-config-fee exact-output parameters, grosses up the Core-computed input with `amountBeforeFee`, saves the extra input as voter fees, and increases voter fee growth.

Swap fees are stored with:

```text
CORE.updateSavedBalances(token0, token1, PoolId.unwrap(poolId), fee0, fee1)
```

The extension does not call `CORE.accumulateAsFees`, so LPs do not earn Core swap fees. Only fees accounted while a pool has nonzero active vote weight increase voter fee growth. If the default fee is active with no voter weight, swap fees are still saved under the pool id but are not assigned to any current or future voter position.

## Voter Fee Claims

Voter fees use fee-growth accounting over each pool's active vote weight. Each stake snapshots `feeGrowth0X128` and `feeGrowth1X128` for every voted pool. On vote changes and vote clearing, `Ve33` first accrues the stake's pending fees from the pool growth delta into `VePoolPosition.accrued0` and `VePoolPosition.accrued1`.

`VE33_CLAIM_POOL_FEES` is a forwarded action. It subtracts the claimed amount from the extension's saved balance and returns the claimed token amounts to the forwarding locker.

For wrapper-owned stakes, `stakeKey.owner` is `address(veToken)`. `VeToken.claimPoolFees(veId, poolKey)` enters a Core lock, forwards the claim to `Ve33`, and withdraws token0/token1 directly to the local stake owner.

## LP Reward Token

LPs earn only the immutable reward token, which is the same token used for ve stakes. LP rewards are independent of Core swap fees. Reward accounting uses reward-per-liquidity accumulators:

- `poolRewardState`, which packs last-accumulated time and the current Q32 reward rate
- `rewardsGlobalPerLiquidity`
- `tickRewardsOutsidePerLiquidity`
- `positionRewardsSnapshotPerLiquidity`
- scheduled `rewardRateDeltaAtTime`

`maybeAccumulateRewards` advances `rewardsGlobalPerLiquidity` using current Core pool liquidity. For stableswap pools, active liquidity is treated as zero when the current tick is outside the stableswap active-liquidity range. If liquidity is zero, accrued scheduled rewards are not assigned to LPs because `rewardsGlobalPerLiquidity` is not increased.

`VE33_ADD_REWARDS` schedules a Q32 reward rate between valid reward times. If `startTime` is in the past or zero, the new rate is applied immediately; otherwise a future rate delta is stored in `rewardRateDeltaAtTime`. The required token amount is rounded up from `rewardRate * duration` and saved in the reward reserve. `VE33_DONATE_REWARDS` immediately increases `rewardsGlobalPerLiquidity` for current active liquidity. For stableswap pools, active liquidity is zero outside the stableswap active-liquidity range. If active liquidity is zero, the donated amount is still credited to the reward reserve saved balance, but no position reward growth is created, so the donation is not claimable by LP positions.

`beforeUpdatePosition` snapshots position rewards before liquidity changes. It uses the same snapshot adjustment trick as Core: rewards earned before the update are preserved by moving `positionRewardsSnapshotPerLiquidity` based on the next liquidity value. If the position fully exits, the snapshot is cleared and unclaimed rewards are discarded.

Reward accounting is range-aware. The extension tracks `tickRewardsOutsidePerLiquidity` for initialized ticks and uses it to compute reward growth inside a position's tick range:

```text
below range:  lowerOutside - upperOutside
in range:     rewardsGlobalPerLiquidity - lowerOutside - upperOutside
above range:  upperOutside - lowerOutside
```

Forwarded swaps explicitly invert reward-outside snapshots for crossed concentrated ticks. For stableswap pools, the active-liquidity lower and upper ticks are updated when swaps cross the stableswap active range. This prevents out-of-range positions from earning rewards while they are out of range.

`VE33_CLAIM_REWARDS` accumulates the pool, computes the position's reward amount from the difference between current in-range reward growth and `positionRewardsSnapshotPerLiquidity`, updates the snapshot to current in-range growth, subtracts the claimed amount from the reward reserve saved balance, and returns the amount to the forwarding locker for withdrawal by `Ve33Positions`.

## Emissions

`VE33_FUND_EMISSIONS` is a forwarded action that saves funded `stakeToken` in Core and increases the global emission stream until a caller-chosen end time. The end time must be a valid reward-accounting timestamp and must be greater than the current block timestamp. A periphery such as `Ve33Periphery` pays the stake token into Core in the same lock. Funding first accrues any existing global emissions into `unallocatedEmissions`, then adds a new Q32 global emission rate and schedules a matching rate decrease at the chosen end time. End times are tracked in a bitmap, so multiple fundings can share the same end time without storing an append-only list.

`VE33_TRIGGER_POOL_EMISSIONS` is permissionless and can be forwarded for any pool using the extension. Triggering moves saved stake token from the emission reserve bucket into the LP reward reserve bucket and schedules the pool's reward stream; no external token transfer is needed.

When triggered, the extension accrues global emissions, accrues total vote seconds, accrues the selected pool's vote seconds, and assigns the pool a proportional share of `unallocatedEmissions`:

```text
poolShare = unallocatedEmissions * poolVoteSeconds / totalVoteSeconds
```

`poolVoteSeconds` is the pool's stored active vote weight integrated over time since that pool's vote seconds were last accrued. `totalVoteSeconds` is the corresponding global active vote weight integrated over time. After a successful trigger, the selected pool's `voteSeconds` are reset to zero and the same amount of seconds is subtracted from `totalVoteSeconds`, so each pool can be triggered independently without double-counting the same voting interval. The assigned amount is scheduled as LP reward-token emissions from now until the next valid reward time within the per-pool emission duration.

Emissions are not triggered automatically on swaps, reward claims, or position updates. A caller must forward `VE33_TRIGGER_POOL_EMISSIONS` for the specific pool.

## Settlement Model

The extension relies on Core saved balances for deferred accounting:

- swap fees are saved under `address(ve33)` and the pool id
- LP rewards are saved under `address(ve33)` and reward reserve salt `bytes32(0)`
- funded-but-unassigned emissions are saved under `address(ve33)` and emission reserve salt `bytes32(uint256(1))`
- ve stake is saved under `address(ve33)` and the stake id

`Ve33` accounts for staking, unstaking, moving stake balances, reward funding, reward claiming, and fee claiming, but does not directly transfer tokens. Callers that integrate directly with token-moving forwarded actions must settle the corresponding payment or withdrawal in the same Core lock. `VeToken` is the reference implementation for stake-owned fee claims and stake-token settlement, `Ve33Positions` is the reference implementation for LP position and reward-claim settlement, and `Ve33Periphery` is the reference implementation for generic reward and emission token settlement.

## Deployment

`script/DeployVe33.s.sol` deploys `Ve33`, `VeToken`, `Ve33Positions`, and `Ve33Periphery` with deterministic CREATE2 deployment. It requires `CORE_ADDRESS` and `STAKE_TOKEN`, and accepts optional expected-address environment variables for deployment verification. See the user guide for the operator-facing command.
