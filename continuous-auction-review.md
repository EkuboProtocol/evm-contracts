# ContinuousAuction launch review

Status: launch candidate ready for user review. Local validation and both V12
reviews are complete. No live deployment has been made.

## Scope

- `src/extensions/ContinuousAuction.sol`
- `src/AuctionPositions.sol`
- Deployment tooling: `script/DeployContinuousAuction.s.sol`
- Base repository revision: `1f5be49e544052fb7b742345d5d17e09d718d5c8`

The immutable bid asset is configurable; address zero selects native currency.
LP position NFTs retain their earned rent after liquidity removal. Metadata
ownership does not grant access to other users' fees.

## External review ledger

| Review | Scope | Fixed cost | Status |
| --- | --- | ---: | --- |
| [V12 8386](https://v12.sh/runs/8386) | Two production contracts, optimized v1 | $15.70 | Completed; locally reviewed |
| [V12 8387](https://v12.sh/runs/8387) | Two production contracts, hardened v2 | $16.02 | Completed; all 11 findings rejected and locally reviewed |

Budget target: less than $100 total. Final audit spend: **$31.72**.
V12 receives production Solidity source with the new contracts explicitly scoped;
existing protocol source is available as context. Analysis-only mode is used;
finding reproduction and remediation are performed locally.

The first upload (zip 5470) reviewed these SHA-256 source hashes:

```text
eaffba17ba1bb44b866a122935296bbf255c7e22935d8e31e54a5a38b4308ccc  src/extensions/ContinuousAuction.sol
734d4ebd7bb768ffdfa20774d0cfb66d7b1a6e45d8576193367e8d5e53db687c  src/AuctionPositions.sol
```

Subsequent changes require follow-up review; this first snapshot is not the final candidate.

The second upload (zip 5471) includes the funding fix, empty-liquidity accounting,
and tick-cell gas optimization. Its source hashes are:

```text
e836b837e06fc5d87bb7979b383e88625dc8abf32b470c4099471045f576c5b3  src/extensions/ContinuousAuction.sol
734d4ebd7bb768ffdfa20774d0cfb66d7b1a6e45d8576193367e8d5e53db687c  src/AuctionPositions.sol
```

## Hardening changes

1. Native overfunding becomes refundable credit. Previously a transaction delayed
   after funding calculation reverted because the exact required value changed.
   `test_nativeFundingSurvivesInclusionDelay` reproduced the failure before the fix.
2. Empty-liquidity rent remains charged and is permanently accounted separately.
   It is neither refunded to the executor nor allocated to later depositors.
   `test_emptyRangeDoesNotLetExecutorAvoidRent` exercises an executor moving out
   of all liquidity and back again.
3. Reentrancy checks cover auction funding, forwarding, LP updates, claims, and
   refund withdrawal, using transient storage. Claims use checks-effects-interactions.
4. Actual received ERC20 funding is checked; transfer-tax funding reverts atomically.
5. Checked bid bounds protect packed 48-bit timestamps, 64-bit block numbers,
   and segment identifiers. Rates are uint96; the TWAMM horizon bounds each
   inter-settlement rent total below 2**128.

## Gas work

- Segment storage reduced from five slots to three, auction state from three to two.
- Incumbent replacement only creates a tail if it survives. Fully displaced
  temporary tails are no longer written and immediately deleted.
- Price validation precedes schedule writes.
- Q128 rent-growth computation uses the proven uint128 rent bound.
- Position updates avoid duplicate reward snapshots unless tick initialization
  changes the reward coordinate system.
- Tick movement within one spacing cell skips the external initialized-tick scan;
  biased floor division handles negative ticks and the zero boundary correctly.

Cold-call gas before this work and for candidate v2:

| Operation | Baseline | Candidate v2 | Reduction |
| --- | ---: | ---: | ---: |
| Initial bid | 173,544 | 130,362 | 24.88% |
| Pending replacement | 193,145 | 145,342 | 24.75% |
| Active replacement with surviving tail | 335,373 | 244,149 | 27.20% |
| Active replacement covering old end | 255,048 | 175,111 | 31.34% |
| Swap with rent accrual | 130,473 | 126,308 | 3.19% |
| Position rent claim | 102,091 | 97,913 | 4.09% |
| Refund withdrawal | 33,232 | 33,254 | -0.07% |

Measurements are recorded in `snapshots/ContinuousAuctionTest.json`. Maximal TWAMM
endpoint schedules cost 1,191,665 gas for expiry and 1,739,926 for replacement;
tests also assert pre-refund execution gas below Lighter's documented 4,250,000
target block gas. Runtime sizes are 12,472 bytes for ContinuousAuction and 22,937
bytes for AuctionPositions, both below 24,576 bytes.

## Validation coverage

Tests cover native/ERC20 funding, rate and expiry validation, same-block exclusion,
incumbent prefix preservation, nested refunds and resuming tails, ownership and
operator authorization, NFT transfers, full withdrawal, late liquidity, boundary
deletion/reinitialization, both directions across tick zero, empty liquidity,
failed payouts, callback reentrancy, maximum rates, timestamps beyond uint32,
CREATE2 prefix mining, deployment reuse, and runtime bytecode size limits.

Independent per-second reference models check bid schedule/refund accounting and
funding conservation, including liquidity gaps. Conservation distinguishes earned
LP rent, irrevocably unallocated rent, displaced refunds, and remaining funding.

Candidate v2 passed 34 auction/deployment tests, including 2,048 runs each of three
fuzz tests. One additional callback regression test was then added, and both
deployment tests pass, bringing the auction/deployment coverage to 35 tests.
The complete regression run has 1,094 passes and four failures in
`ExposedStorageTest`. All four were reproduced on an exported clean copy of the
base revision with the same seed
`0x40d6f0e8c5dcbd282e94162b08ef7d822c4e9f78d2138fcfeed586129d5f18db`.
They concern transient-storage reads and are not caused by the auction changes.

Formatting passes for all five new Solidity files; `git diff --check` passes.
The whole-tree formatter reports existing differences in unrelated source/tests.

## V12 8386 finding review

All 10 published findings were enumerated without severity or validity filters,
and complete evidence plus current review state was read for each. V12 classified
one high as unreviewed and nine lows as invalid. No V12 review controls or shared
notes were changed; the assessments below are local review conclusions.

| Finding UID | V12 severity / disposition | Local assessment |
| --- | --- | --- |
| [291869](https://v12.sh/runs/8386/291869) | High / unreviewed | Disproved: `and(shr(bit, extension), iszero(...))` is a bitwise mask with 0 or 1, not a logical nonzero test. The `0x51` address prefix enables precisely the three declared callbacks. |
| [291867](https://v12.sh/runs/8386/291867) | Low / invalid | Deployment configuration, not a post-deployment attack. The new deployment script checks Core code existence and deploys/registers the extension with that Core. |
| [291868](https://v12.sh/runs/8386/291868) | Low / invalid | Deployment configuration. The script constructs the manager from the just-deployed auction and the same Core; the integration test exercises that binding. |
| [291871](https://v12.sh/runs/8386/291871) | Low / invalid | Caller-selected refund recipient affects only the caller's balance. No third-party authorization bypass. |
| [291874](https://v12.sh/runs/8386/291874) | Low / invalid | Schedule length is bounded by the TWAMM grid, with at most one incumbent prefix. Maximal schedule tests exercise expiry and replacement below the target gas bound. |
| [291875](https://v12.sh/runs/8386/291875) | Low / invalid | Modular growth subtraction correctly handles a boundary crossing. A whole uncheckpointed growth cycle needs at least roughly 136 years at maximum rate and minimum liquidity. |
| [291876](https://v12.sh/runs/8386/291876) | Low / invalid | Same accumulator-cycle concern as 291875; no realistic new attack path. |
| [291881](https://v12.sh/runs/8386/291881) | Low / invalid | Inherited NFT lifecycle: an authorized burn does not settle positions; deterministic remint by the original minter is explicitly supported. Withdraw and collect all value before burning. This behavior is real, although V12 lacked the ERC721 dependency needed to prove it. |
| [291882](https://v12.sh/runs/8386/291882) | Low / invalid | Unsupported bid-asset semantics. Deployment requires native currency or a standard, non-rebasing token with reliable transfers; mutable confiscation/taxes are outside that assumption. |
| [291883](https://v12.sh/runs/8386/291883) | Low / invalid | Integer rounding dust is real and documented. Global settlement loses less than one base unit per nonzero-liquidity accrual; each position checkpoint also rounds down. No sweep or redistribution is promised. |

For 291869, `test_audit291869_callbackBitsAreIndividuallyMasked` asserts all eight
callback predicates for the exact `0x51` prefix. The deployment integration test
also initializes a pool, deposits, collects Core fees, and fully withdraws without
any unsupported callback firing. Both tests pass. The tested Core, call-point
types, callback library, and BaseExtension sources were byte-compared with zip
5470 and are identical. No production change is appropriate for this false positive.

Local review: 10 assessed, 0 actionable defects, 0 unresolved assessments.
Remote state reconciliation: targeted 10 = updated 0 + unchanged 10 + unresolved 0 + blocked 0.
The high remains **unreviewed in V12**, with its local rebuttal above.

The local Solady ERC721 `_mint`/`_burn` code and `FixedPointMathLib.fullMulDivN`
were also inspected to resolve the dependency gaps behind 291881 and 291883.
Burn/remint and floor rounding behave as documented; their V12 rejection is not
being relied on as evidence that those behaviors are absent.

## V12 8387 final-candidate finding review

The complete unfiltered worklist contains 11 low-severity findings, all marked
invalid by V12; no critical, high, medium, info, QA, or unclassified findings were
published. Complete evidence and all source locations were reviewed for every
finding. The final production files match uploaded snapshot 5471 byte-for-byte.

| Finding UID | Local assessment of V12's rejected finding |
| --- | --- |
| [291907](https://v12.sh/runs/8387/291907) | Core identity is a deployment input. Code existence and constructor registration are checked; the operator must select the intended Core. No mutable authority substitution exists. |
| [291908](https://v12.sh/runs/8387/291908) | Deployment script passes its own newly deployed auction to the manager. Invalid manually selected constructor endpoints are deployment errors. |
| [291910](https://v12.sh/runs/8387/291910) | Callback-controlled/minting/rebasing bid tokens are outside the supported standard-token model. Funding and claim entry points are reentrancy guarded. |
| [291911](https://v12.sh/runs/8387/291911) | Timestamp narrowing at 2**48 seconds is an approximately 8.9-million-year lifecycle boundary, not a practical launch defect. |
| [291917](https://v12.sh/runs/8387/291917) | The alleged gap cannot be constructed: linked intervals are contiguous, so a successor of a head ending at activation also begins at activation. Reference-model fuzzing verifies schedule behavior. |
| [291920](https://v12.sh/runs/8387/291920) | Authorized NFT burning without settlement is inherited behavior; principal and rent must be collected first. Solady source confirms the behavior despite V12's dependency-evidence gap. Documentation explicitly explains remint/recovery limitations. |
| [291923](https://v12.sh/runs/8387/291923) | Outbound-tax tokens are unsupported. Exact inbound balance checks do not certify future outbound token behavior; standard-transfer semantics are an explicit deployment assumption. |
| [291924](https://v12.sh/runs/8387/291924) | Negative-rebasing/confiscatable balances are unsupported; nominal liabilities require a balance-stable bid asset. |
| [291925](https://v12.sh/runs/8387/291925) | Floor rounding is real and documented as retained dust. Local fullMulDivN inspection resolves the external-dependency evidence gap; no claim of exact fractional-rent distribution is made. |
| [291926](https://v12.sh/runs/8387/291926) | Modular accumulator boundary crossings are sound; loss requires a full uncheckpointed cycle, beyond the realistic funded-rate/time domain. |
| [291927](https://v12.sh/runs/8387/291927) | Script supplies the same Core to extension and manager. Both bindings are immutable, and end-to-end deployment/LP-operation tests pass. |

No additional production patch was required by either completed report. V12's
missing dependency evidence was supplemented by local source review rather than
treated as proof of safety. No server-side triage changes were requested or made.

Final-candidate reconciliation: targeted 11 = updated 0 + unchanged 11 + unresolved 0 + blocked 0.
Across both reports: targeted 21 = updated 0 + unchanged 21 + unresolved 0 + blocked 0.

## Reproduction commands

This environment uses the SHA-256-verified official Solidity 0.8.33 executable at
`/tmp/opencode/solc-0.8.33` because the compiler was not initially cached by Foundry.

```bash
forge test --offline --use /tmp/opencode/solc-0.8.33 \
  --match-contract 'ContinuousAuction(Test|DeploymentTest)' --fuzz-runs 2048
forge test --offline --use /tmp/opencode/solc-0.8.33 \
  --match-contract ContinuousAuctionTest --match-test test_gas
forge test --offline --use /tmp/opencode/solc-0.8.33 --summary
forge fmt --check src/extensions/ContinuousAuction.sol src/AuctionPositions.sol \
  script/DeployContinuousAuction.s.sol test/extensions/ContinuousAuction.t.sol \
  test/ContinuousAuctionDeployment.t.sol
git diff --check
```

Local validation artifacts are under `/tmp/opencode/auction-launch/`, including
`extended-tests.json`, `full-regression.txt`, both immutable source zips/hashes,
and pre-optimization code/gas baselines. Unrelated gas snapshots regenerated by
the full regression run were backed up there and restored to their original state.

## Economic assumptions

See `continuous-auction.md`: rent rewards active liquidity over time. A holder
may also be an LP and recapture its share. This is not an oracle, a guaranteed
LP yield, a historical-LP compensation mechanism, or an atomic Lighter hedge.
Empty-liquidity rent and rounding dust remain in the extension without an admin
sweep. Bids activate at timestamp+1 and require a later block; skipped-block time
is still charged. Those are explicit mechanism choices for reviewer consideration.
