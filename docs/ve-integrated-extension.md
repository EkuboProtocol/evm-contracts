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
- ve stake amounts keyed by `(owner, stakeId)`
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

`Ve33Positions` is the ERC721 LP position manager. It owns Core positions for Ve33 LPs, settles liquidity token payments, and forwards LP reward claims to `Ve33`. `Ve33Periphery` owns token settlement for generic Ve33 actions such as global emission schedules. Swaps are settled by the configured router. `Ve33` itself accounts balances only with Core saved balances and does not transfer ERC20s.

For LP positions, `Ve33Positions` derives the Core `PositionId` from `(tokenId, tickLower, tickUpper)` and owns the resulting Core position as the locker contract. ERC721 ownership and approvals authorize deposits, withdrawals, and reward claims. This keeps LP position ownership explicit without inheriting the standard `BasePositions` swap-fee collection assumptions.

The stake owner in `Ve33` is the locker that forwarded the stake operation. For `VeToken` stakes this is `address(veToken)`, not the user. The user is tracked by `VeToken`, and `VeToken` authorizes wrapper operations before calling into `Ve33`.

Because the canonical stake state is independent of the wrapper, the same design can support other representations of staked tokens, including a fungible ERC20 representation. This branch includes the transferable `VeToken` ERC721 wrapper, `Ve33Positions` LP NFT manager, and `Ve33Periphery` settlement helper.

## Pool Requirements

Pools using this extension must set the Core pool-config fee to `0`. The active swap fee is stored in extension state and selected by ve voters.

The extension enables these Core call points:

- `beforeInitializePool`
- `afterInitializePool`
- `beforeSwap`
- `beforeUpdatePosition`

Pool initialization validates `poolKey.config.fee() == 0` and concentrated power-of-4 tick spacing in `beforeInitializePool`. With Core's current max tick spacing, the power-of-4 rule allows 10 concentrated pools per pair: `1`, `4`, `16`, `64`, `256`, `1024`, `4096`, `16384`, `65536`, and `262144`. This reduces near-duplicate pool fragmentation and preserves the gas benefits of binary-aligned spacing.

Direct Core swaps are rejected in `beforeSwap`. Swaps must be made through `Core.forward` to the extension with `VE33_SWAP`.

Pool-key validation is only repeated where the call receives untrusted input and the operation would not otherwise fail safely before mutating Ve33 state. `vote`, forwarded swaps, public reward accumulation, and forwarded LP reward claims validate Ve33 pool configuration. Pool-fee claims instead require `poolKey.toPoolId()` to match the stake's current voted pool, which was validated when the vote was set. Trusted Core hooks for initialized pools, such as `afterInitializePool` and `beforeUpdatePosition`, rely on Core dispatch and do not re-run full pool-key validation.

## Stake Accounting

Stakes are stored in:

```text
stakeAmounts[owner][stakeId]
```

`StakeId` is a packed custom type:

```text
bytes24 salt || uint64 endTime
```

For `VeToken`, `salt = bytes24(uint192(veId))`. The current stake amount is fetched from `Ve33Lib.stakeAmount(ve33, address(veToken), stakeId)` whenever the wrapper needs it, so the NFT does not store the amount. The stake end timestamp is stored in Solady ERC721 `extraData`, which is large enough for the `uint64` end time.

All stake-token backing is saved under a single Core saved-balance salt:

```text
VE33_STAKE_TOKEN_SAVED_BALANCE_ID
```

Forward stake call types:

- `VE33_STAKE`: increases `stakeAmounts[originalLocker][stakeId]`
- `VE33_UNSTAKE`: removes an entire expired stake key and returns the unstaked amount

`Ve33` updates Core saved balances for staked tokens under `address(ve33)` and the aggregate stake-token salt:

```text
CORE.updateSavedBalances(stakeToken, address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID, delta, 0)
```

It does not transfer stake tokens for these stake operations. The calling representation handles token settlement: `VeToken` pays the stake token into Core after staking, and withdraws expired stake to the current ERC721 owner after unstaking. Approved ERC721 operators can manage a represented stake, and pool-fee claims can be sent to an authorized caller-selected recipient. Extending and merging call `Ve33.moveStake` directly, which moves stake accounting between stake ids without touching Core saved balances. `moveStake` requires the destination stake id to end after the source stake id, resizes the source vote to the source's remaining voting power, and resizes any existing destination vote to the destination's new voting power. Splitting calls `Ve33.splitStake` directly, which keeps the source stake voted and resizes the source vote weight to the reduced current voting power; the newly split `VeToken` stake starts unvoted.

## Voting

`Ve33.vote` assigns one stake id's full current voting power to one pool and accepts an explicit `uint64` swap fee. Fees are 0.64 fixed point, so `1 << 64` is 100%. The optional `VeToken` wrapper exposes `vote(veId, poolKey, swapFee)`, `clearVote(veId)`, `splitStake(veId, amount)`, and `mergeStakes(fromVeId, toVeId)`.

