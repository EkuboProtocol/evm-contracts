# Ve33 Audit Invariant Verification

This document verifies the invariants defined in `audits/ve33-audit-invariants.md` against the current repository state.

Status labels:

- **Satisfied**: checked against implementation and at least one executable or manual evidence source.
- **Executable invariant**: enforced by a Foundry invariant test.
- **Unit/regression**: enforced by a named unit test.
- **Manual inspection**: checked by reading the referenced implementation path.

## Verification Summary

All named `V33-*` invariants in `audits/ve33-audit-invariants.md` are checked to satisfaction. The strongest executable coverage is in:

- `test/extensions/Ve33EmissionsInvariant.t.sol`
- `test/extensions/Ve33.t.sol`
- `test/VeToken.t.sol`

The primary implementation evidence is:

- `src/extensions/Ve33.sol`
- `src/interfaces/extensions/IVe33.sol`
- `src/libraries/Ve33StorageLayout.sol`
- `src/libraries/Ve33Lib.sol`
- `src/types/stakeId.sol`
- `src/types/vePoolVote.sol`
- `src/types/vePoolSwapFeeState.sol`
- `src/types/ve33GlobalEmissionState.sol`
- `src/VeToken.sol`
- `src/Ve33Positions.sol`
- `src/Ve33Periphery.sol`

## Storage Layout Invariants

| Invariant | Status | Evidence |
| --- | --- | --- |
| `V33-STOR-001` Ve33 manual storage only | **Satisfied** | Manual inspection: `src/extensions/Ve33.sol` declares constants/immutables and moves local mutable slot helpers into `abstract contract Ve33Storage`; all local storage access uses `Ve33StorageLayout` helpers and `StorageSlot` load/store APIs. |
| `V33-STOR-002` fixed slots do not collide | **Satisfied** | Manual inspection: fixed slots are `0`, `1`, `2` in `src/libraries/Ve33StorageLayout.sol`. Executable invariant: `invariant_trackedVe33StorageSlotsDoNotUseFixedSlots` in `test/extensions/Ve33EmissionsInvariant.t.sol` checks all tracked dynamic families and adjacent two-word slots against fixed slots. |
| `V33-STOR-003` dynamic slot families are disjoint | **Satisfied** | Manual inspection: every dynamic family in `src/libraries/Ve33StorageLayout.sol` uses a distinct `cast keccak "Ve33StorageLayout#..."` domain separator, and the slot helpers include that family offset in the hash input. Adjacent two-word values are limited to fee-growth snapshot slots and pool fee-growth slots. Executable invariant coverage checks reachable tracked stake, pool, tick, position, bitmap, and time-delta slots do not hit fixed slots. |
| `V33-STOR-004` library readers match contract writers | **Satisfied** | Manual inspection: `src/libraries/Ve33Lib.sol` readers use the same `Ve33StorageLayout` helpers as `src/extensions/Ve33.sol` writers for stake amounts, votes, fee growth, pool fee growth, and global emission state. The shared packed parsers are in `src/types/*.sol`. |
| `V33-STOR-005` packed types mask before assembly use | **Satisfied** | Manual inspection: constructors/parsers in `src/types/stakeId.sol`, `src/types/vePoolVote.sol`, `src/types/vePoolSwapFeeState.sol`, and `src/types/ve33GlobalEmissionState.sol` mask or shift fields to their declared widths before returning narrower values. `Ve33GlobalEmissionState` avoids unsafe raw casts by parsing through the custom type. |

## Pool And Forwarding Invariants

