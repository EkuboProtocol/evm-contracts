# Ve33 Contracts Audit Report

Date: 2026-06-22

Reviewed state: current `ve-integrated-extension` working tree, including power-of-4 concentrated tick-spacing validation, pre-initialization voted-fee preservation, chosen-end global emission funding, and full-string VeToken metadata snapshots.

## Scope

This report covers the Ve33 integrated pool system contracts:

- `src/extensions/Ve33.sol`
- `src/VeToken.sol`
- `src/Ve33Positions.sol`

Supporting files were reviewed where needed for context:

- `src/libraries/Ve33Lib.sol`
- `src/Ve33Periphery.sol`
- `src/Router.sol`
- `src/Core.sol`
- `src/base/BaseLocker.sol`
- `src/base/FlashAccountant.sol`
- `src/libraries/FlashAccountantLib.sol`
- `test/extensions/Ve33.t.sol`
- `test/VeToken.t.sol`
- `docs/ve-integrated-extension.md`
- `docs/ve33-user-guide.md`

## Executive Summary

No critical, high, medium, or low severity security findings were identified in the reviewed scope.

The implementation is consistent with the intended architecture:

- `Ve33` is a forward-only Core extension for Ve33 pools.
- Core pool config fees must be zero; Ve33 accounts voter-selected swap fees outside Core LP fee accounting.
- Concentrated Ve33 pools and votes are limited to power-of-4 tick spacings, allowing 10 concentrated pools per pair
  under Core's current max tick spacing.
- If a pool already has active votes before initialization, initialization records the default fee without overwriting the
  active voted fee.
- Pool fee validation happens before Core pool initialization; default-fee state initialization and the current fee event
  happen after Core pool initialization.
- Global emission funders choose a valid end time; Ve33 accrues existing emissions before adding the new rate and tracks
  future rate decreases with a bitmap-backed schedule.
- `Ve33` uses Core saved balances as its accounting ledger and does not transfer ERC20 tokens directly.
- `VeToken` is an ERC721 wrapper over canonical Ve33 stake accounting.
- `Ve33Positions` is a Ve33-specific ERC721 LP position manager and does not inherit standard LP fee-collection behavior.
- `Ve33Positions` bounds total position liquidity to `type(int128).max`, keeping principal queries safe.
- LP reward accounting is range-aware and tracks initialized-tick reward growth outside ranges.
- Forward calls to Ve33 are represented by action-specific encode, decode, and execution helpers in `Ve33Lib`; there is
  no generic Ve33 forward helper.

The main residual risks are economic and operational rather than code-level vulnerabilities: stale vote weights require `poke` or stake updates to decay on-chain, uninitialized pools can receive votes before reward triggering is possible, and Core saved-balance buckets bound practical token accounting to `uint128` amounts.

## Findings Summary

| Severity | Count |
| --- | ---: |
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 0 |
| Informational / Design Notes | 3 |

## Informational / Design Notes

### I-01: Vote Decay Is Sampled, Not Continuous On-Chain

Voting power is computed from stake amount and remaining lock time when `vote` or `poke` is called. Stored pool vote weights do not continuously decay between calls. `poke` accrues fees and vote seconds using the prior stored weights, then reduces active weights to current voting power or clears expired votes.

This matches the documented design and is tested, but it means keepers or users should periodically call `poke` for stale stakes if current fee and emission allocation should reflect decayed voting power.

Evidence:

- `Ve33._votingPower` computes linearly decayed voting power from the current timestamp.
- `Ve33._vote` samples that power and stores pool weights.
- `Ve33._pokeVotes` reduces active weights to the current target.
- `VeToken.poke` exposes the same refresh path for ERC721-represented stakes.

### I-02: Votes Can Target Uninitialized Ve33 Pool Keys

`Ve33._vote` validates that each voted pool key points at the Ve33 extension and has zero Core fee, but it does not require the pool to already be initialized. This allows vote weight and vote seconds to accrue for a pool before the pool can receive triggered emissions. Reward triggering later calls into reward scheduling, which requires a valid initialized Ve33 pool through `maybeAccumulateRewards`.

This appears consistent with the permissionless pool design, but integrators should understand that votes to uninitialized pools can remain part of total vote seconds until those pools are initialized and triggered or the stake is revoted, moved, expired, or poked.

Evidence:

