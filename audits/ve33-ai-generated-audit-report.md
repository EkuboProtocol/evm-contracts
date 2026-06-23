# AI-Generated Ve33 Branch Audit Report

Date: 2026-06-23

Branch reviewed: `ve-integrated-extension`

Review type: AI-generated security review. This report was produced by an AI coding agent and should not be treated as
an independent human audit or a substitute for formal security review.

## Scope

The audit scope is limited to source files introduced, modified, or removed by this branch under `src/`:

- `src/extensions/Ve33.sol`
- `src/libraries/Ve33Lib.sol`
- `src/Ve33Periphery.sol`
- `src/Ve33Positions.sol`
- `src/VeToken.sol`
- `src/Router.sol`
- `src/base/BaseRouter.sol`
- `src/math/isPowerOfFour.sol`
- `src/math/tickSpacingFee.sol`
- `src/types/stakeId.sol`
- `src/types/ve33RewardPoolState.sol`
- `src/MEVCaptureRouter.sol` removal and migration into `src/Router.sol`

Tests, docs, deploy helpers, and unchanged dependencies were reviewed as supporting evidence. They were not part of the
audited source scope except where needed to understand how the changed contracts interact with existing Core,
accountant, locker, and math primitives.

## Executive Summary

No critical, high, medium, or low severity security findings were identified in the reviewed source scope.

The branch implements a Ve33-specific extension architecture with these main properties:

- Ve33 pools use zero Core config fees and account voter-selected swap fees outside Core LP fee accounting.
- Direct Core swaps are blocked for Ve33 pools; swaps are executed through the forwarded Ve33 swap path.
- Voter fees are charged by the extension swap path, saved under pool-specific Core saved-balance buckets, and claimed by
  stake owners through fee-growth accounting.
- LPs do not earn swap fees. They earn the immutable `stakeToken` through range-aware per-position rewards.
- LP reward accounting mirrors Core fee-outside accounting by tracking global reward growth, initialized-tick reward
  growth outside, and per-position reward snapshots.
- Ve33 does not perform token transfers and does not custody tokens directly. It accounts token obligations through Core
  saved balances.
- Token movement is handled by wrappers, periphery contracts, positions contracts, and routers that call Ve33 through
  action-specific forward helpers.
- Ve33 contains canonical stake, vote, voter-fee, global-emission, and LP-reward accounting.
- Global emissions are scheduled and prepaid by external policy/controller callers, then allocated continuously by active
  vote weight through `emissionGrowthGlobalX128`. Ve33 does not query or embed emission policy.
- VeToken is an ERC721 representation of Ve33 stakes, with token ids used as stake salts.
- Ve33Positions is a Ve33-specific ERC721 position manager and intentionally does not inherit LP fee-collection logic.
- The generic router was split into `BaseRouter` plus `Router`, and the old `MEVCaptureRouter` behavior was merged into
  `Router` alongside Ve33 swap routing.

The main remaining risks are design and operational risks: vote decay is sampled when votes are touched, votes can be
cast for uninitialized Ve33 pool keys, reward and fee accounting uses fixed-width Core saved-balance lanes, scheduled
emission intervals with no active votes are not retroactively distributed, and `Ve33Lib` storage readers depend on the
exact `Ve33` storage layout.

## Findings Summary

| Severity | Count |
| --- | ---: |
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| Informational / Design Notes | 6 |

## Informational / Design Notes

### I-01: Vote Decay Is Sampled When Stakes Are Touched

Voting power decays linearly with remaining stake duration, but stored pool vote weights do not continuously update on
chain. They are refreshed when a stake votes, is poked, is moved, is increased, is unstaked, or otherwise clears and
rewrites voting state.

This is consistent with the intended gas model. It means pool fee weights and emission allocation use the last sampled
voting power until someone updates stale votes. The `poke` path exists to let anyone refresh stale stakes, and VeToken
exposes that operation for NFT-represented stakes.

Operational impact:

- Active pool fees can lag current decayed voting power until votes are touched.
- Emission allocation can include stale weight for a stake until the stale vote is poked or otherwise changed.
- Keepers or interested users should call `poke` on long-idle stakes when current weights matter.

### I-02: Votes Can Be Cast Before Pool Initialization

Ve33 voting validates that a pool key belongs to the Ve33 extension, uses zero Core config fee, and uses an allowed
concentrated tick spacing. It does not require the pool to already be initialized. This permits permissionless
pre-initialization signaling.