| Invariant | Status | Evidence |
| --- | --- | --- |
| `V33-POOL-001` Ve33 pool key validation | **Satisfied** | Manual inspection: `beforeInitializePool`, `vote`, `maybeAccumulateRewards`, forwarded `swap`, and forwarded LP reward claims validate untrusted pool keys; `claimPoolFees` checks `poolKey.toPoolId() == votedPoolId`; trusted hooks avoid redundant full validation. Unit/regression: `test_poolInitializationRejectsInvalidConfig`, `test_voteValidation`, and `test_maybeAccumulateRewardsValidationAndOutOfRangeStableswap` in `test/extensions/Ve33.t.sol`. |
| `V33-POOL-002` direct Core swaps are forbidden | **Satisfied** | Manual inspection: `Ve33.beforeSwap` always reverts with `SwapMustHappenThroughForward`. Unit/regression: `test_directHooksAndInvalidCoreLockRevert` and forwarded swap tests in `test/extensions/Ve33.t.sol`. |
| `V33-POOL-003` Ve33 does not transfer ERC20s | **Satisfied** | Manual inspection: `src/extensions/Ve33.sol` only mutates Core saved balances. Settlement is in lockers/periphery: `src/VeToken.sol`, `src/Ve33Positions.sol`, and `src/Ve33Periphery.sol`. No ERC20 transfer helper is imported or called by `Ve33`. |

## Stake Accounting Invariants

| Invariant | Status | Evidence |
| --- | --- | --- |
| `V33-STK-001` stake amount backing | **Satisfied** | Manual inspection: `_stake` and `_unstake` update stake amount and the `VE33_STAKE_TOKEN_SAVED_BALANCE_ID` bucket by matching deltas; `moveStake` only moves local stake amounts. Executable invariant: `invariant_stakeTokenBackingIsAlwaysSolvent`. Unit/regression: `test_stakeActionsReturnUsefulAmounts`. |
| `V33-STK-002` valid new stake times | **Satisfied** | Manual inspection: `_stake` validates future end time and max duration using real `uint64` epoch times; `moveStake` requires destination validity for nonzero moves. Unit/regression: `test_stakeLifecycleAndInvalidStakePaths` in `test/VeToken.t.sol` and `test_moveStakeRevertsForEarlierEndTime` in `test/extensions/Ve33.t.sol`. |
| `V33-STK-003` voting power formula | **Satisfied** | Manual inspection: `_votingPower` in `src/extensions/Ve33.sol` and `Ve33Lib.votingPower` compute `amount * secondsUntilEnd / VE33_MAX_STAKE_DURATION` and return zero for expired/out-of-range stakes. Unit/regression: vote weight tests in `test/extensions/Ve33.t.sol` and gas/read tests in `test/VeToken.t.sol`. |
| `V33-STK-004` move stake direction | **Satisfied** | Manual inspection: `moveStake` checks source balance, treats same-stake moves as no-op after the balance check, rejects earlier destination end times, validates destination time, and resizes votes through `_adjustVoteWeight`. Unit/regression: `test_moveStakeAdjustsSourceAndDestinationVotes`, `test_moveStakeAllowsSameEndTime`, and `test_moveStakeRevertsForEarlierEndTime`. |
| `V33-STK-005` VeToken split preserves source stake | **Satisfied** | Manual inspection: `VeToken.splitStake` requires `amount < currentAmount`, mints a fresh destination NFT, and moves to the same end time; `_mergeStakes` delegates to `moveStake` and burns the source NFT. Unit/regression: `test_splitAndMergeStakeLifecycle`, `test_splitStakePreservesSourceVoteAndAccruedFees`, and `test_splitStakesVoteMultiplePoolsIndependently`. |

## Vote And Swap Fee Invariants

