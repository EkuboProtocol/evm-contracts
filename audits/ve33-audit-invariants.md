# Ve33 Audit Invariants

This file defines expected invariants for automated audit tooling over `Ve33`, `VeToken`, and `Ve33Positions`.
Treat contract code as authoritative when documentation and implementation differ.

## Reviewed Sources

- `docs/ve33-user-guide.md`
- `docs/ve-integrated-extension.md`
- `README.md`
- `whitepaper.md`
- `skills/ekubo-extension-authoring/references/extension-patterns.md`
- `src/extensions/Ve33.sol`
- `src/VeToken.sol`
- `src/Ve33Positions.sol`
- `src/interfaces/extensions/IVe33.sol`
- `src/libraries/Ve33StorageLayout.sol`
- `src/libraries/Ve33Lib.sol`
- `src/types/stakeId.sol`
- `src/types/ve33GlobalEmissionState.sol`
- `src/types/vePoolVote.sol`
- `src/types/vePoolFeeState.sol`

## Notation

- `owner` means the canonical Ve33 stake or position owner. For `VeToken` stakes this is `address(veToken)`, not the user.
- `stakeId = bytes24 salt || uint64 endTime`.
- `poolId = poolKey.toPoolId()`.
- `stake-balance bucket` means Core saved balance `(stakeToken, address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID)` owned by `address(ve33)`.
- `pool-fee bucket` means Core saved balance `(poolKey.token0, poolKey.token1, VE33_POOL_FEES_SAVED_BALANCE_ID)` owned by `address(ve33)`.
- `active vote` means a nonzero `VePoolVote.weight()` stored for `(owner, stakeId)` and a matching nonzero `votedPoolId`.

## Storage Layout Invariants

### V33-STOR-001: Ve33 Manual Storage Only

`Ve33` must not declare mutable storage variables other than immutables. All mutable state must be accessed through `Ve33StorageLayout`.

Expected evidence:

- The only declared contract state in `Ve33` is immutable or constant.
- Every `StorageSlot.load`, `store`, `loadTwo`, or `storeTwo` in `Ve33` is derived from `Ve33StorageLayout`.

### V33-STOR-002: Fixed Slots Do Not Collide

The fixed slots below are reserved and must never be reused by dynamic slot families:

```text
0: totalVoteWeight
1: emissionGrowthGlobalX128
2: globalEmissionState = uint160 emissionRate || uint32 lastAccrued
```

No dynamic slot helper may return `0`, `1`, or `2` for any valid key.

### V33-STOR-003: Dynamic Slot Families Are Disjoint

The following slot families must be pairwise disjoint, including any adjacent slot used by two-word values:

- `stakeAmountSlot(owner, stakeId)`
- `votedPoolIdSlot(owner, stakeId)`
- `vePoolVoteSlot(owner, stakeId)`
- `vePoolFeeGrowthSnapshotSlot(owner, stakeId)` and `.next()`
- `poolEmissionGrowthGlobalX128SnapshotSlot(poolId)`
- `poolFeeStateSlot(poolId)`
- `poolTotalWeightSlot(poolId)`
- `poolFeeGrowthSlot(poolId)` and `.next()`
- `rewardsGlobalPerLiquiditySlot(poolId)`
- `tickRewardsOutsidePerLiquiditySlot(poolId, tick)`
- `positionRewardsSnapshotPerLiquiditySlot(poolId, owner, positionId)`
- `emissionInitializedTimeBitmapSlot(word)`
- `emissionRateDeltaAtTimeSlot(time)`

Changing any `*_OFFSET` constant in `Ve33StorageLayout` must be treated as storage-layout breaking unless a full collision proof is supplied.

### V33-STOR-004: Library Readers Match Contract Writers

Every `Ve33Lib` read helper must use the same `Ve33StorageLayout` helper and packed type parser as the corresponding `Ve33` write path.

High-risk examples:

- `Ve33Lib.votingPower` must derive expired real `uint64` stake times consistently with `Ve33._votingPower`.
- `Ve33Lib.globalEmissionState` must parse the exact slot written by `_setGlobalEmissionState`.
- `Ve33Lib.poolFeeGrowth` and `Ve33Lib.vePoolFeeGrowthSnapshot` must read both words in the same order written by `Ve33`.

### V33-STOR-005: Packed Types Must Mask Before Assembly Use

Packed custom types must preserve field widths and must not allow high bits to leak into values later used in assembly:

- `StakeId`: `bytes24 salt`, `uint64 endTime`.
- `VePoolVote`: `uint64 timestamp`, `uint64 swapFee`, `uint128 weight`.
- `VePoolFeeState`: `uint64 swapFee`, `uint192 feeWeightSum`.
- `Ve33GlobalEmissionState`: `uint32 lastAccrued`, `uint160 emissionRate`.

Any conversion from raw storage to a narrower integer must be performed through the custom type parser or an equivalent masked operation.

## Pool And Forwarding Invariants

### V33-POOL-001: Ve33 Pool Key Validation

User-callable paths that accept untrusted `PoolKey` input and mutate Ve33 pool state must reject invalid pool keys before state-dependent mutation unless the operation will otherwise fail safely before mutation:

- `poolKey.config.extension() == address(ve33)`.
- `poolKey.config.fee() == 0` for `Ve33` pool accounting.
- concentrated pool tick spacing is a power of four.

Important boundaries:

- `vote`, forwarded swaps, public reward accumulation, and forwarded LP reward claims validate the full Ve33 pool configuration because they accept untrusted pool keys.
- Pool-fee claims verify `poolKey.toPoolId() == votedPoolId(owner, stakeId)` instead of revalidating the pool key, because the voted pool id was only written by a validated vote.
- Trusted Core hooks for initialized pools, including `afterInitializePool` and `beforeUpdatePosition`, must not perform redundant full validation. `afterInitializePool` relies on `beforeInitializePool`, and `beforeUpdatePosition` relies on Core dispatch for an initialized pool using this extension.
- `Ve33Positions` validates `extension == address(ve33)` on untrusted user input before managing positions; Core and Ve33 own the remaining pool validation.

### V33-POOL-002: Direct Core Swaps Are Forbidden

`Ve33.beforeSwap` must always revert. Successful Ve33 swaps must execute through `Core.forward(address(ve33), encode(VE33_SWAP, poolKey, params))`.

### V33-POOL-003: Ve33 Does Not Transfer ERC20s

`Ve33` must never call ERC20 transfer helpers. All token movement is represented by Core saved-balance deltas. Wrappers and periphery contracts must settle payments or withdrawals in the same Core lock.

## Stake Accounting Invariants

### V33-STK-001: Stake Amount Backing

For every successful `VE33_STAKE`, the stake amount and the stake-balance bucket increase by exactly `amount`.
For every successful `VE33_UNSTAKE`, the stake amount and the stake-balance bucket decrease by exactly the unstaked amount.
`moveStake` must not change Core saved balances.

### V33-STK-002: Valid New Stake Times

Any new nonzero stake destination must satisfy:

- `stakeId.endTime() > block.timestamp`.
- `stakeId.endTime() - block.timestamp <= VE33_MAX_STAKE_DURATION`.

Stake times are real `uint64` epoch times. Stake duration checks must not use modulo arithmetic.

### V33-STK-003: Voting Power Formula

For valid non-expired stakes:

```text
votingPower = stakeAmount(owner, stakeId) * (stakeId.endTime() - block.timestamp) / VE33_MAX_STAKE_DURATION
```

Voting power is zero if the stake is expired or its end time is more than `VE33_MAX_STAKE_DURATION` seconds in the future.

### V33-STK-004: Move Stake Direction

For nonzero `moveStake(fromStakeId, toStakeId, amount)` where `fromStakeId != toStakeId`:

- `amount <= stakeAmount(owner, fromStakeId)`.
- `toStakeId.endTime() >= fromStakeId.endTime()`.
- `toStakeId` is otherwise a valid new stake time.
- source amount decreases by `amount`.
- destination amount increases by `amount`.
- source and destination votes are resized to their new current voting power if they already had active votes.

Moving to the same stake id is a no-op after checking `amount <= stakeAmount(owner, fromStakeId)`.

### V33-STK-005: VeToken Split Preserves Source Stake

`Ve33` exposes only `moveStake`; both `VeToken.splitStake` and `VeToken._mergeStakes` delegate to it. `VeToken.splitStake` enforces that the source amount must remain nonzero before calling `Ve33.moveStake`. For nonzero `VeToken.splitStake(veId, amount)`:

- `fromStakeId != toStakeId` (fresh NFT mint guarantees a new salt).
- `toStakeId.endTime() == fromStakeId.endTime()` (same end time as source).
- `toStakeId` is otherwise a valid new stake time.
- `amount < stakeAmount(VeToken, fromStakeId)` (source stays nonzero, enforced in VeToken before calling `moveStake`).
- source amount decreases by `amount`.
- destination amount increases by `amount`.
- source vote is resized to its new current voting power if it had an active vote.

