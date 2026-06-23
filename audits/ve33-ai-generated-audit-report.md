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
- `src/MEVCaptureRouter.sol` removal and migration into `src/Router.sol`

Tests, docs, deploy helpers, and unchanged dependencies were reviewed only as supporting evidence. They were not part of
the audited source scope except where needed to understand how the changed contracts interact with existing Core,
accountant, locker, and math primitives.

## Executive Summary

No critical, high, medium, or low severity security findings were identified in the reviewed source scope.

The branch implements a Ve33-specific extension architecture with these main properties:

- Ve33 pools use zero Core config fees and account voter-selected swap fees outside Core LP fee accounting.
- Direct Core swaps are blocked for Ve33 pools; swaps are executed through the forwarded Ve33 swap path.
- Voter fees are charged by the extension swap path, saved under pool-specific Core saved-balance buckets, and claimed by
  stake owners through fee-growth accounting.
- LPs do not earn swap fees. They earn the immutable `stakeToken` as per-position rewards.
- LP reward accounting is range-aware and mirrors Core fee-outside accounting by tracking global reward growth,
  initialized-tick reward growth outside, and per-position reward snapshots.
- Ve33 does not perform token transfers and does not custody tokens directly. It accounts token obligations through Core
  saved balances.
- Token movement is handled by wrappers and periphery contracts that call Ve33 through action-specific forward helpers.
- Ve33 contains canonical stake, vote, fee, emission, and LP reward accounting.
- VeToken is an ERC721 representation of Ve33 stakes, with token ids used as stake salts.
- Ve33Positions is a Ve33-specific ERC721 position manager and intentionally does not inherit LP fee-collection logic.
- The generic router was split into `BaseRouter` plus `Router`, and the old `MEVCaptureRouter` behavior was merged into
  `Router` alongside Ve33 swap routing.

The main remaining risks are design and operational risks: vote decay is sampled when votes are touched, votes can be
cast for uninitialized Ve33 pool keys, reward and fee accounting uses fixed-width Core saved-balance lanes, and
`Ve33Lib` storage readers depend on the exact `Ve33` storage layout.

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
chain. They are refreshed when a stake votes, is poked, is moved, is unstaked, or otherwise touches the voting state.

This is consistent with the intended gas model. It means pool fee weights, vote seconds, and emission allocation reflect
the last sampled voting power until someone updates stale votes. The `poke` path exists to let anyone refresh stale
stakes, and VeToken exposes that operation for NFT-represented stakes.

Operational impact:

- Active pool fees can lag the current decayed voting power until votes are touched.
- Emission allocation can include stale weight for a stake until the stale vote is poked or otherwise changed.
- Keepers or interested users should call `poke` on long-idle stakes when current weights matter.

### I-02: Votes Can Be Cast Before Pool Initialization

Ve33 voting validates that a pool key belongs to the Ve33 extension, uses zero Core config fee, and uses an allowed
concentrated tick spacing. It does not require the pool to already be initialized. This permits permissionless
pre-initialization signaling, but reward triggering later depends on initialized pool reward state.

This appears intentional for the current design, and initialization preserves any already-voted active fee instead of
overwriting it with the default fee. Integrators should still be aware that votes for uninitialized pools can affect
vote totals before those pools are able to receive scheduled rewards.

Operational impact:

- Votes can accrue vote seconds for a pool that cannot yet receive LP reward emissions.
- If a voted pool is never initialized, users or keepers need to revote, poke, move, or expire those stakes to remove the
  stale allocation.

### I-03: Core Saved-Balance Width Bounds Large Accounting Flows

Ve33 uses Core saved balances for stake balances, fee buckets, reward reserves, and claimable accounting. These lanes are
bounded by Core's saved-balance width. Ve33 also bounds reward scheduling and emission funding amounts to fit the same
style of accounting.

This is not a vulnerability under normal token supply assumptions, but it is a hard accounting boundary. Very large
single funding events, very large per-pool reward triggers, or very infrequent triggering could revert instead of
partially scheduling excess rewards.

Operational impact:

- Funders and keepers should avoid creating per-bucket balances or per-trigger reward amounts near fixed-width limits.
- More frequent emission triggering reduces the chance that one pool's accumulated share exceeds the supported reward
  schedule amount.

### I-04: Small Emission Shares Can Round to Zero

Global emissions are accumulated into an unallocated reserve and distributed to pools when each pool is triggered. A pool
with a very small share of vote seconds can produce a reward amount that rounds to zero for the actual LP reward schedule.

The test suite covers this as expected behavior. It avoids forcing all tiny shares into nonzero schedules, but it means
very small voted pools may need more elapsed time or more vote share before a trigger produces a meaningful reward rate.

Operational impact:

- Tiny pools can have triggers that do not create LP rewards.
- Residual unallocated or unscheduled dust should be expected around very small shares and integer division.

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
hooks. It validates zero Core config fees and allowed tick spacing for concentrated pools, initializes reward state after
Core pool initialization, and emits the current pool fee after initialization.

The extension is forward-first for user-facing actions that require token accounting or Core lock context. It dispatches
specific actions for swaps, stake changes, reward funding, emission triggering, LP reward claims, and voter fee claims.
It does not expose a generic arbitrary forward helper.

The swap path accumulates rewards before price movement, removes a maximum voter fee from exact-input swaps before
calling Core, computes exact-input fees from actual consumed input, caps those fees to the amount removed up front, and
adds exact-output voter fees after Core computes the required input. The resulting voter fees are saved into pool-specific
fee buckets.