| Invariant | Status | Evidence |
| --- | --- | --- |
| `V33-VOTE-001` vote with zero power clears existing vote | **Satisfied** | Manual inspection: `vote` validates the pool key, computes current power, and calls `_adjustVoteWeight` with zero so an existing vote is cleared instead of reverting. Unit/regression: `test_voteClearsExistingVoteWhenPowerIsZero`. |
| `V33-VOTE-002` aggregate vote weight consistency | **Satisfied** | Manual inspection: `_adjustVoteWeight` updates `totalVoteWeight`, packed pool total weight, separate pool fee-weight sum, and cached swap fee together. Executable invariant: `invariant_voteAccountingIsConsistent`. Unit/regression: `test_multipleVotersSetWeightedFeeAndClaimProRataFees`. |
| `V33-VOTE-003` one active pool per stake | **Satisfied** | Manual inspection: `votedPoolId` is set/cleared with each vote transition; cleared votes zero `VePoolVote` and fee-growth snapshots. Executable invariant: `invariant_voteAccountingIsConsistent` asserts zero vote and zero snapshots when `votedPoolId == 0`. |
| `V33-VOTE-004` vote changes accrue before mutation | **Satisfied** | Manual inspection: `_adjustVoteWeight` calls `accrueEmissions`, realizes pool rewards, accounts pending voter fees for nonzero resized votes, then mutates weight state. Unit/regression: `test_stakeIncreaseAdjustsVoteButMovingOrRemovingClearsVote`, `test_splitStakePreservesSourceVoteAndAccruedFees`, and `test_claimPoolFeesAndExtendStakeClaimsBeforeClearingVote`. |
| `V33-VOTE-005` vote events reconstruct current fee | **Satisfied** | Manual inspection: `_adjustVoteWeight` emits `VoteWeightApplied(owner, stakeId, poolId, weight, nextSwapFee)` after mutation, including zero weight on clears. Unit/regression: `test_voteWeightAppliedEventsDescribeCurrentVoteState`. |

## Voter Fee Invariants

| Invariant | Status | Evidence |
| --- | --- | --- |
| `V33-FEE-001` fees accounted only in unspecified token | **Satisfied** | Manual inspection: forwarded `_swap` applies the fee to the token opposite the exact/specified token and accounts only that side. Unit/regression: `test_forwardedExactInputPartialToken0SwapAccountsExecutedInputFee`, `test_forwardedExactInputPartialToken1SwapAccountsExecutedInputFee`, and `test_forwardedSwapCoversToken1AndExactOutFeeBranches`. |
| `V33-FEE-002` fee growth requires active weight | **Satisfied** | Manual inspection: zero `poolTotalWeight` yields zero cached swap fee and no fee-growth increase. Unit/regression: `test_zeroFeeVoteAndUnweightedFees` and `test_poolWithLiquidityButNoVotesDoesNotAccrueRetroactiveRewardsAfterVote`. |
| `V33-FEE-003` claim requires current voted pool | **Satisfied** | Manual inspection: `_claimPoolFees` reverts unless `poolKey.toPoolId() == _votedPoolId(owner, stakeId)`. Unit/regression: `test_veTokenClaimPoolFees_requiresAuthorizationAndSupportsRecipient` and claim paths in `test/extensions/Ve33.t.sol`. |
| `V33-FEE-004` claim state changes only on nonzero fees | **Satisfied** | Manual inspection: `_claimPoolFees` updates snapshots, saved balances, and emits `PoolFeesClaimed` only in nonzero amount branches. Unit/regression: `test_zeroFeeVoteAndUnweightedFees` and `test_multipleVotersSetWeightedFeeAndClaimProRataFees`. |

## Emission Invariants