Each pool tracks active vote weight, voter fee growth, a snapshot of global emission growth, and the weighted fee sum. When votes change, the pool fee is computed as `feeWeightSum / weight`; integer division rounds down. With no active votes, this EVM `div` returns zero, so the pool has no extension swap fee.

Voting power is sampled when `vote` is called or when the stake owner changes stake accounting through owner-authorized
stake operations:

```text
stakeAmount * (endTime - block.timestamp) / VE33_MAX_STAKE_DURATION
```

That current power is written into the pool's total weight slot and the stake's packed `VePoolVote` record for the selected pool, together with the voted fee and last vote-accounting timestamp. Stored pool weights do not continuously decay on their own. They change when the stake votes again or when a stake operation updates or clears the vote. Emission allocation uses these stored active weights when global emission growth accrues.

Increasing stake amount resizes any existing vote to the stake's new current voting power. Withdrawing an expired stake clears the affected vote before removing the amount. Extending and merging move stake accounting to the caller-selected destination stake id, which must end after the source stake id, and resize or clear affected votes as part of the owner-authorized operation. Splitting preserves the source vote with reduced current voting power and leaves the new stake id unvoted. Multi-pool allocation is represented by multiple stake ids: `VeToken.splitStake` can split one NFT into another NFT with the same end time while preserving the source vote, and `VeToken.mergeStakes(fromVeId, toVeId)` moves `fromVeId` into `toVeId` without changing `toVeId`'s end time.

There is no external permissionless stale-vote poke. If a stake owner wants to keep voter fees that would otherwise be discarded, it should claim those pool fees through the lock/forward path before voting for a new pool, clearing a vote, or running a stake operation that clears the active vote. Nonzero vote-weight resizing preserves fees already accrued under the previous weight. This keeps token settlement in the wrapper/periphery layer because fee claims require the pool tokens from `PoolKey`.

`vote` is not a forwarded action because it does not require token settlement. It must be called by the `Ve33` stake owner for the `StakeId`; for the ERC721 wrapper that means `VeToken` authorizes the user or approved operator, then calls `Ve33.vote` as the stake owner.

## Forwarded Swap Accounting

The forwarded swap handler uses the supplied `SwapParameters` as-is. Routers and callers are responsible for setting default sqrt-ratio limits before forwarding.

The extension accounts voter fees in the unspecified token. For exact-input swaps, the fee is taken from the output token. For exact-output swaps, the fee is taken from the input token. The nonzero fee is added to the returned balance delta, saved under the extension and shared pool-fee salt for the token pair, and accounted to voter fee growth.

Swap fees are stored with:

```text
CORE.updateSavedBalances(token0, token1, VE33_POOL_FEES_SAVED_BALANCE_ID, fee0, fee1)
```

The extension does not call `CORE.accumulateAsFees`, so LPs do not earn Core swap fees. Only fees accounted while a pool has nonzero active vote weight increase voter fee growth. With no active vote weight, the extension swap fee is zero.

## Voter Fee Claims

Voter fees use fee-growth accounting over each pool's active vote weight. Each stake snapshots `feeGrowth0X128Snapshot` and `feeGrowth1X128Snapshot` for its current voted pool. On nonzero weight changes, `Ve33` uses the Core snapshot-adjustment trick: it computes fees accumulated under the old weight, sets the new weight, then moves the fee-growth snapshots backward so the already accumulated amount remains claimable under the next weight. If a stake's pool vote weight is cleared to zero, pending unclaimed voter fees for that pool position are discarded.

`VE33_CLAIM_POOL_FEES` is a forwarded action. It subtracts the claimed amount from the extension's saved balance and returns the claimed token amounts to the forwarding locker.

For wrapper-owned stakes, the `Ve33` stake owner is `address(veToken)`. `VeToken.claimPoolFees(veId, poolKey, recipient)` enters a Core lock, forwards the claim to `Ve33`, and withdraws token0/token1 directly to the authorized caller-selected recipient. `claimPoolFeesToSelf` uses `msg.sender` as the recipient.

## LP Reward Token

LPs earn only the immutable reward token, which is the same token used for ve stakes. LP rewards come from global emissions directed by active votes and are independent of Core swap fees. Reward accounting uses reward-per-liquidity accumulators:

- `rewardsGlobalPerLiquidity`
- `tickRewardsOutsidePerLiquidity`
- `positionRewardsSnapshotPerLiquidity`

`maybeAccumulateRewards` first accrues the global emission stream, realizes the pool's vote-weighted share since its last snapshot, and advances `rewardsGlobalPerLiquidity` using current Core pool liquidity. If liquidity is zero, including before a voted pool is initialized or before liquidity is added, realized emissions are not assigned to LPs because `rewardsGlobalPerLiquidity` is not increased. Those emissions are intentionally burned rather than blocked by pool-existence checks.

`beforeUpdatePosition` snapshots position rewards before liquidity changes. It uses the same snapshot adjustment trick as Core: rewards earned before the update are preserved by moving `positionRewardsSnapshotPerLiquidity` based on the next liquidity value. If the position fully exits, the snapshot is cleared and unclaimed rewards are discarded.