`VeToken.splitStake` mints a fresh destination NFT, so the new wrapped stake starts unvoted.
`VeToken._mergeStakes` moves the full source amount into the destination using `moveStake` and burns the source NFT.

## Vote And Swap Fee Invariants

### V33-VOTE-001: Vote With Zero Power Clears Existing Vote

`vote(stakeId, poolKey, swapFee)` with zero current voting power must not revert and must not apply new vote weight. If there is an existing vote with nonzero stored weight (e.g. a stake that has since expired), that vote must be cleared, removing it from pool, fee-growth, and total-weight state. No new vote is applied.

### V33-VOTE-002: Aggregate Vote Weight Consistency

For reachable active votes:

```text
totalVoteWeight == sum(poolTotalWeight[poolId])
poolTotalWeight[poolId] == sum(active vote weights for poolId)
poolFeeState[poolId].feeWeightSum == sum(active vote weight * active vote swapFee for poolId)
poolFeeState[poolId].swapFee == poolFeeState[poolId].feeWeightSum / poolTotalWeight[poolId]
```

If `poolTotalWeight[poolId] == 0`, the effective swap fee must be zero.

### V33-VOTE-003: One Active Pool Per Stake

Each `(owner, stakeId)` can have at most one active voted pool. If `votedPoolId(owner, stakeId) == 0`, `vePoolVote(owner, stakeId).weight()` and the stake fee-growth snapshots must be zero.

### V33-VOTE-004: Vote Changes Accrue Before Mutation

Before changing a pool's active vote weight, Ve33 must:

- accrue global emissions,
- realize that pool's pending emission share against current Core liquidity,
- update voter fee-growth snapshots so already accrued fees are preserved for nonzero resized votes.

When a vote is cleared to zero, pending unclaimed voter fees are intentionally discarded.

### V33-VOTE-005: Vote Events Reconstruct Current Fee

Every non-no-op vote weight change must emit:

```text
VoteWeightApplied(owner, stakeId, poolId, weight, swapFee)
```

The last event by `(owner, stakeId, poolId)` must reconstruct that stake's current weight, and the last event by `poolId` must expose the current pool swap fee after the weight change.

## Voter Fee Invariants

### V33-FEE-001: Fees Are Accounted Only In The Unspecified Token

Forwarded swaps account Ve33 voter fees only in the token opposite the specified (exact-amount) token:

- exact input: fee is taken from the output token delta,
- exact output: fee is taken from the input token delta.

Only nonzero fee amounts may increase the pool-fee bucket and pool fee-growth.

### V33-FEE-002: Fee Growth Requires Active Weight

If `poolTotalWeight[poolId] == 0`, swaps must not increase pool fee-growth. The effective swap fee is zero, so no Ve33 voter fee should be charged.

### V33-FEE-003: Claim Requires Current Voted Pool

`VE33_CLAIM_POOL_FEES` must revert unless `poolKey.toPoolId() == votedPoolId(owner, stakeId)`. This check is sufficient because voting validates pool keys before setting `votedPoolId`.

### V33-FEE-004: Claim State Changes Only On Nonzero Fees

If a voter fee claim computes `(amount0, amount1) == (0, 0)`, it must not update snapshots, saved balances, or emit `PoolFeesClaimed`.
If either amount is nonzero, the fee-growth snapshot must be updated to current pool fee growth, the pool-fee bucket must decrease by the claimed amounts, and `PoolFeesClaimed` must be emitted.

## Emission Invariants

### V33-EMIT-001: Schedule Times Are Real Valid Times

`VE33_SCHEDULE_EMISSIONS` with nonzero `rewardRate` must require:

- `startTime` and `endTime` are valid schedule times for the current timestamp,
- `realStartTime = max(block.timestamp, startTime)`,
- `endTime > realStartTime`,
- `endTime > block.timestamp`.

The real duration is therefore less than `2**32` seconds.

### V33-EMIT-002: Scheduled Amount Is Rounded Up Q32

For a nonzero schedule:

```text
amount = uint128(((endTime - realStartTime) * rewardRate + type(uint32).max) >> 32)
```

The stake-balance bucket must increase by exactly `amount`, and `EmissionsScheduled` must report the same amount.

### V33-EMIT-003: Rate Deltas Are Bounded Per Time