Voter fee accounting tracks fee growth per pool token and per stake. Vote changes first accrue fees and vote seconds for
the old weights, then update active weights and selected fees. The active pool fee is the weighted average fee selected by
current active votes, falling back to the default tick-spacing-derived fee when active vote weight is zero.

LP reward accounting is range-aware. The extension tracks:

- global reward growth per liquidity,
- initialized tick reward growth outside,
- position reward growth snapshots,
- future reward-rate decreases,
- stableswap active-range reward boundaries.

Position reward snapshots are updated before liquidity changes. Concentrated tick outside values are initialized,
cleared, and inverted as positions and swaps cross initialized ticks.

Stake accounting lives in Ve33, but token transfers do not. Stake, unstake, and stake movement update saved-balance
buckets and canonical stake mappings. Wrappers such as VeToken settle the actual token movement around the forwarded call.

### Ve33Lib

`Ve33Lib` contains action-specific calldata encoders, result decoders, and forward-call helpers for Ve33. It also exposes
storage reader helpers for stakes, vote states, pool fee state, reward state, and voting power calculations.

This design keeps call sites explicit and avoids a generic Ve33 forwarding surface. The main tradeoff is storage layout
coupling. Any future Ve33 storage layout change must be reviewed against `Ve33Lib` slot derivations.

### Ve33Periphery

`Ve33Periphery` is a settlement helper for actions that require token movement around Ve33 forward calls. It is bound to
an immutable `Ve33` instance and forwards reward and emission actions to that immutable address, not to an arbitrary
extension supplied through a pool key.

The reviewed periphery no longer exposes a swap function. Swap support is routed through `Router`, which handles swap
normalization and calls Ve33's forwarded swap path for Ve33 pools.

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

### Math Helpers

`isPowerOfFour` is a free function used to constrain concentrated Ve33 tick spacing and reduce pool fragmentation.
Core already enforces maximum tick spacing, so this helper only answers whether a provided spacing is a power of four.

`tickSpacingFee` computes a default pool fee from tick spacing for concentrated pools and amplification for stableswap
pools. Fees are capped at 50%.

### MEVCaptureRouter Removal

`src/MEVCaptureRouter.sol` was removed because its swap override was migrated into `src/Router.sol`. The reviewed risk is
that MEV capture routing and Ve33 routing now share one router deployment surface. This is acceptable but increases the
importance of correct immutable extension address configuration.

## Invariants Reviewed

- Ve33 pools reject nonzero Core config fees.
- Concentrated Ve33 pools only allow power-of-four tick spacing.
- Pool initialization preserves any already-voted pool fee and only fills the default fee when vote state already exists.
- Pool fee validation happens before Core initialization; pool fee event emission happens after initialization.
- Direct Core swaps into Ve33 pools revert.
- Forwarded exact-input swaps charge voter fees from actual consumed input and cap them to the fee removed before Core
  execution.
- Forwarded exact-output swaps gross up the actual Core input by the current voter fee.
- Voter fee accounting uses saved balances and fee-growth snapshots.
- Ve33 does not transfer ERC20 tokens or receive native ETH directly.
- Token movement is handled by VeToken, Ve33Positions, Ve33Periphery, or Router settlement paths.
- LP reward accounting is per-position and range-aware.
- Initialized tick reward-outside accounting is updated when swaps cross initialized ticks.
- Position reward snapshots are updated before liquidity changes.
- Zero-liquidity reward donations are burned according to the current design.
- Emission funding accrues existing emission state before adding a new rate.
- Emission funders choose valid end times, and scheduled end-time rate decreases are tracked without storing an
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
- tick-spacing fee math and fuzzing,
- pre-initialization vote fee preservation,
- pool fee event emission,
- direct hook and direct swap rejection,
- vote validation, vote clearing, decay, and `poke`,
- default fee computation for concentrated and stableswap pools,
- forwarded swaps through the router,
- partial exact-input fee accounting for both token directions,
- exact-output fee accounting,
- voter fee claims and pro-rata fee growth,
- reward donation, reward claims, zero-liquidity donation behavior, and future reward schedules,
- reward boundary snapshots for concentrated and stableswap pools,
- global emission funding, valid chosen end times, and per-pool triggering,
- tiny pool emission share rounding behavior,
- Ve33Periphery immutable-extension forwarding regression coverage,
- Ve33Positions authorization, independent positions, reward claims, and liquidity overflow guard,
- VeToken stake lifecycle, transfers, approvals, fee claims, unstake settlement, metadata, SVG decoding, and gas snapshots.

## Residual Risk

The audited code is still a large economic system with several surfaces that should receive continued review:

- economic effects of sampled vote decay,
- keeper incentives and timing around `poke` and emission triggering,
- pool fragmentation and stake incentives under the power-of-four tick-spacing policy,
- dust behavior for tiny emission shares,
- production deployment configuration for router and periphery immutables,
- future storage layout edits that could break `Ve33Lib` readers.

## Verification

Commands run against the reviewed working tree:

```sh
git diff --check
forge build --offline --sizes
forge test --offline
```

Results:

- `git diff --check` passed.
- `forge build --offline --sizes` passed.
- `forge test --offline` passed: 825 tests passed, 0 failed, 0 skipped.

No Solidity files were changed while producing this report, so `forge fmt` was not required.