Reward accounting is range-aware. The extension tracks `tickRewardsOutsidePerLiquidity` for initialized ticks and uses it to compute reward growth inside a position's tick range:

```text
below range:  lowerOutside - upperOutside
in range:     rewardsGlobalPerLiquidity - lowerOutside - upperOutside
above range:  upperOutside - lowerOutside
```

Forwarded swaps explicitly invert reward-outside snapshots for crossed concentrated ticks. Stableswap positions use the pool's global reward growth directly, so stableswap liquidity can keep earning emissions when the current tick is outside the stableswap active-liquidity range.

`VE33_CLAIM_REWARDS` accumulates the pool, computes the position's reward amount from the difference between current position reward growth and `positionRewardsSnapshotPerLiquidity`, updates the snapshot to current reward growth, subtracts the claimed amount from the LP-reward saved-balance bucket, and returns the amount to the forwarding locker for withdrawal by `Ve33Positions`.

## Emissions

`VE33_SCHEDULE_EMISSIONS` is a forwarded action that saves funded `stakeToken` in Core and schedules a global Q32 emission rate between caller-selected valid times. The call is permissionless. Governance, a PID controller, or any other external policy component can decide when and how much to schedule, but `Ve33` does not query or privilege that policy component.

Scheduling first accrues the existing global emission stream, computes the token amount required for `rewardRate * duration`, saves that amount in the LP-reward saved-balance bucket, and records emission-rate deltas in `emissionRateDeltaAtTime`. Start and end times are tracked in a bitmap, so multiple schedules can share the same valid time without storing an append-only list.

Global emissions are accounted with:

```text
emissionGrowthGlobalX128 += emittedAmount / total active vote weight
```

If total active vote weight is zero for an interval, that interval does not increase global emission growth and no LP can claim that interval. The prepaid tokens remain in the LP-reward saved-balance bucket as unassigned backing; they are not retroactively distributed when votes appear later.

Each pool stores `emissionGrowthGlobalX128Snapshot`. When the pool is touched through a swap, position update, reward claim, vote update, clear, or stake change, `Ve33` accrues global emissions and computes:

```text
poolEmissionAmount =
  (emissionGrowthGlobalX128 - poolSnapshot) * pool active vote weight
```

That amount immediately increases `rewardsGlobalPerLiquidity` when the pool has current Core liquidity. There is no separate trigger call and no keeper-chosen pool distribution step. A newly voted pool snapshots current global emission growth before its weight is added, so it starts earning from the new vote timestamp rather than receiving past emissions. If the pool is not initialized yet or has no liquidity when its emission share is realized, the realized amount is economically burned.

Global emission growth and pool snapshots use unchecked `uint256` modular arithmetic, like Core fee-growth accumulators. A snapshot can be numerically greater than the current global accumulator after wraparound; only the modular difference is meaningful.

## Known Burn And Discard Cases

The extension intentionally favors simple, local accounting over retroactive reassignment. These cases can leave tokens or accounting dust unclaimable:

- Replacing or clearing a vote discards unclaimed voter fees under the previous vote.
- Withdrawing an expired stake clears its vote and discards pending voter fees if they were not claimed first.
- Moving an entire stake clears the source stake's vote and discards source-stake voter fees if they were not claimed first; bundled claim-and-merge helpers preserve those fees.
- Fully withdrawing an LP position without first claiming rewards clears the reward snapshot and discards unclaimed LP rewards; `Ve33Positions.withdrawAndClaimRewards` avoids this.
- Voting for an uninitialized pool can direct future emissions to that pool, but any pool emission share realized before initialization or before nonzero liquidity exists is not assigned to later LPs.
- Emission intervals with zero total active vote weight do not increase global emission growth, and fixed-point divisions can leave rounding dust in saved balances. These amounts are not retroactively redistributed.

## Settlement Model

The extension relies on Core saved balances for deferred accounting:

- swap fees are saved under `address(ve33)` and shared token-pair salt `VE33_POOL_FEES_SAVED_BALANCE_ID`
- staked balances, LP rewards, and scheduled emissions are saved under `address(ve33)` and aggregate stake-token salt `VE33_STAKE_TOKEN_SAVED_BALANCE_ID`

`Ve33` accounts for staking, unstaking, moving stake balances, emission funding, reward claiming, and fee claiming, but does not directly transfer tokens. Callers that integrate directly with token-moving forwarded actions must settle the corresponding payment or withdrawal in the same Core lock. `VeToken` is the reference implementation for stake-owned fee claims and stake-token settlement, `Ve33Positions` is the reference implementation for LP position and reward-claim settlement, and `Ve33Periphery` is the reference implementation for generic emission token settlement.

## Deployment

`script/DeployVe33.s.sol` deploys `Ve33`, `VeToken`, `Ve33Positions`, and `Ve33Periphery` with deterministic CREATE2 deployment. It requires `CORE_ADDRESS` and `STAKE_TOKEN`, and accepts optional expected-address environment variables for deployment verification. `script/DeployRouter.s.sol` deploys the router separately so chains without Ve33 do not need a Ve33 address. See the user guide for the operator-facing commands.