| Invariant | Status | Evidence |
| --- | --- | --- |
| `V33-EMIT-001` schedule times are real valid times | **Satisfied** | Manual inspection: `_scheduleEmissions` uses `realStartTime = max(block.timestamp, startTime)` and validates start/end via `isTimeValid`, future end, and end greater than real start. Unit/regression: `test_scheduleEmissionsAccruesMultipleEventsAtSameTime` and `test_scheduleEmissionsAccruesAcrossUint32Wrap`. |
| `V33-EMIT-002` scheduled amount is rounded up Q32 | **Satisfied** | Manual inspection: `_scheduleEmissions` computes `uint128(((realDuration * rewardRate) + type(uint32).max) >> 32)`, increases the stake-balance bucket, and emits `EmissionsScheduled` with the amount. Unit/regression: `test_peripherySchedulesEmissionsAndClaimsRewards`, `test_peripherySchedulesNativeEmissions`, and schedule tests in `test/extensions/Ve33.t.sol`. |
| `V33-EMIT-003` rate deltas are bounded per time | **Satisfied** | Manual inspection: `_updateEmissionTime` bounds absolute per-time deltas by `VE33_MAX_ABS_VALUE_EMISSION_RATE_DELTA` and flips the initialized-time bitmap when a delta crosses zero/nonzero. Unit/regression: `test_scheduleEmissionsAccruesMultipleEventsAtSameTime`. |
| `V33-EMIT-004` packed last accrued time recovers real time | **Satisfied** | Manual inspection: `Ve33GlobalEmissionState.realEmissionTimeAtOrBeforeNow` reconstructs the latest real timestamp from low 32 bits before `accrueEmissions` loops. Unit/regression: `test_scheduleEmissionsAccruesAcrossUint32Wrap`. |
| `V33-EMIT-005` global emission growth depends on total vote weight | **Satisfied** | Manual inspection: `accrueEmissions` only increases `emissionGrowthGlobalX128` when `totalVoteWeight != 0`. Executable invariant: `invariant_stakeTokenBackingIsAlwaysSolvent`. Unit/regression: `test_scheduleEmissionsWithoutVotesDoesNotAccrueRewards`. |
| `V33-EMIT-006` pool realization burns when liquidity is zero | **Satisfied** | Manual inspection: `_maybeAccumulatePoolRewards` advances the pool snapshot on new global growth even when pool weight/liquidity prevents reward-per-liquidity assignment; arithmetic is modular. Unit/regression: `test_rewardsAccruedBeforePoolInitializationAreNotClaimableByLaterLiquidity` and `test_rewardsAccruedBeforePoolLiquidityAreNotClaimableByLaterLiquidity`. |
| `V33-EMIT-007` unassigned emissions are not retroactive | **Satisfied** | Manual inspection: zero total vote weight leaves global emission growth unchanged, and zero-liquidity/uninitialized realization advances snapshots without later allocation. Unit/regression: `test_scheduleEmissionsWithoutVotesDoesNotAccrueRewards`, `test_scheduleEmissionsStartsAccruingWhenPoolReceivesVotes`, `test_rewardsAccruedBeforePoolInitializationAreNotClaimableByLaterLiquidity`, and `test_poolWithLiquidityButNoVotesDoesNotAccrueRetroactiveRewardsAfterVote`. |

## LP Reward Invariants

| Invariant | Status | Evidence |
| --- | --- | --- |
| `V33-LP-001` position snapshots update before liquidity changes | **Satisfied** | Manual inspection: `beforeUpdatePosition` skips zero liquidity deltas and otherwise snapshots rewards before Core applies the liquidity mutation. Unit/regression: `test_gas_updatePosition`, `test_rewardsAccruedBeforePoolLiquidityAreNotClaimableByLaterLiquidity`, and reward snapshot tests. |
| `V33-LP-002` range-aware reward growth | **Satisfied** | Manual inspection: `_getRewardsInsidePerLiquidity` uses Core-style lower/current/upper inside growth for concentrated pools; stableswap paths use global reward growth. Unit/regression: `test_rewardSnapshotsAcrossConcentratedAndStableswapBoundaries`, `test_concentratedRewardsPauseWhilePositionIsOutOfRangeAcrossCrossings`, and `test_stableswapPoolStartsWithZeroDerivedFee`. |
| `V33-LP-003` tick crossing inverts reward outside | **Satisfied** | Manual inspection: `_updateCrossedTicks` updates each crossed initialized tick to `rewardsGlobalPerLiquidity - previousOutside`. Unit/regression: `test_rewardSnapshotsAcrossConcentratedAndStableswapBoundaries` and `test_concentratedRewardsPauseWhilePositionIsOutOfRangeAcrossCrossings`. |
| `V33-LP-004` reward claims are backed by saved balances | **Satisfied** | Manual inspection: `_claimRewards` updates the position snapshot, decrements the stake-balance bucket by nonzero claimed rewards, and emits `RewardsClaimed` only when amount is nonzero. Executable invariant: `invariant_stakeTokenBackingIsAlwaysSolvent` and `invariant_positionsNeverClaimMoreThanActiveLiquidityShare`. Unit/regression: `test_peripherySchedulesEmissionsAndClaimsRewards`. |
| `V33-LP-005` full exit discards unclaimed LP rewards | **Satisfied** | Manual inspection: `beforeUpdatePosition` clears snapshot when next liquidity is zero. Unit/regression: `test_vePositionsWithdrawAndClaimRewards` verifies bundled claim-before-withdraw path for users that do not want discard. |