Uninitialized pools cannot accrue LP rewards because they do not yet have Core pool liquidity or stored pool reward
state. When such a pool is voted, Ve33 snapshots current global emission growth for that pool before adding vote weight,
so the pool cannot claim global emissions from before the vote. Once the pool is initialized, normal pool touches can
realize its share of later emission growth.

Operational impact:

- Votes for never-initialized pools can remain part of total active vote weight until users revote, clear, poke, move, or
  expire those stakes.
- Emission growth earned by initialized pools is still computed from total active vote weight, so abandoned
  pre-initialization votes can dilute initialized pools until refreshed.

### I-03: Core Saved-Balance Width Bounds Large Accounting Flows

Ve33 uses Core saved balances for stake balances, fee buckets, reward reserves, emission reserves, and claimable
accounting. These lanes are bounded by Core's saved-balance width. Ve33 also bounds scheduled reward and emission amounts
to fit the supported accounting width.

This is not a vulnerability under the branch's token supply assumptions, but it is a hard accounting boundary. Very large
single schedules, very large donations, or very infrequent reward realization could revert instead of partially accepting
excess amounts.

Operational impact:

- Funders should avoid creating per-bucket balances near fixed-width limits.
- Schedulers should prefer bounded rates and durations that keep one schedule's prepaid amount well below the supported
  width.

### I-04: Zero-Vote Emission Intervals Are Not Retroactive

Global emissions are scheduled as Q32 rates and prepaid into the LP reward reserve. When global emissions accrue while
`totalVoteWeight == 0`, `emissionGrowthGlobalX128` does not increase. Those elapsed emissions are therefore not
claimable by any pool and are not retroactively distributed when votes appear later.

The prepaid tokens remain in the reward reserve and in `emissionReserve` as unassigned backing. Later global emission
growth can consume reserve, but only for intervals where active vote weight exists and the emission rate is still active
or has been extended by later schedules.

Operational impact:

- Controllers should avoid scheduling meaningful emissions for periods expected to have no active vote weight unless
  burning or stranding that interval's emission is acceptable.
- Initialization and voting should be coordinated before high-value schedules begin.

### I-05: Ve33Lib Storage Readers Are Layout Coupled

`Ve33Lib` exposes read helpers through `ExposedStorage` and hard-coded storage slot derivations. This reduces `Ve33`
runtime bytecode because public getters are removed from the extension, but it couples the library to the exact storage
layout of `Ve33` and its bases.

This is acceptable for the current branch, but future edits must treat storage layout as part of the library interface.

Maintenance impact:

- Adding state variables before existing Ve33 storage can silently break `Ve33Lib` readers.
- Adding a stateful base contract before `Ve33` storage can also break the reader assumptions.
- Storage layout changes should include targeted tests for every `Ve33Lib` reader.

### I-06: Router Deployment Must Use the Correct Extension Addresses

`Router` now contains routing support for both MEV capture pools and Ve33 pools. It decides whether to forward a swap
based on immutable extension addresses supplied at deployment.

This is not a contract-level vulnerability, but it is a deployment invariant. A router deployed with an incorrect or zero
Ve33 address will fail to route Ve33 pools through the required forwarded swap path. Direct Core swaps into Ve33 pools are
intentionally rejected by the extension.

Operational impact:

- Deploy scripts and tests should keep the router's configured Ve33 address in sync with the deployed extension address.
- Integrators should not assume a generic router instance can swap Ve33 pools unless it was deployed with the matching
  Ve33 extension.

## Component Review

### Ve33

`Ve33` is the canonical extension for Ve33 pools. It registers pool initialization, swap blocking, and position update
hooks. It validates zero Core config fees and power-of-four concentrated tick spacing before Core pool initialization,
then stores the canonical pool key and initializes reward/emission snapshots after initialization.

The extension is forward-first for user-facing actions that require token accounting or Core lock context. It dispatches
specific actions for swaps, stake changes, LP reward donations and schedules, global emission schedules, LP reward
claims, and voter fee claims. It does not expose a generic arbitrary forward helper.

The swap path accumulates rewards before price movement, removes a maximum voter fee from exact-input swaps before
calling Core, computes exact-input fees from actual consumed input, caps those fees to the amount removed up front, and
adds exact-output voter fees after Core computes the required input. The resulting voter fees are saved into
pool-specific fee buckets and added to voter fee-growth accounting when active vote weight is nonzero.

Voter fee accounting tracks fee growth per pool token and per stake. Vote changes first accrue pool emission/reward
accounting for the old stored weights, then update active weights and selected fees. The active pool fee is computed on
demand as `feeWeightSum / weight`. The assembly `div` intentionally returns zero when `weight == 0`, so unvoted pools
have no extension swap fee.

