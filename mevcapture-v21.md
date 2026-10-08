# MEVCapture v2.1

`src/extensions/MEVCaptureV21.sol` implements the EKU-946 design rev 5, §(b) ("v2.1"): an in-swap, segmented,
away-only surcharge around a time-decaying anchor, with a liquidity gate and a rate limit on anchor movement. It is a new,
forward-only extension. `MEVCapture.sol` (v1) and `Core` are unchanged. Nothing here is deployed.

## Mechanism (as implemented)

State is one word per pool (`src/types/mevCaptureV21PoolState.sol`):

| bits | field |
|---|---|
| 255..224 | `lastUpdateTime` |
| 223..192 | `lRefTime` |
| 191..160 | `lastPosTime` |
| 159..152 | `lRefBits` |
| 151..144 | `snapBits` |
| 143..112 | `lRefRaiseTime` |
| 111..64 | reserved (zero) |
| 63..0 | `anchorX16` (int64, Q48.16 ticks) |

Immutables (constructor-checked, exposed by `getConfig()`): `HALF_LIFE` τ ∈ [1, 2^20], `SLOPE_K` ∈ [1, 16], `SEGMENT_EXP`
≤ 8, `J_LIN` ∈ [1, 64], `MAX_FEE` ∈ [1, 2^15], `CLAMP_TICKS` ∈ [1, 2·MAX_TICK], `M_GATE` ≤ 16, plus the budget lemma.
`MAX_SEGMENTS = J_LIN + 24`. Defaults: τ = 120 s, `SLOPE_K` = 4 (k = 2), W = tickSpacing, `J_LIN` = 16, `MAX_FEE` = 2^15,
CLAMP = 2 500 ticks/τ, `M_GATE` = 3.

Call points: `beforeInitializePool` (state init; rejects stableswap/full-range, fee 0, fee ≥ `MAX_FEE`), `beforeSwap`
(always reverts; Core skips it only when the extension itself is the locker), `beforeUpdatePosition` (snapshot only,
`onlyCore`).

`handleForwardData` (every swap):
1. On the first swap of a timestamp, the anchor update: observation `L_obs` (the snapshot if a position changed earlier
   in the timestamp), decayed reference `e_ref`, gate `L_obs + M_GATE ≥ e_ref`; on a pass the exp2 decay toward the pool
   tick, clamped to `CLAMP·min(Δt, τ)/τ`, and `lRefBits = raise(e_ref, L_obs)`; on a fail `AnchorGateFailed(poolId,
   L_obs, e_ref)`.
