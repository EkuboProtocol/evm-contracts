# Solar on next: initial compiler evaluation

These are the initial results at `a8caef9`, before the gas follow-up. See the
[follow-up](./solar-gas-followup.md) for the retained source refactor, rejected
assembly-removal experiments, and controlled mixed-compiler fixture results.

## Scope and recommendation

This is a development-only experiment on `next` revision
`6f40e4eb07c99dc1ffc25f28a3821b3afb1aea6a`, using Foundry 1.8.7,
standalone Solar 0.3.0 and solc 0.8.33. Production contract sources and deployment
scripts are unchanged from that revision. Default and release profiles retain
solc; the Solar workflow is manual-only.

Solar produces substantially smaller bytecode and improves most measured gas
cases, but it does not dominate solc: several long/sparse swaps regress. Do not
ship a production compiler switch on this evidence. Upstream also explicitly
[warns against production use](https://github.com/paradigmxyz/solar#features-and-goals).

## Correctness and test-harness refactors

The original next suite exposed two compiler-sensitive test-harness assumptions:

- The gate-vector test retained temporary JSON decoding allocations across all
  independent scenarios in one call frame. Solar exhausted its existing memory
  budget. Each scenario now uses a fresh call frame, preserving all assertions,
  the aggregate step-count check and the existing resource limits.
- The solvency handler read a selector beyond the length of empty revert data.
  Solar's memory contents there were not zero. It now handles empty data before
  reading the selector, preserving the handler's existing acceptance of EVM
  out-of-gas errors. A regression fails before this fix and passes afterward;
  unknown nonempty errors remain rejected.

The three vector tests pass with both compilers. With seed `0x2338`, the extended
solvency invariant passes **32 runs / 16,000 calls / zero reverts per compiler**.
Both full suites pass **1,111 tests across 110 suites**, with zero failures
and two pre-existing skips per compiler. All 91 production artifact ABI entry
sets (ignoring ordering) and method identifier maps agree across the earlier
completed gas builds; this is not proof of runtime equivalence.
Canonical-address tests are unchanged from next's existing policy.
The fresh-frame vector refactor increases solc gate-vector test-harness gas
from approximately 299M to 479M; it is a memory-bounding change, not a production
gas optimization.

## Gas and bytecode

The same 33 `MEVCaptureV21GasTest` cold Router/deposit fixtures were executed with
both compilers under Foundry 1.8.7, using the repository's optimizer and EVM
settings. Measurements went to separate scratch snapshot directories. Tracked
solc baselines were not rewritten.

- **24 cases improve; 9 regress** with Solar.
- Range: **3.65% lower** to **3.05% higher** gas.
- Equal-case arithmetic mean: 1.48% lower gas. This is not traffic-weighted and
  is not a prediction of aggregate user savings.
- Largest regression: J64 exact-in to maximum fee and merge,
  **904,642 -> 932,209 gas** (+3.05%).
- J16 first swap in timestamp: **105,278 -> 101,431 gas** (-3.65%).

| Contract | solc deployed bytes | Solar deployed bytes | Change |
| --- | ---: | ---: | ---: |
| Core | 18,840 | 12,294 | -34.75% |
| Router | 11,304 | 7,724 | -31.67% |
| MEVCapture | 5,182 | 2,427 | -53.16% |
| MEVCaptureV21 | 12,312 | 7,567 | -38.54% |

Bytecode size is not deployment gas. Compiler changes also change metadata,
initcode and deterministic addresses; smaller bytecode is not proof of semantic
or deployment-address compatibility.

## Build-time reproduction

After both full test jobs completed, three uncached 157-file source builds per
compiler ran serially with alternating compiler order:

| Compiler | Wall-clock seconds per build | Median |
| --- | --- | --- |
| solc 0.8.33 | 13.117, 12.845, 13.020 | 13.020s |
| Solar 0.3.0 | 0.212, 0.227, 0.239 | 0.227s |

Solar's median was **57.4 times faster** on this host. Each log confirms a real
157-file compilation. These are source-build timings, not full-suite build
timings or a broad multi-host benchmark; operating-system caches were not
flushed. Gas and bytecode results above were reproduced by the same serial run.
Use the committed comparison script on an otherwise idle host to reproduce:

```bash
# Put standalone Solar 0.3.0 before Foundry 1.8.7 on PATH.
python3 bin/compare-compilers.py --output /path/to/new-results-directory \
  --solc /absolute/path/to/solc-0.8.33
```

The script alternates compiler order, runs three uncached source builds each,
and captures raw timings, bytecode sizes and all 33 gas cases in `summary.json`.
Every Foundry build/test command is offline. Obtain compilers and submodules
before running it.

Solar reports Solidity language version 0.8.38 and warns about exact 0.8.33
pragmas. Foundry's progress label `Solar 0.8.33` is not its actual version.
The pinned standalone release is necessary: Foundry 1.8.7's bundled Solar
reports 0.2.0 and cannot compile this project.

## Remaining acceptance boundaries

No deployment, signing, funds movement, global toolchain replacement, automatic
CI switch or release compiler change is included. This evidence supports opt-in
development use, not a production compiler switch. Before any production switch,
rerun full-suite verification on the release revision, review workload-specific
gas regressions, establish compiler production readiness, and regenerate/review
deterministic deployment artifacts under the normal approval and production gates.