LP reward accounting is range-aware. The extension tracks:

- global reward growth per liquidity,
- initialized tick reward growth outside,
- position reward growth snapshots,
- per-pool scheduled reward-rate deltas,
- stableswap active-range reward boundaries,
- global emission growth per unit of active vote weight.

Position reward snapshots are updated before liquidity changes. Concentrated tick outside values are initialized,
cleared, and inverted as positions and swaps cross initialized ticks.

Global emissions are permissionlessly scheduled through `VE33_SCHEDULE_EMISSIONS`. The caller chooses valid start and
end times and a Q32 reward rate, and the required token amount is prepaid into the LP reward saved-balance bucket.
`_accrueEmissions` advances `emissionGrowthGlobalX128` using the current total active vote weight. Each pool stores an
`emissionGrowthGlobalX128Snapshot`; when the pool is touched, its share of global growth is realized into
`rewardsGlobalPerLiquidity` for current active LP liquidity and subtracted from `emissionReserve`. There is no separate
pool-emission trigger.

Stake accounting lives in Ve33, but token transfers do not. Stake, unstake, and stake movement update saved-balance
buckets and canonical stake mappings. Wrappers such as VeToken settle the actual token movement around the forwarded
call.

### Ve33Lib

`Ve33Lib` contains action-specific calldata encoders, result decoders, and forward-call helpers for Ve33. It also exposes
storage reader helpers for stakes, vote states, pool reward state, emission state, stored pool keys, and voting power
calculations.

This design keeps call sites explicit and avoids a generic Ve33 forwarding surface. The main tradeoff is storage layout
coupling. Any future Ve33 storage layout change must be reviewed against `Ve33Lib` slot derivations.

### Ve33Periphery

`Ve33Periphery` is a settlement helper for actions that require token movement around Ve33 forward calls. It is bound to
an immutable `Ve33` instance and forwards reward and emission actions to that immutable address, not to an arbitrary
extension supplied through a pool key.

The reviewed periphery exposes reward donation, pool reward scheduling, and global emission scheduling. It no longer
exposes a swap function. Swap support is routed through `Router`, which handles swap normalization and calls Ve33's
forwarded swap path for Ve33 pools.

### Ve33Positions

`Ve33Positions` is a Ve33-specific ERC721 position manager. It does not inherit `BasePositions` because Ve33 LPs do not
earn Core swap fees. It validates that positions use the immutable Ve33 extension, tracks position ownership through
ERC721 ownership and approvals, and settles principal through Core/accountant flows.

Deposits validate both per-call liquidity deltas and resulting total liquidity against `type(int128).max`. This preserves
the safety of `getPositionLiquidity`, which casts stored liquidity to `int128` before computing principal amounts.

LP reward claims use Ve33's action-specific claim helper and withdraw the resulting `stakeToken` amount to the requested
recipient.

### VeToken

`VeToken` is an ERC721 representation of Ve33 stakes. The canonical stake amount is read from Ve33 storage, and the token
id is used directly as the Ve33 stake salt. The stake end timestamp is stored in Solady ERC721 extra data.

Stake, unstake, and move-stake operations authorize through ERC721 owner or approval checks, then call Ve33 through
action-specific helpers. Token settlement happens in VeToken:

- staking pays `stakeToken` into Core after Ve33 records the saved stake balance,
- unstaking withdraws `stakeToken` to the current NFT owner after Ve33 releases the saved stake balance,
- moving a stake changes Ve33 stake buckets without transferring tokens,
- claiming voter fees withdraws pool tokens to the current NFT owner.

Metadata is generated on chain as ERC721 JSON with embedded SVG. The displayed stake amount is adjusted for the
underlying stake token decimals, and the date is rendered as readable text.

### Router and BaseRouter

The router split leaves shared lock, multihop, and settlement behavior in `BaseRouter`. `Router` supplies the swap
implementation and routes extension-specific swaps.

For normal pools, the router avoids unnecessary extension checks when no swap hooks are relevant. For MEV capture pools,
the previous `MEVCaptureRouter` override is now handled in `Router`. For Ve33 pools, the router normalizes user swap
parameters before forwarding to Ve33. Default sqrt ratio limits remain a router responsibility and are not applied inside
the Ve33 forward handler.

### Math And Type Helpers

`isPowerOfFour` is a free function used to constrain concentrated Ve33 tick spacing and reduce pool fragmentation. Core
already enforces maximum tick spacing, so this helper only answers whether a provided spacing is a power of four.