2. The swap: one Core call toward the anchor (limit = the rounded anchor, floor from below / ceil from above, minFee =
   the caller's), then one Core call per away segment with `minFee = max(caller minFee, fee_j)`, segments chosen by sqrt
   ratio (a boundary the price sits on is skipped), merged to the user limit once `fee_j = MAX_FEE` or at the last
   budgeted call. Balance updates are summed with checked int128 arithmetic.
3. Post-swap refresh of the reference (H1-capped) unless a position changed in the timestamp. One `sstore` at most.

Implementation choices the spec leaves open (all mirrored by the vectors):
- The budget merge happens on the `MAX_SEGMENTS`-th away call (`n == MAX_SEGMENTS − 1` completed calls), so a swap makes
  at most `MAX_SEGMENTS` away calls ("J_LIN = 64 (88 calls)"). The constructor proves the cap is reached first.
- The rounded anchor tick is clamped to `[MIN_TICK, MAX_TICK]` before `tickToSqrtRatio` (Core can report `MIN_TICK − 1`).
- A segment boundary beyond `MAX_TICK` makes that segment run to the user limit.
- `params.withDefaultSqrtRatioLimit()` is applied, so a zero limit means "no limit" as through the Router.

## Tests

| invariant (§b) | where |
|---|---|
| every swap: deltas, state after, Core call sequence (limit, fee, amount), gate event, extension state vs an independent reference executed on a twin pool without extension | `MEVCaptureV21Base._swapChecked` (used by all scenario tests, the fuzz and the stateful test) |
| 1 anchor written only by the update rule | `test_anchor_written_only_on_first_swap_of_timestamp`, `test_init_state`, invariant `invariant_anchor_only_on_first_swap` |
| 2 decay sign / monotone / clamp / no move on fail | `_checkDecay` on every first swap |
| 3 empty-range park, flash at P, dust, idle park | `test_park_through_empty_range_gate_fails`, `test_park_return_with_flash_liquidity_at_P`, `test_park_with_dust_moves_at_most_clamp_rate`, `test_idle_park_moves_at_most_clamp` |
| 4 crossing after an empty-range push | `test_crossing_after_empty_range_push_pays_same_as_from_anchor` |
| 5 split invariance | `test_split_invariance` (fuzz) |
| 6 same-timestamp JIT | `test_same_timestamp_jit_after_swap_collects_nothing` |
| 7 own-range redirect | `test_own_range_redirect_collects_nothing_of_victim` |
| 8 nothing lost, fee growth | `test_nothing_stranded_and_fee_growth_matches_twin` |
| 9 narrow JIT by the arb | `test_narrow_jit_pays_schedule_per_unit` |
| 10 toward fee, cap, exact-out | `test_toward_pays_max_poolFee_minFee`, `test_exact_out_follows_same_schedule`, cap check in `_checkCoreCalls` |
| 11 constructor ranges | `test_constructor_rejects_out_of_range`, `test_budget_lemma` |
| 12 gas table | `MEVCaptureV21Gas.t.sol` (below) |
| 13 flash L_ref inflation (CSO965 port) | `test_flash_lref_inflation_one_lock` |
| 14 reference decay 1/16, 1/1024 | `test_reference_decay_exit_to_one_sixteenth_reopens_after_one_tau` (120 s), `..._one_1024th_reopens_after_seven_tau` (840 s) |
| 15 segment loop | `test_toward_far_is_one_call`, `test_no_zero_length_segments_on_boundaries`, `test_merge_after_cap`, `test_sparse_pool_segments_until_cap`, `test_budget_lemma` |
| 16 checked sums | `test_large_amounts_never_wrap` (fuzz near 2^127) |
| 17–19 H1 | `test_h1_one_block_inflation`, `test_h1_sustained_inflation_{1,4,8,16}_tau`, `test_h1_honest_growth_never_fails`, invariant `invariant_reference_rises_at_most_one_bit_per_tau` |
| 20 G1 path assertions | (a) `_checkCoreCalls` asserts no `updatePosition` call from the handler on every swap; (b) `test_beforeSwap_reverts_for_every_locker`, `test_direct_core_swap_reverts` |
| 21 N1 fractional anchor | `test_n1_fractional_anchor_sliver`, vectors |
| 22 J1 event | every checked swap asserts `AnchorGateFailed` iff the gate failed; `test_j1_per_timestamp_parking_freezes_anchor_with_events` |
| fuzz | `test_differential_fuzz` (random fee, spacing, layouts with gaps, swaps, limits, minFee, time steps) |
| stateful | `MEVCaptureV21Invariant.t.sol` (24 runs × 500 calls of swaps, adds, removes, warps; all checked) |

## Reference models and vectors

- `test/extensions/mevcapture-v21/ref_model.py`: exact integer model written from the spec (bit-exact exp2 port).
- `test/extensions/mevcapture-v21/gen_vectors.py` regenerates `test/data/mevcapture-v21/{gateScenarios,anchorUpdates,schedules}.json`
  and fails unless the model agrees with the design models copied to `models/`: every `v23_gate_model.py` scenario (H1
  tests 1–3, G1, G2, G3.1, G3.2, J1) step by step (pass/fail and `lRefBits` identical, anchor within 1e-3 tick), and the
  `v21_attacks.py` segment boundaries (exact) and rates (within the 0.16 ceil).
- `MEVCaptureV21VectorsTest` checks the contract's internal rules against those files.
- `test/data/mevcapture-v21/swaps.json`: end-to-end swap vectors (pool layout, state before/after, every Core call with
  limit, minFee and remaining amount, deltas), rebuilt and compared on every test run by `MEVCaptureV21SwapVectorsTest`.
  Regenerate with `FOUNDRY_PROFILE=v21vectors WRITE_V21_VECTORS=true forge test --offline --mc MEVCaptureV21SwapVectorsTest`.

Vector groups for the quoter/indexer: segment schedule (`schedules.json`, 288 cases incl. J_LIN 64), fractional anchor
N1 (`schedules.json` anchors with a fractional part; `swaps.json` scenario `n1_fractional_anchor_decay`), decay
(`anchorUpdates.json`), gate and H1 (`gateScenarios.json`).

## Gas and bytecode

Identical toolchain: forge 1.8.3, solc 0.8.33, via-IR, optimizer 9 999 999 runs, EVM osaka (repo `foundry.toml`). Cold, isolated transactions through the Router; pool fee 0.30%, spacing 4096, liquidity ±400 spacings unless stated; first swap of a new timestamp unless stated. Source: `snapshots/MEVCaptureV21GasTest.json`. Call counts are away Core calls for v2.1 (from the reference model).

| scenario | v1 | v2.1 J_LIN 16 (calls) | v2.1 J_LIN 64 (calls) |
|---|---|---|---|
| exact-in, 1 away segment | 123,376 | 106,283 (1) | 106,283 (1) |
| exact-in, 3 away segments | 123,795 | 128,086 (3) | 128,086 (3) |
| exact-out, 3 away segments | 123,779 | 127,611 (3) | 127,611 (3) |
| exact-in, 16 away segments | 124,031 | 270,055 (16) | 270,055 (16) |
| exact-in to 64 spacings | 124,095 | 325,470 (21) | 801,255 (64) |
| exact-in to MAX_FEE, merged | 185,598 | 397,093 (22) | 905,909 (68) |
| sparse pool (liquidity only at 300–400 spacings) | 149,267 | 292,441 (22) | 688,879 (68) |
| first swap in timestamp, 1 segment | 99,958 | 105,194 | |
| later swap in same timestamp, 1 segment | 93,870 | 98,248 | |
| toward the anchor (4 spacings, 1 call) | 111,068 | 104,497 | |

Position hook (`Positions.deposit`):

| | no extension | v1 | v2.1 |
|---|---|---|---|
| first update in timestamp | 319,316 | 332,577 | 328,420 |
| later update in timestamp | 125,166 | 130,633 | 130,669 |

Marginal cost per extra away segment: about 10,921 gas (about 8.3k inside Core per call plus the extension's loop). `SEGMENT_EXP` = 2 (W = 4s) cuts the call count about 4× at a small economic cost (design §d).

Bytecode (same settings, `forge build --sizes`):

| contract | runtime (B) | initcode (B) |
|---|---|---|
| MEVCapture (v1) | 5,182 | 5,687 |
| MEVCaptureV21 | 12,256 | 13,592 |

## Spec observation for the CSO review (Q1)

With rev 5, a pass first decays the reference by `⌊(now − lRefTime)/τ⌋` bits and then raises it by at most one bit.
A pool whose swaps are at least τ apart therefore cannot raise its reference (from init it stays at ≤ 1 bit), and a
warmed reference decays by one bit per touch once touches are more than 2τ apart. On such pools the gate is always
lenient, so per-timestamp empty-range parking (J1) does not freeze the anchor but drags it at the clamp rate
(CLAMP·min(Δt, τ)/τ, the accepted ≤ CLAMP/τ residual), without the dust the residual table assumes. The design models
show the same (`v23_gate_model.Pool5` touched every 120 s stays at 1 bit; `gateScenarios.json` scenario
`quiet_pool_touched_every_tau`; `test_quiet_pool_reference_cannot_climb`). The Ethereum calibration pool 4494 averages
about one swap per 6 minutes (3τ). The implementation follows the spec as written; a possible fix, if the CSO wants one,
is to not decay on a pass whose observation is at or above the stored reference.