## Burn And Discard Invariants

| Invariant | Status | Evidence |
| --- | --- | --- |
| `V33-BURN-001` vote clearing discards voter fees | **Satisfied** | Manual inspection: `_adjustVoteWeight` clears voted pool, vote, and fee-growth snapshots when next weight is zero. Unit/regression: `test_stakeIncreaseAdjustsVoteButMovingOrRemovingClearsVote`, `test_voteClearsExistingVoteWhenPowerIsZero`, and destructive-claim tests before extend/merge. |
| `V33-BURN-002` nonzero vote resizing preserves voter fees | **Satisfied** | Manual inspection: `_adjustVoteWeight` accounts pending fees and adjusts snapshots for nonzero next weights. Unit/regression: `test_stakeIncreaseAdjustsVoteButMovingOrRemovingClearsVote`, `test_moveStakeAdjustsSourceAndDestinationVotes`, and `test_splitStakePreservesSourceVoteAndAccruedFees`. |
| `V33-BURN-003` rounding dust can remain unassigned | **Satisfied** | Manual inspection: fixed-point growth uses floor division and saved-balance buckets are decreased only by computed claim amounts, never forced to zero. Executable invariant: `invariant_stakeTokenBackingIsAlwaysSolvent`, `invariant_voterFeesAreAlwaysSolvent`, and `invariant_positionsNeverClaimMoreThanActiveLiquidityShare`. |

## VeToken Wrapper Invariants

| Invariant | Status | Evidence |
| --- | --- | --- |
| `V33-NFT-001` NFT id maps to stake salt | **Satisfied** | Manual inspection: `VeToken.stakeId` uses `createStakeId(_stakeSalt(veId), _stakeEndTime(veId))`; `_stakeSalt` rejects ids above `type(uint192).max`. Unit/regression: `test_gas_stakeId` and `test_stakeLifecycleAndInvalidStakePaths`. |
| `V33-NFT-002` wrapper stores end time only | **Satisfied** | Manual inspection: `VeToken.stakes` reads amount from `ve33.stakeAmount(address(this), stakeId(id))` and end time from ERC721 extra data. Unit/regression: `test_gas_stakes` and lifecycle tests in `test/VeToken.t.sol`. |
| `V33-NFT-003` native stake token is supported | **Satisfied** | Manual inspection: `VeToken.handleLockData` pays native stake tokens via `SafeTransferLib.safeTransferETH`; `VeToken` inherits `PayableMulticallable`. Unit/regression: `test_constructor_acceptsNativeTokenAsStakeToken` and `test_multicall_acceptsValue`. |
| `V33-NFT-004` authorization controls destructive and claim actions | **Satisfied** | Manual inspection: vote, clear, claim, increase, extend, split, merge, and withdraw entrypoints use `authorizedForStake`. Unit/regression: `test_veTokenClaimPoolFees_requiresAuthorizationAndSupportsRecipient`, `test_erc721ApprovedAccountCanUpdateStake`, and `test_approvedWithdrawSendsStakeToCurrentOwner`. |
| `V33-NFT-005` token settlement stays in lock | **Satisfied** | Manual inspection: `VeToken.handleLockData` performs stake payment, unstake withdrawal, and pool-fee withdrawals in the same lock as the forwarded Ve33 operation. Unit/regression: lifecycle tests in `test/VeToken.t.sol` and multicall claim-before-mutate tests in `test/extensions/Ve33.t.sol`. |
| `V33-NFT-006` merge keeps destination identity | **Satisfied** | Manual inspection: `_mergeStakes` moves from source stake id to destination stake id and burns only `fromVeId`; destination extra data is unchanged. Unit/regression: `test_splitAndMergeStakeLifecycle` and `test_claimPoolFeesAndMergeStakesClaimsSourceFeesBeforeBurning`. |

