# Solar gas follow-up

For line-by-line PR review, see [all 33 gas diffs](./solar-gas-diffs.md), including
before/after values for both compilers and the mixed-fixture comparison.

## What was more expensive?

The original all-Solar run at `a8caef9` used more **execution gas**, not more
compilation time, in these nine cold Router fixtures:

| Swap fixture | solc gas | Solar gas | Extra gas |
| --- | ---: | ---: | ---: |
| v1 to maximum fee and merge | 185,377 | 186,041 | 664 (0.36%) |
| v2.1 J16, 16 segments | 269,876 | 272,615 | 2,739 (1.01%) |
| v2.1 J16, 64 segments | 325,206 | 330,031 | 4,825 (1.48%) |
| v2.1 J16, maximum fee and merge | 396,608 | 405,731 | 9,123 (2.30%) |
| v2.1 J16, sparse pool | 292,318 | 295,348 | 3,030 (1.04%) |
| v2.1 J64, 16 segments | 269,876 | 272,615 | 2,739 (1.01%) |
| v2.1 J64, 64 segments | 800,260 | 822,199 | 21,939 (2.74%) |
| v2.1 J64, maximum fee and merge | 904,642 | 932,209 | 27,567 (3.05%) |
| v2.1 J64, sparse pool | 688,342 | 704,388 | 16,046 (2.33%) |

The cap/merge J64 trace makes 68 Core swap calls. Those calls consume 683,393
gas with Solar versus 644,731 with solc in aggregate; cheaper Solar periphery
offsets part of this difference. This localizes much of the difference to Core,
but is not an opcode-level diagnosis of the compiler.

## Refactor retained on the branch

The extension previously extracted direction and skip-ahead from packed swap
parameters, then reconstructed and revalidated the same fields for every
segment. It now preserves bits 16–31 directly while replacing the fee (0–15),
signed amount (32–159), and price limit (160–255) in ordinary Solidity.
The already-packed skip field cannot exceed 15 bits; this does not remove the
range check for callers constructing parameters from an arbitrary integer.
Signed amount, limit and fee casts retain the original field widths.

Against each compiler's original results, this refactor improves **17 fixtures
and ties 16**, with no regressions in this fixture set:

- Solar: 48 gas saved per segment call, up to **3,264 gas** saved.
- solc: 61 gas saved per segment call, up to **4,148 gas** saved.
- V2.1 deployed bytecode: Solar 7,567 → 7,549 bytes; solc 12,312 → 12,305 bytes.
- One trivial `isZero` assembly block is replaced with the equivalent typed
  Solidity comparison. It does not change these 33 gas measurements; see the
  broader snapshot caveat below rather than treating it as universally free.

`SolarRefactorTest` checks the packed Core calldata against the original
constructor for arbitrary parameters, signed amounts, limits and fees, and
checks the zero predicate. Existing vectors and invariants cover swap semantics.
Both full offline snapshots pass with seed `0x2338`: **1,113 passed, 0 failed,
2 pre-existing skips per compiler**, across 111 suites. The two retained-change
properties also pass 10,000 cases each under **both** compilers.
Core logic, rounding formulas, storage layouts, public ABIs, token settlement
and deployment scripts are unchanged by this refactor. Bytecode/CREATE2
addresses are still compiler- and source-dependent.

A broader comparison of 710 shared deterministic solc test-function snapshots
shows 44 improvements, 664 ties and **two increases**: the aggregate
`test_narrow_jit_pays_schedule_per_unit` test rises by 2,306 gas and
`test_unifiedFetcherQuotesAndBalances` rises by 6 gas. Those are whole-test
measurements including harness/reference/deployment work, not isolated user
transaction gas; their causes have not been isolated. They are disclosed rather
than excluded from an "everything cheaper" claim. Fuzz/invariant entries are
not included in that 710-case comparison.

## Can all of it be cheaper?

**All 33 measured cases can be cheaper than updated all-solc** in an experimental
composition: compile Core with solc and the periphery/extensions with Solar.
The controlled fixture saves **0.79%–3.05%** versus updated all-solc:

| J64 maximum-fee/merge case | Gas |
| --- | ---: |
| Original all-solc | 904,642 |
| Original all-Solar | 932,209 |
| Refactored all-solc | 900,494 |
| Refactored all-Solar | 928,945 |
| solc Core + Solar periphery | **891,291** |

This does **not** mean every possible workload is cheaper, or that the mixed
fixture dominates all-Solar: all-Solar remains cheaper on some short swaps.
Pure Solar still has nine regressions relative to solc on the same revision.

### Controls and limitations

- Each variant uses the same source, pool setup, fixture calls and cold isolated
  transactions. A separate pure-Solar derived fixture reproduces the ordinary
  Solar gas snapshots **exactly**, checking that the wrapper/configuration does
  not itself create a false saving.
- The local mixed fixture substitutes solc's Core runtime code with `vm.etch`
  before pool operations. Core has no immutables or linked references, and the
  two compiler artifacts have matching ABI entries and method selectors. The
  ordinary constructor's initial state is retained.
- This is a **test-only composition**, not a deployable mixed-compiler pipeline,
  full-suite mixed-compiler equivalence proof, or deployment-gas measurement.
- An initial derived fixture omitted its own isolation annotation; those warm
  measurements were invalid and discarded. The controlled results above have
  explicit isolation on both derived fixtures and the exact-match control.

Reproduce the controlled experiment with pinned tools and a fresh output path:

```bash
python3 bin/compare-compilers.py --mixed-core \
  --solc /absolute/path/to/solc-0.8.33 --output /new/scratch/results
```

The script records both single-compiler results, mixed results, the generated
fixture/config and logs. It refuses to compare if the pure-Solar control does
not match or Core's interface/immutable assumptions stop holding. It does not
change release profiles or deployment scripts.
The portable `--mixed-core` command was run end to end and reproduced all 33
mixed results and the exact pure-Solar control match. Its one-build-per-compiler
validation run does not replace the initial three-run compile-time benchmark.

## Why not remove all assembly?

Measured experiments, not a blanket style rule, decided what stayed:

- Plain Solidity min/max increased Solar gas, up to 2,490 gas in the J64 cap case.
- Branching tick normalization saved gas on some paths but raised toward-anchor
  swaps by 36 gas under Solar.
- A larger conversion/Core-check rewrite removed more assembly and saved Solar
  gas, but raised solc gas in most fixtures (up to 1,420 gas). It was reverted.

Deleting assembly alone is not a gas optimization. The branch keeps the
measured, encoding-preserving improvement and removes only a trivial assembly
block. It does not rewrite protocol math or relax checks for dust gains.

## Release boundary

Nothing is deployed or switched in production. Solar upstream still warns
against production use. The mixed result is evidence for further development
evaluation, not permission to deploy or claim compiler equivalence. A release
would need its own artifact pipeline, broader mixed-runtime verification,
deterministic-address review, and the existing release/security approval gates.