`tickSpacingFee` now only contains `capFee` and `MAX_VE_FEE`, capping voter-selected explicit fees at 50%.

`StakeId` is a custom type storing `bytes24 salt || uint64 endTime`. `Ve33RewardPoolState` is a custom type storing a
32-bit truncated last-accumulated timestamp and a 224-bit Q32 reward rate.

### MEVCaptureRouter Removal

`src/MEVCaptureRouter.sol` was removed because its swap override was migrated into `src/Router.sol`. The reviewed risk is
that MEV capture routing and Ve33 routing now share one router deployment surface. This is acceptable but increases the
importance of correct immutable extension address configuration.

## Invariants Reviewed

- Ve33 pools reject nonzero Core config fees.
- Concentrated Ve33 pools only allow power-of-four tick spacing.
- Direct Core swaps into Ve33 pools revert.
- Forwarded exact-input swaps charge voter fees from actual consumed input and cap them to the fee removed before Core
  execution.
- Forwarded exact-output swaps gross up the actual Core input by the current voter fee.
- Active pool fee is the weighted average of explicit fee votes and is zero when active pool vote weight is zero.
- Voter fee accounting uses saved balances and fee-growth snapshots.
- Vote updates, clears, and pokes accrue pool emission/reward state before weight changes.
- Global emissions are scheduled through forward calls, prepaid into saved balances, and allocated by
  `emissionGrowthGlobalX128` according to active vote weight.
- Ve33 does not transfer ERC20 tokens or receive native ETH directly.
- Token movement is handled by VeToken, Ve33Positions, Ve33Periphery, or Router settlement paths.
- LP reward accounting is per-position and range-aware.
- Initialized tick reward-outside accounting is updated when swaps cross initialized ticks.
- Position reward snapshots are updated before liquidity changes.
- Zero-liquidity reward donations are saved but produce no claimable LP reward growth.
- Emission scheduling accrues existing emission state before adding a new rate.
- Emission schedulers choose valid start and end times, and scheduled rate deltas are tracked without storing an
  append-only list.
- VeToken claims and unstaking settle to the current NFT owner.
- Ve33Positions deposits cannot make stored liquidity exceed the `int128` queryability bound.
- Ve33Periphery forwards only to its immutable Ve33 instance.
- Router applies default swap limits before forwarding and does not rely on Ve33 to apply router conveniences.

## Test Evidence Reviewed

The reviewed test suite covers the major audited behaviors:

- extension registration and call point selection,
- zero Core fee pool initialization,
- concentrated power-of-four tick-spacing validation and fuzzing,
- explicit fee capping,
- pre-initialization vote support and later reward accounting,
- direct hook and direct swap rejection,
- vote validation, vote clearing, decay, and `poke`,
- zero-fee behavior when no active votes exist,
- forwarded swaps through the router,
- partial exact-input fee accounting for both token directions,
- exact-output fee accounting,
- voter fee claims and pro-rata fee growth,
- reward donation, reward claims, zero-liquidity donation behavior, and future reward schedules,
- reward boundary snapshots for concentrated and stableswap pools,
- global emission scheduling, valid chosen start/end times, same-time schedule aggregation, and continuous pool-touch
  allocation,
- zero-vote emission interval behavior,
- pro-rata distribution to touched voted pools,
- Ve33Periphery immutable-extension forwarding and settlement coverage,
- Ve33Positions authorization, independent positions, reward claims, and liquidity overflow guard,
- VeToken stake lifecycle, transfers, approvals, fee claims, unstake settlement, metadata, SVG decoding, and gas
  snapshots,
- `StakeId` and `Ve33RewardPoolState` custom-type round trips and dirty-bit behavior.

## Residual Risk

The audited code is still a large economic system with several surfaces that should receive continued review:

- economic effects of sampled vote decay,
- keeper incentives and timing around `poke` and normal pool touches,
- pool fragmentation and stake incentives under the power-of-four tick-spacing policy,
- zero-vote and zero-liquidity scheduled-emission behavior,
- production deployment configuration for router and periphery immutables,
- future storage layout edits that could break `Ve33Lib` readers.

## Verification

Commands run against the reviewed working tree:

```sh
git diff --check
forge fmt
forge build --offline --sizes
forge test --offline
```

Results:

- `git diff --check` passed.
- `forge fmt` completed.
- `forge build --offline --sizes` passed.
- `forge test --offline` passed: 825 tests passed, 0 failed, 0 skipped.
