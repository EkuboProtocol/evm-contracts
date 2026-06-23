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

`Ve33Positions` is the ERC721 LP position manager. It owns Core positions for Ve33 LPs, settles liquidity token payments, and forwards LP reward claims to `Ve33`. `Ve33Periphery` owns token settlement for generic Ve33 actions such as reward donations, explicit reward schedules, and global emission schedules. Swaps are settled by the configured router. `Ve33` itself accounts balances only with Core saved balances and does not transfer ERC20s.

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

The saved-balance id for staked tokens is:

```text
keccak256(abi.encodePacked(owner, StakeId.unwrap(stakeId)))
```

Forward stake call types:

- `VE33_STAKE`: increases `stakeAmounts[originalLocker][stakeId]`
- `VE33_UNSTAKE`: removes an entire expired stake key and returns the unstaked amount
- `VE33_MOVE_STAKE`: moves amount from one `stakeId` to another

`Ve33` updates Core saved balances for staked tokens under `address(ve33)` and the stake id:

```text
CORE.updateSavedBalances(stakeToken, address(type(uint160).max), stakeSavedBalanceId, delta, 0)
```

It does not transfer stake tokens for these stake operations. The calling representation handles token settlement: `VeToken` pays the stake token into Core after staking, and withdraws expired stake to the current ERC721 owner after unstaking. Approved ERC721 operators can manage a represented stake, but unstaked tokens and claimed pool fees settle to the current NFT owner. Extending is implemented as `VE33_MOVE_STAKE`, which moves saved balance from the old stake id to the new stake id without moving tokens.

## Voting

`Ve33.vote` accepts explicit `uint64` swap fees. Fees are 0.64 fixed point, so `1 << 64` is 100%, and `capFee` caps voter-selected fees to `1 << 63` or 50%. The optional `VeToken` wrapper exposes `vote(veId, poolKeys, weights, swapFees)` and `poke(veId)` as a permissionless convenience for refreshing stale represented stakes.

Each pool tracks active vote weight, voter fee growth, a snapshot of global emission growth, and the weighted fee sum. When votes change, each selected fee is capped and the pool fee is computed on demand as `feeWeightSum / weight`; integer division rounds down. With no active votes, this EVM `div` returns zero, so the pool has no extension swap fee.

Voting power is sampled when `vote` or `poke` is called:

```text
stakeAmount * (endTime - block.timestamp) / VE33_MAX_STAKE_DURATION
```

That current power is split across the supplied relative weights and written into `PoolVoteState.weight` and each stake's `VePoolPosition.weight`. Stored pool weights do not continuously decay on their own. They change when the stake votes again, when a stake operation clears votes, or when anyone calls `poke` for the stake. Emission allocation uses these stored active weights when global emission growth accrues.

Changing a stake clears that stake's votes before the amount or end time changes, keeping vote weights, fee-growth snapshots, and emission-growth snapshots synchronized with voting power.

`poke` is a permissionless stale-vote cleanup path. It accrues affected pools' reward and fee accounting using the existing stored weights up to the poke timestamp, then reduces the stake's active pool weights to current decayed voting power. If the stake has expired, `poke` clears its votes and the affected pools have zero extension fee when no other votes remain. `VeToken.poke(veId)` calls the same extension logic for ERC721-represented stakes. Claiming pool fees does not poke automatically, so users who intend to extend or restake can avoid redundant weight-refresh gas.

`vote` is not a forwarded action because it does not require token settlement. It must be called by the `Ve33` stake owner for the `StakeId`; for the ERC721 wrapper that means `VeToken` authorizes the user or approved operator, then calls `Ve33.vote` as the stake owner.

## Forwarded Swap Accounting

The forwarded swap handler uses the supplied `SwapParameters` as-is. Routers and callers are responsible for setting default sqrt-ratio limits before forwarding.

For exact-input swaps, the extension computes the maximum voter fee from `params.amount()`, calls Core with `amount - fee`, then computes the actual charged fee from the executed input delta returned by Core. If the swap executes partially, for example because it hits `sqrtRatioLimit`, the charged fee is capped to the maximum fee removed before the Core swap. The fee is added back to the returned input delta, saved under the extension and pool id, and accounted to voter fee growth.

For exact-output swaps, the extension calls Core with the zero-config-fee exact-output parameters, grosses up the Core-computed input with `amountBeforeFee`, saves the extra input as voter fees, and increases voter fee growth.

Swap fees are stored with:

```text
CORE.updateSavedBalances(token0, token1, PoolId.unwrap(poolId), fee0, fee1)
```

The extension does not call `CORE.accumulateAsFees`, so LPs do not earn Core swap fees. Only fees accounted while a pool has nonzero active vote weight increase voter fee growth. With no active vote weight, the extension swap fee is zero.

## Voter Fee Claims

Voter fees use fee-growth accounting over each pool's active vote weight. Each stake snapshots `feeGrowth0X128` and `feeGrowth1X128` for every voted pool. On nonzero weight changes, `Ve33` uses the Core snapshot-adjustment trick: it computes fees accumulated under the old weight, sets the new weight, then moves the fee-growth snapshots backward so the already accumulated amount remains claimable under the next weight. If a stake's pool vote weight is cleared to zero, pending unclaimed voter fees for that pool position are discarded.