For each valid schedule time, the absolute sum of scheduled emission-rate deltas must not exceed `VE33_MAX_ABS_VALUE_EMISSION_RATE_DELTA`.
The initialized-time bitmap bit for a time must be set exactly when its stored rate delta is nonzero.

### V33-EMIT-004: Packed Last Accrued Time Recovers Real Time

`Ve33GlobalEmissionState.lastAccrued` stores only `uint32(block.timestamp)`. The real last-accrued time must be recovered as the latest timestamp at or before `block.timestamp` with that same low 32 bits.
All emission loops must use the recovered real time, not the raw `uint32` value.

### V33-EMIT-005: Global Emission Growth Depends On Total Vote Weight

During `accrueEmissions`, for each interval:

```text
amount = uint128((emissionRate * duration) >> 32)
if totalVoteWeight != 0:
  emissionGrowthGlobalX128 += amount * 2**128 / totalVoteWeight
else:
  emissionGrowthGlobalX128 is unchanged
```

If total active vote weight is zero, prepaid emissions remain unassigned and must not be retroactively allocated.

### V33-EMIT-006: Pool Realization Burns When Liquidity Is Zero

When `_maybeAccumulatePoolRewards(poolId, liquidity)` observes new global emission growth, it must advance `poolEmissionGrowthGlobalX128Snapshot[poolId]` even if `poolTotalWeight[poolId] == 0` or `liquidity == 0`.
If pool weight is nonzero and liquidity is zero, the realized pool emission amount is intentionally not added to `rewardsGlobalPerLiquidity`.
The difference between `emissionGrowthGlobalX128` and the pool snapshot is computed with unchecked `uint256` modular arithmetic. A snapshot may numerically exceed the global accumulator after wraparound, and that is valid.

### V33-EMIT-007: Unassigned Emissions Are Not Retroactive

Emission intervals with zero total active vote weight must not increase global emission growth. Those prepaid tokens remain unassigned in the stake-balance bucket and must not be distributed retroactively when votes appear later.

Voting for an uninitialized pool may give that pool active weight for future intervals. If its share is realized before the pool is initialized or before nonzero liquidity exists, that share is economically burned and must not become claimable by later LPs.

## LP Reward Invariants

### V33-LP-001: Position Snapshots Update Before Liquidity Changes

`beforeUpdatePosition` must snapshot rewards before any nonzero liquidity change. If `liquidityDelta == 0`, the hook may no-op.

For nonzero next liquidity, the new snapshot must preserve already-earned rewards under the next liquidity amount. For zero next liquidity, the snapshot must be cleared and any unclaimed rewards are discarded.

### V33-LP-002: Range-Aware Reward Growth

For concentrated pools, position rewards must use Core-style inside growth:

```text
tick < lower:      lowerOutside - upperOutside
lower <= tick < upper: global - lowerOutside - upperOutside
tick >= upper:     upperOutside - lowerOutside
```

For stableswap pools, position rewards use `rewardsGlobalPerLiquidity` directly.

### V33-LP-003: Tick Crossing Inverts Reward Outside

On every forwarded concentrated swap, each initialized tick crossed between the pre-swap and post-swap ticks must update:

```text
tickRewardsOutsidePerLiquidity = rewardsGlobalPerLiquidity - previousTickRewardsOutsidePerLiquidity
```

The set of crossed ticks must match Core's initialized tick traversal for the same direction and `skipAhead`.

### V33-LP-004: Reward Claims Are Backed By Saved Balances

If an LP reward claim amount is zero, it must not emit `RewardsClaimed`.
If nonzero, the position snapshot must advance to current inside growth, the stake-balance bucket must decrease by exactly `uint128(amount)`, and `RewardsClaimed` must be emitted.

### V33-LP-005: Full Exit Discards Unclaimed LP Rewards

If `beforeUpdatePosition` observes `liquidityNext == 0`, it must clear the position reward snapshot. Any unclaimed LP rewards represented only by that snapshot are intentionally discarded unless the caller claimed first, for example through `Ve33Positions.withdrawAndClaimRewards`.

## Burn And Discard Invariants

### V33-BURN-001: Vote Clearing Discards Voter Fees

Clearing, replacing, or resizing an active vote to zero must delete the stake's voted pool, packed vote, and fee-growth snapshots. Any unclaimed voter fees under that vote become unclaimable. This includes expired unstake and moving an entire source stake.

### V33-BURN-002: Nonzero Vote Resizing Preserves Voter Fees

When a stake operation changes an active vote to another nonzero weight, it must preserve fees already accrued under the old weight by adjusting the fee-growth snapshot backward for the new weight. Increasing stake amount, partial moves, and partial splits should not discard voter fees unless the resulting current vote weight is zero.