- `Ve33._vote` checks extension and zero fee only for pool keys.
- `Ve33._triggerPoolEmissions` accepts extension-owned pool keys, then schedules rewards through `_addRewards`.
- `Ve33.maybeAccumulateRewards` reverts with `PoolNotInitialized` when reward state is missing and the pool is not initialized for the extension.

### I-03: Reward and Emission Accounting Is Bounded by Core Saved-Balance Width

Core saved balances store per-bucket balances in `uint128` lanes. Ve33 enforces this boundary for direct LP reward scheduling and reward claims, and funding accepts `uint128` amounts. If accumulated emission allocation for one pool becomes larger than the supported reward-schedule amount, triggering that pool can revert instead of partially scheduling the excess.

This is not a vulnerability under ordinary ERC20 supply assumptions, but operators should keep funding and triggering cadence within `uint128` per-bucket accounting limits. Triggering more frequently reduces the chance that a single pool share exceeds the reward schedule bound.

Evidence:

- Core saved balances revert when a bucket would exceed `uint128`.
- `Ve33._addRewards` reverts with `RewardAmountOverflow` if the scheduled reward amount exceeds `uint128`.
- `Ve33._fundEmissions` accepts `uint128 amount`.
- `Ve33._triggerPoolEmissions` computes a pool share and forwards it to `_addRewards`.

## Component Review

### Ve33

`Ve33` registers `beforeInitializePool`, `afterInitializePool`, `beforeSwap`, and `beforeUpdatePosition` call points. `beforeInitializePool` rejects nonzero Core config fees and concentrated tick spacings that are not powers of four. `afterInitializePool` computes and stores the default extension swap fee, initializes reward state, and emits `PoolSwapFeeUpdated` with the current active pool fee. If vote state already exists for the pool, initialization preserves the active voted fee and only fills `defaultSwapFee`. Direct Core swaps revert; swaps must use the forwarded `VE33_SWAP` path. Integrators call this path through `Ve33Lib.swap`, which wraps action-specific `encodeSwap` and `decodeSwapResult` helpers.

The forwarded swap path:

- accumulates pending LP rewards before price movement,
- reduces exact-input Core swap amount by the maximum voter fee,
- charges exact-input fees from actual executed input and caps them to the amount removed up front,
- grosses up exact-output input after Core execution,
- saves voter fees in the pool saved-balance bucket,
- accounts fee growth only when active vote weight is nonzero,
- updates crossed tick reward-outside values for range-aware rewards.

Stake accounting is owned by Ve33 but token movement is not. `VE33_STAKE`, `VE33_UNSTAKE`, and `VE33_MOVE_STAKE` update `stakeAmounts`, clear affected votes, and update saved balances under the stake id. The forwarding locker is the stake owner.

Vote accounting uses fee-growth snapshots per stake and pool. Vote changes clear old votes after accruing fees and vote seconds, then write new active weights and fee choices. Pool swap fee is the weighted average selected fee, falling back to the default fee when active vote weight is zero.

LP rewards use:

- `poolRewardState`
- `rewardsGlobalPerLiquidity`
- `tickRewardsOutsidePerLiquidity`
- `positionRewardsSnapshotPerLiquidity`
- `rewardRateDeltaAtTime`

Position updates snapshot reward growth before liquidity changes. For concentrated pools, initialized tick boundaries are initialized, cleared, and inverted similarly to Core fee-outside accounting. For stableswap pools, reward activity is limited to the active-liquidity tick range.

Global emissions are funded through a forwarded action with a caller-selected valid end time. Funding accrues existing emissions first, increases the current Q32 emission rate, records a rate decrease at the chosen end time, and marks that end time in a bitmap. Accrual walks initialized end times up to the current block timestamp, moves streamed emissions into `unallocatedEmissions`, applies scheduled rate decreases, clears consumed bitmap entries, and leaves pool selection to independent `triggerPoolEmissions` calls.

### VeToken

`VeToken` is an ERC721 representation for stakes whose canonical accounting lives in `Ve33`. Token ids are used directly as Ve33 stake salts. The amount is read from Ve33 storage through `Ve33Lib`; the stake end timestamp is stored in Solady ERC721 extra data.

The wrapper authorizes stake operations through ERC721 owner or approval checks, then enters a Core lock and calls the action-specific `Ve33Lib` stake, unstake, move-stake, and claim-fee helpers. Token settlement happens in the wrapper:

- staking pays `stakeToken` into Core after Ve33 increases the saved stake balance,
- unstaking withdraws `stakeToken` to the current NFT owner after Ve33 decreases the saved stake balance,
- moving stake updates Ve33 saved-balance buckets without token transfers,
- pool-fee claims withdraw pool tokens to the current NFT owner.