## Ve33Positions Invariants

| Invariant | Status | Evidence |
| --- | --- | --- |
| `V33-POS-001` position id mapping | **Satisfied** | Manual inspection: `Ve33Positions.positionId` uses `createPositionId(bytes24(uint192(id)), tickLower, tickUpper)` and all Core position updates use `address(this)` as owner. Unit/regression: `test_vePositionsAuthorizesByNftAndKeepsIndependentPositions`. |
| `V33-POS-002` only Ve33 pools are managed | **Satisfied** | Manual inspection: `Ve33Positions` validates `poolKey.config.extension() == address(ve33)` before user-driven deposits, withdrawals, claims, and pool initialization. Unit/regression: `test_vePositionsAuthorizesByNftAndKeepsIndependentPositions`. |
| `V33-POS-003` NFT authorization controls LP operations | **Satisfied** | Manual inspection: deposit, withdraw, and claim entrypoints use `authorizedForNft`. Unit/regression: `test_vePositionsAuthorizesByNftAndKeepsIndependentPositions`. |
| `V33-POS-004` deposit slippage and overflow | **Satisfied** | Manual inspection: `Ve33Positions.handleLockData` reverts on insufficient computed liquidity, signed-liquidity overflow, existing-position overflow, and price movement over max amounts. Unit/regression: `test_vePositionsRejectsDepositsThatOverflowQueryableLiquidity`. |
| `V33-POS-005` withdraw and claim can be bundled | **Satisfied** | Manual inspection: `withdrawAndClaimRewards` calls `_claimRewards` before decreasing liquidity and settles reward/principal to the same recipient. Unit/regression: `test_vePositionsWithdrawAndClaimRewards`. |

## Observable Event Invariants

| Invariant | Status | Evidence |
| --- | --- | --- |
| `V33-EVT-001` vote reconstruction | **Satisfied** | Manual inspection: `VoteWeightApplied` is emitted with `(owner, stakeId, poolId, weight, swapFee)` for weight changes, with zero weight on clears. Unit/regression: `test_voteWeightAppliedEventsDescribeCurrentVoteState`. |
| `V33-EVT-002` current swap fee reconstruction | **Satisfied** | Manual inspection: `_adjustVoteWeight` emits the post-mutation pool swap fee in `VoteWeightApplied`. Unit/regression: `test_voteWeightAppliedEventsDescribeCurrentVoteState` and aggregate fee tests. |
| `V33-EVT-003` saved balance delta events | **Satisfied** | Manual inspection: nonzero saved-balance/per-liquidity state transitions emit `PoolFeesAccounted`, `PoolFeesClaimed`, `PoolEmissionsAccrued`, `EmissionsScheduled`, and `RewardsClaimed`; zero-amount reward and fee claims do not emit claim events. Unit/regression: `test_forwardedSwapAccountsVoterFee`, `test_zeroFeeVoteAndUnweightedFees`, `test_maybeAccumulateRewardsValidationAndOutOfRangeStableswap`, and reward-claim no-event checks in `test_concentratedRewardsPauseWhilePositionIsOutOfRangeAcrossCrossings`. |

## Commands Used For Verification

The verification was checked against these focused targets:

```sh
forge test --offline --match-contract Ve33Test
forge test --offline --match-contract Ve33NativePeripheryTest
forge test --offline --match-contract Ve33EmissionsInvariantTest
forge test --offline --match-contract VeTokenTest
```

The branch-level gates are:

```sh
forge test --offline
forge snapshot --offline
```