### V33-BURN-003: Rounding Dust Can Remain Unassigned

Fixed-point divisions in voter fee growth, global emission growth, and reward-per-liquidity accounting may leave dust in Core saved balances. The system must never over-distribute to eliminate dust.

## VeToken Wrapper Invariants

### V33-NFT-001: NFT Id Maps To Stake Salt

For every `VeToken` id:

```text
stakeId(veId) == createStakeId(bytes24(uint192(veId)), uint64(extraData(veId)))
```

`veId > type(uint192).max` must revert before constructing a stake salt.

### V33-NFT-002: Wrapper Stores End Time Only

`VeToken` must not store the stake amount. `stakes(veId).amount` must read `ve33.stakeAmount(address(veToken), stakeId(veId))`, and `stakes(veId).endTime` must read ERC721 extra data.

### V33-NFT-003: Native Stake Token Is Supported

`VeToken` supports the native token (`address(0)`) as the stake token. When `ve33.stakeToken() == address(0)`, staking requires the caller to forward the native token via `msg.value`, and unstaking withdraws native token to the recipient. `VeToken.multicall` is payable to support native-token stake operations in a single transaction.

### V33-NFT-004: Authorization Controls Destructive And Claim Actions

Only the ERC721 owner or approved operator may:

- vote or clear vote,
- claim pool fees,
- increase, extend, split, merge, or withdraw stake.

`claimPoolFees(veId, poolKey, recipient)` may use an authorized caller-selected recipient. `claimPoolFeesToSelf` must use `msg.sender`.

### V33-NFT-005: Token Settlement Stays In Lock

`createStake` and `increaseStakeAmount` must pay stake tokens into Core in the same lock as the forwarded `VE33_STAKE`.
`withdrawStake` must withdraw the unstaked amount to the current NFT owner in the same lock as the forwarded `VE33_UNSTAKE`.
Pool-fee claims must withdraw claimed pool tokens in the same lock as the forwarded `VE33_CLAIM_POOL_FEES`.

### V33-NFT-006: Merge Keeps Destination Identity

`mergeStakes(fromVeId, toVeId)` must move `fromVeId` into `toVeId`, burn `fromVeId`, and must not change `toVeId`'s end time. The caller must choose a destination whose stake id ends after the source stake id unless the move is a no-op.

## Ve33Positions Invariants

### V33-POS-001: Position Id Mapping

For every Ve33 LP NFT id and tick range:

```text
positionId(id, tickLower, tickUpper) == createPositionId(bytes24(uint192(id)), tickLower, tickUpper)
owner in Core == address(ve33Positions)
```

Different NFT ids must map to independent Core position salts for the same pool and tick range.

### V33-POS-002: Only Ve33 Pools Are Managed

Every deposit, withdraw, reward claim, or pool initialization path in `Ve33Positions` must reject `poolKey.config.extension() != address(ve33)` before mutating position state or settling tokens.

### V33-POS-003: NFT Authorization Controls LP Operations

Only the ERC721 owner or approved operator may deposit into, withdraw from, or claim rewards for a Ve33 position NFT.

### V33-POS-004: Deposit Slippage And Overflow

Deposits must revert if computed liquidity is less than `minLiquidity`, if liquidity cannot fit in signed Core update bounds, or if price movement causes actual token amounts to exceed `maxAmount0` or `maxAmount1`.

### V33-POS-005: Withdraw And Claim Can Be Bundled

`withdrawAndClaimRewards` must claim rewards before withdrawing liquidity, settle reward tokens and pool principal to the same recipient, and return all three amounts.

## Observable Event Invariants

### V33-EVT-001: Vote Reconstruction

Indexers can reconstruct active vote weights by taking the last `VoteWeightApplied(owner, stakeId, poolId, ...)` for every tuple. A zero-weight event means the tuple is inactive.

### V33-EVT-002: Current Swap Fee Reconstruction

Indexers can reconstruct the current pool swap fee by taking the latest `VoteWeightApplied` event for a pool and reading its `swapFee` field. Pools with no active vote events or only zero active weights have zero swap fee.

### V33-EVT-003: Saved Balance Delta Events

`PoolFeesAccounted`, `PoolFeesClaimed`, `PoolEmissionsAccrued`, `EmissionsScheduled`, and `RewardsClaimed` must correspond to the saved-balance or per-liquidity state changes described above. Zero-amount claims must not emit claim events.