Transfers and approvals therefore move control of the represented stake without moving Ve33 canonical state.

### Ve33Positions

`Ve33Positions` is a Ve33-specific ERC721 liquidity position manager. It validates pool keys against the immutable Ve33 extension and derives Core `PositionId` from `(tokenId, tickLower, tickUpper)`.

Deposits and withdrawals are authorized by NFT ownership or approval, happen under a Core lock, and settle token principal through the accountant. The contract does not collect Core LP swap fees because Ve33 pools use zero Core config fees and account swap fees to voters instead.

Deposits reject both per-call liquidity deltas and resulting total position liquidity above `type(int128).max`. This keeps `getPositionLiquidity` safe because the helper computes principal amounts by casting the stored position liquidity to `int128` before passing a negative liquidity delta into `liquidityDeltaToAmountDelta`.

Reward claims use the action-specific `Ve33Lib.claimRewards` helper, then withdraw the returned `stakeToken` amount to the requested recipient. The extension computes rewards for the position owner as `address(Ve33Positions)`.

## Invariants Reviewed

- Ve33 pools cannot be initialized with nonzero Core config fees.
- Concentrated Ve33 pools cannot be initialized or voted on unless their tick spacing is a power of four.
- Pre-initialization votes cannot be overwritten by later pool initialization.
- Pool initialization emits the current active pool fee after Core initialization.
- Direct swaps through Core are blocked for Ve33 pools.
- Ve33 has no `receive` function, does not call ERC20 transfer helpers, and does not custody tokens outside Core saved
  balances.
- Ve33 token-moving actions are forwarded and settled by wrappers or periphery contracts.
- Voter pool fees are saved under the pool id and claimed through fee-growth accounting.
- LP rewards are denominated in the immutable `stakeToken`.
- LP reward accounting is range-aware for concentrated and stableswap pools.
- Position reward snapshots are updated before liquidity changes.
- Exact-input forwarded swaps charge fees from executed input and cap partial-fill fees.
- VeToken claims and unstaking settle to the current NFT owner, even when an approved operator initiates the action.
- Ve33Positions owner/approval checks gate deposits, withdrawals, and LP reward claims.
- Ve33Positions deposits cannot make stored liquidity exceed `type(int128).max`, so `getPositionLiquidity` remains queryable.
- Global emission schedules accrue existing rates before new funding, support multiple streams ending at the same valid time, and clear their bitmap entries after the scheduled rate decrease is applied.

## Test Coverage Reviewed

The existing tests cover the key audited behavior:

- extension registration and call point selection,
- zero Core fee pool initialization,
- concentrated power-of-4 tick-spacing validation,
- preservation of pre-initialization voted fees,
- pool-fee event emission after initialization,
- direct hook rejection,
- vote validation and default fee voting,
- forwarded swap voter fee accounting,
- partial exact-input fee accounting for token0 and token1 inputs,
- exact-output fee paths,
- vote clearing, decay, and `poke`,
- pro-rata voter fee claims,
- reward donations and reward claims,
- zero-liquidity reward donation behavior,
- immediate and future reward schedules,
- stableswap active-range reward behavior,
- global emission funding and per-pool triggering,
- caller-chosen global emission end times and shared emission-end bitmap entries,
- malicious pool-key extension routing regression in `Ve33Periphery`,
- Ve33Positions authorization and independent positions,
- Ve33Positions resulting-liquidity overflow rejection and `getPositionLiquidity` queryability at `type(int128).max`,
- reward snapshots across concentrated and stableswap boundaries,
- VeToken metadata JSON and decoded SVG fixture snapshots, stake lifecycle, transfer, approval, and owner-directed withdrawal behavior.

## Verification

Commands run against the reviewed working tree:

```sh
forge fmt
forge build --offline --sizes
forge test --offline --match-test test_vePositionsRejectsDepositsThatOverflowQueryableLiquidity
forge test --offline --match-contract IsPowerOfFourTest
forge test --offline --match-contract Ve33Test
forge test --offline --match-contract 'Ve33Test|VeTokenTest|RouterTest'
forge test --offline
```

The focused Ve33Positions liquidity regression, focused power-of-four math suite, full Ve33 suite, focused Ve33/VeToken/Router suite, full test suite, and size build completed successfully for the reviewed working tree. The full suite passed with 825 tests. Existing forge-lint warnings unrelated to this report remain present in the repository.
