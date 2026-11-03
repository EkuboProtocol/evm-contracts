# Compiler gas diffs

All numbers are gas units from the same 33 cold, isolated Router/deposit fixtures
in `MEVCaptureV21GasTest`, using Foundry 1.8.7, solc 0.8.33 and standalone Solar
0.3.0. Before is `a8caef9`; after is `581d965` (the packed-parameter refactor).
The final column compares **after Solar minus after solc**: positive means Solar
costs more. Neither compiler's tracked production gas baseline was overwritten.

**Mixed is test-only:** solc Core runtime substituted into a Solar fixture, not
a deployable migration. Its separate pure-Solar control matches the ordinary
Solar measurements exactly. It beats after-solc in these 33 cases, but does not
beat all-Solar on every case and is not evidence for every possible workload.

| Fixture | solc before → after | Solar before → after | Mixed fixture | Solar − solc after |
| --- | ---: | ---: | ---: | ---: |
| no extension deposit, first position update in timestamp | 319,316 → 319,316 | 315,233 → 315,233 | 316,781 | -4,083 |
| no extension deposit, later position update in timestamp | 125,166 → 125,166 | 121,255 → 121,255 | 122,631 | -3,911 |
| v1 deposit, first position update in timestamp | 332,577 → 332,577 | 327,755 → 327,755 | 329,728 | -4,822 |
| v1 deposit, later position update in timestamp | 130,633 → 130,633 | 126,522 → 126,522 | 127,895 | -4,111 |
| v1 exact-in 1 away segment | 123,359 → 123,359 | 120,323 → 120,323 | 120,865 | -3,036 |
| v1 exact-in 16 away segments | 124,014 → 124,014 | 120,813 → 120,813 | 121,520 | -3,201 |
| v1 exact-in 3 away segments | 123,778 → 123,778 | 120,616 → 120,616 | 121,284 | -3,162 |
| v1 exact-in 64 away segments (J16: 16 + 6 doubling) | 124,078 → 124,078 | 120,841 → 120,841 | 121,584 | -3,237 |
| v1 exact-in to MAX_FEE and merge | 185,377 → 185,377 | 186,041 → 186,041 | 182,883 | +664 |
| v1 exact-in toward the anchor (4 spacings) | 111,051 → 111,051 | 107,384 → 107,384 | 108,368 | -3,667 |
| v1 exact-out 3 away segments | 123,754 → 123,754 | 120,404 → 120,404 | 121,215 | -3,350 |
| v1 first swap in timestamp (1 segment) | 99,949 → 99,949 | 97,001 → 97,001 | 97,730 | -2,948 |
| v1 later swap in timestamp (1 segment) | 93,861 → 93,861 | 91,095 → 91,095 | 91,705 | -2,766 |
| v1 sparse pool exact-in to far liquidity | 149,240 → 149,240 | 146,256 → 146,256 | 146,746 | -2,984 |
| v2.1 J16 deposit, first position update in timestamp | 328,420 → 328,420 | 323,996 → 323,996 | 325,648 | -4,424 |
| v2.1 J16 deposit, later position update in timestamp | 130,669 → 130,669 | 126,525 → 126,525 | 127,898 | -4,144 |
| v2.1 J16 exact-in 1 away segment | 106,359 → 106,298 | 102,772 → 102,724 | 103,191 | -3,574 |
| v2.1 J16 exact-in 16 away segments | 269,876 → 268,900 | 272,615 → 271,847 | 264,597 | +2,947 |
| v2.1 J16 exact-in 3 away segments | 128,128 → 127,945 | 125,317 → 125,173 | 124,688 | -2,772 |
| v2.1 J16 exact-in 64 away segments (J16: 16 + 6 doubling) | 325,206 → 323,925 | 330,031 → 329,023 | 319,220 | +5,098 |
| v2.1 J16 exact-in to MAX_FEE and merge | 396,608 → 395,266 | 405,731 → 404,675 | 390,471 | +9,409 |
| v2.1 J16 exact-in toward the anchor (4 spacings) | 104,573 → 104,512 | 100,919 → 100,871 | 101,322 | -3,641 |
| v2.1 J16 exact-out 3 away segments | 127,653 → 127,470 | 124,402 → 124,258 | 124,217 | -3,212 |
| v2.1 J16 first swap in timestamp (1 segment) | 105,278 → 105,217 | 101,431 → 101,383 | 102,120 | -3,834 |
| v2.1 J16 later swap in timestamp (1 segment) | 98,239 → 98,178 | 95,198 → 95,150 | 95,887 | -3,028 |
| v2.1 J16 sparse pool exact-in to far liquidity | 292,318 → 290,976 | 295,348 → 294,292 | 286,214 | +3,316 |
| v2.1 J64 exact-in 1 away segment | 106,359 → 106,298 | 102,772 → 102,724 | 103,191 | -3,574 |
| v2.1 J64 exact-in 16 away segments | 269,876 → 268,900 | 272,615 → 271,847 | 264,597 | +2,947 |
| v2.1 J64 exact-in 3 away segments | 128,128 → 127,945 | 125,317 → 125,173 | 124,688 | -2,772 |
| v2.1 J64 exact-in 64 away segments (J16: 16 + 6 doubling) | 800,260 → 796,356 | 822,199 → 819,127 | 787,463 | +22,771 |
| v2.1 J64 exact-in to MAX_FEE and merge | 904,642 → 900,494 | 932,209 → 928,945 | 891,291 | +28,451 |
| v2.1 J64 exact-out 3 away segments | 127,653 → 127,470 | 124,402 → 124,258 | 124,217 | -3,212 |
| v2.1 J64 sparse pool exact-in to far liquidity | 688,342 → 684,194 | 704,388 → 701,124 | 675,024 | +16,930 |

## Broader whole-test snapshot caveat

Among 710 shared deterministic solc test-function snapshots: 44 improved, 664
tied, and two increased. These whole tests include harness/reference/deployment
work; they are not isolated user calls, and their causes have not been isolated.

| Whole test | Before | After | Increase |
| --- | ---: | ---: | ---: |
| `MEVCaptureV21Test:test_narrow_jit_pays_schedule_per_unit()` | 1,887,024 | 1,889,330 | +2,306 |
| `FreeLPTest:test_unifiedFetcherQuotesAndBalances()` | 918,494 | 918,500 | +6 |

See [methodology and limitations](./solar-gas-followup.md) and reproduce with:

```bash
python3 bin/compare-compilers.py --mixed-core \
  --solc /absolute/path/to/solc-0.8.33 --output /new/scratch/results
```

The opt-in Solar profile does not change release compilation. Production use,
deployment addresses and a deployable mixed-compiler pipeline are not approved
by these measurements.