`VE33_CLAIM_POOL_FEES` is a forwarded action. It subtracts the claimed amount from the extension's saved balance and returns the claimed token amounts to the forwarding locker.

For wrapper-owned stakes, the `Ve33` stake owner is `address(veToken)`. `VeToken.claimPoolFees(veId, poolKey)` enters a Core lock, forwards the claim to `Ve33`, and withdraws token0/token1 directly to the local stake owner.

## LP Reward Token

LPs earn only the immutable reward token, which is the same token used for ve stakes. LP rewards are independent of Core swap fees. Reward accounting uses reward-per-liquidity accumulators:

- `poolRewardState`, which packs last-accumulated time and the current Q32 reward rate
- `rewardsGlobalPerLiquidity`
- `tickRewardsOutsidePerLiquidity`
- `positionRewardsSnapshotPerLiquidity`
- scheduled `rewardRateDeltaAtTime`

`maybeAccumulateRewards` advances `rewardsGlobalPerLiquidity` using current Core pool liquidity. For stableswap pools, active liquidity is treated as zero when the current tick is outside the stableswap active-liquidity range. If liquidity is zero, accrued scheduled rewards are not assigned to LPs because `rewardsGlobalPerLiquidity` is not increased.

`VE33_SCHEDULE_REWARDS` schedules a Q32 reward rate between valid reward times. If `startTime` is in the past or zero, the new rate is applied immediately; otherwise a future rate delta is stored in `rewardRateDeltaAtTime`. The required token amount is rounded up from `rewardRate * duration` and saved in the reward reserve. `VE33_DONATE_REWARDS` immediately increases `rewardsGlobalPerLiquidity` for current active liquidity. For stableswap pools, active liquidity is zero outside the stableswap active-liquidity range. If active liquidity is zero, the donated amount is still credited to the reward reserve saved balance, but no position reward growth is created, so the donation is not claimable by LP positions.

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

`VE33_SCHEDULE_EMISSIONS` is a forwarded action that saves funded `stakeToken` in Core and schedules a global Q32 emission rate between caller-selected valid times. The call is permissionless. Governance, a PID controller, or any other external policy component can decide when and how much to schedule, but `Ve33` does not query or privilege that policy component.

Scheduling first accrues the existing global emission stream, computes the token amount required for `rewardRate * duration`, saves that amount in the LP reward reserve saved-balance bucket, increases `emissionReserve`, and records emission-rate deltas in `emissionRateDeltaAtTime`. Start and end times are tracked in a bitmap, so multiple schedules can share the same valid time without storing an append-only list.

Global emissions are accounted with:

```text
emissionGrowthGlobalX128 += emittedAmount / total active vote weight
```

If total active vote weight is zero for an interval, that interval does not increase global emission growth and no LP can claim that interval. The prepaid tokens remain in the reward reserve and `emissionReserve` as unassigned backing; they are not retroactively distributed when votes appear later.

Each pool stores `emissionGrowthGlobalX128Snapshot`. When the pool is touched through a swap, position update, reward claim, reward donation, explicit reward schedule, vote update, clear, or poke, `Ve33` accrues global emissions and computes:

```text
poolEmissionAmount =
  (emissionGrowthGlobalX128 - poolSnapshot) * pool active vote weight
```

That amount is capped by `emissionReserve`, subtracted from `emissionReserve`, and immediately added to `rewardsGlobalPerLiquidity` for the pool's current active LP liquidity. There is no separate trigger call and no keeper-chosen pool distribution step. A newly voted pool snapshots current global emission growth before its weight is added, so it starts earning from the new vote timestamp rather than receiving past emissions. If the pool has no active LP liquidity when its emission share is realized, the realized amount is removed from `emissionReserve` but cannot be claimed by positions.

## Settlement Model

The extension relies on Core saved balances for deferred accounting:

- swap fees are saved under `address(ve33)` and the pool id
- LP rewards are saved under `address(ve33)` and reward reserve salt `bytes32(0)`
- scheduled emissions are also prepaid into the LP reward reserve salt `bytes32(0)`; `emissionReserve` tracks the portion not yet assigned by global emission growth
- ve stake is saved under `address(ve33)` and `keccak256(abi.encodePacked(owner, StakeId.unwrap(stakeId)))`

`Ve33` accounts for staking, unstaking, moving stake balances, reward funding, reward claiming, and fee claiming, but does not directly transfer tokens. Callers that integrate directly with token-moving forwarded actions must settle the corresponding payment or withdrawal in the same Core lock. `VeToken` is the reference implementation for stake-owned fee claims and stake-token settlement, `Ve33Positions` is the reference implementation for LP position and reward-claim settlement, and `Ve33Periphery` is the reference implementation for generic reward and emission token settlement.

## Deployment

`script/DeployVe33.s.sol` deploys `Ve33`, `VeToken`, `Ve33Positions`, and `Ve33Periphery` with deterministic CREATE2 deployment. It requires `CORE_ADDRESS` and `STAKE_TOKEN`, and accepts optional expected-address environment variables for deployment verification. See the user guide for the operator-facing command.
