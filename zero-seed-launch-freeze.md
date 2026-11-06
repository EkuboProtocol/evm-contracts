# Final-source verification report

Verification of the final launch source. Canonical interface: `zero-seed-launch.md`; machine ABI/errors/topics: `test/vectors/zero-seed-launch.json`; event bytes: `test/vectors/zero-seed-launch-events.json`; deployed addresses: `zero-seed-launch-deployment.md`.

## Baseline and tools

Compared with the previous revision `3d6378f585591dc7eabeea6976932c30524bb8ea`, built separately. Baseline launch tests: 92/92 passing. Both builds use Forge 1.8.3, solc 0.8.33, via IR, 9,999,999 optimizer runs, Osaka, IPFS metadata and locked submodule revisions. Compiler-derived standard-JSON inputs reproduce creation code, runtime templates and metadata byte for byte for extension, periphery and token.

## Verification

- `forge fmt --check` and `forge build --offline`.
- Full `forge test --offline`: 1,290 passing across 127 suites before the final additions; final `forge snapshot --offline` includes the access, complete-event and local-factory deployment regressions (1,293 tests).
- Final launch-focused tests: **101/101** across 20 suites. Existing native/ERC20, 6-decimal quote, claims/ownership, hostile/shared-quote, nested-payment, maximum-fee and accounting regressions are retained.
- Nine focused fuzz tests at **10,000 runs each**, including arbitrary canonical metadata, signed range alignment, maximal installation, fee signs/conservation, supply conservation and fee-curve properties: all pass.
- Installation oracle: **293,547** checks on 64 deterministic rows and 20,000 full-domain pseudo-random cases, including exact accepted supply envelopes and first refusals.
- Independent fee/Decimal, liquidity, residue and expiry oracle: **55,253** checks.
- Empty/nonempty-logo creation has identical installation and extension write-set; emitted topics/data decode to all requested fields plus final logo string. Canonical metadata includes 31-byte, multibyte, arbitrary-byte and embedded-zero round trips; zero/overlength/dirty-tail words fail explicitly. Supply zero, cap, cap+1 and uint128 maximum are covered in preview and create.

All executions are local fixtures against the compiled Core. Machine numbers are exact integers or decimal strings.

## Measured gas versus pinned source

The ordinary fixture now derives spacing 17,990 and aligns its bounds inward; baseline used spacing 100 at the requested bounds. These are **end-to-end revision comparisons**, not controlled claims that a single arithmetic change caused every delta. Same harness, compiler/settings and nominal supply/fees/quote, both orders.

| In-test operation | Baseline token0 | Current token0 | Baseline native token1 | Current native token1 |
|---|---:|---:|---:|---:|
| create via periphery | 1,368,087 | 1,145,023 | 1,326,935 | 1,104,007 |
| first buy after create | 102,485 | 102,296 | 84,663 | 84,187 |
| subsequent warm buy | 34,267 | 34,078 | 35,163 | 34,686 |
| sell | 34,271 | 34,167 | 38,609 | 38,502 |
| claim | 70,154 | 70,066 | 79,676 | 79,588 |

`ZeroSeedLaunchAccessTest` runs unchanged on both source revisions. It probes each call, restores its input state, explicitly cools or warms touched persistent slots/accounts, and measures an actual forwarded buy or periphery claim. Warm versus cold values here use **identical pre-state** (including zero-to-nonzero writes), unlike the subsequent-warm-buy line above.

| Identical-state call | Baseline cold / warm | Current cold / warm | Core distinct read slots baseline → current |
|---|---:|---:|---:|
| token0 buy | 116,180 / 99,680 | 117,991 / 99,491 | 5 → 6 |
| native token1 buy | 104,358 / 81,858 | 105,882 / 81,382 | 13 → 14 |
| token0 claim | 50,253 / 42,253 | 50,179 / 42,179 | 3 → 3 |
| native token1 claim | 50,318 / 42,318 | 50,244 / 42,244 | 3 → 3 |

The new skip-ahead eagerly reads one additional bitmap word on this fixture, costing an extra cold SLOAD: cold buys regress **1,811 / 1,524 gas**, while warm calls improve **189 / 476 gas**. This is intentional to bound worst-case full-width traversal; no universal swap-gas saving is claimed. Distinct recorded read slots are **not counts of executed SLOAD instructions** and may include read-modify-writes. Extension buy reads remain two Launch slots; claim reads one; periphery claim reads one owner slot. Launch layout remains two slots; no storage-slot saving is claimed from removal of spacing input or retention of decay rate.

Full-domain cap-supply actual Core/router sweeps, cold reads restored and cooled: token0 buy **101,143**, reverse sell **104,735**; native token1 buy **98,816**, reverse sell **105,307** gas. Every call fits a 1.9M execution cap plus a conservative 100k overhead allowance (**2M** budget). Buys assert exact arrival at the installed upper economic bound. The purchased inventory is then sold back. Geometry fuzzing proves at most two adjacent bitmap words for all valid input ranges, both orders. This does not promise one-transaction fills for arbitrarily large quote amounts or every fee choice.

The local-factory deployment rehearsal independently mines the same salt, deploys the exact pair in the test EVM, and verifies full resolved runtime hashes, registration and LAUNCH. Measured direct execution: extension **3,765,720**, periphery **1,268,287** gas, before transaction intrinsic/calldata or chain data-gas overhead.

## Bytecode and storage

| Contract | Baseline creation / runtime bytes | Current creation / runtime bytes |
|---|---:|---:|
| extension | 20,184 / 19,694 | 18,884 / 18,366 |
| periphery | 5,754 / 5,534 | 6,343 / 6,123 |
| launch token | MintableERC20 4,419 / 3,949 | LaunchToken 3,172 / 3,012 |

The periphery grows to carry the dynamic logo and expanded preview. Creation drops roughly 223k gas, primarily from smaller token deployment and removed ownership initialization/renunciation plus metadata-storage work. Extension metadata and logo occupy no persistent slots; token name, symbol and deploying extension are immutable runtime values. ERC20 supply/balances/allowances/nonces remain in Solady custom storage; compiler layout alone does not enumerate assembly-derived Solady slots. Extension `_launches` and periphery `launchOwner` each remain mapping slot zero in their own contracts. Compiler storage layouts are reproducible from the standard-JSON inputs.

Runtime template hashes (zero immutable placeholders) and creationCode hashes are machine-pinned in the vectors. **They are not CREATE2 init-code hashes**: constructor arguments must be appended first. Deployed runtime hashes resolve compiler-identified immutables at the deployment addresses, rather than copying fixture-address runtime hashes.

## Security status and preserved limitations

This report covers the tests and oracles above; it is not an independent audit. An arbitrary ERC20 quote remains a **token-wide untrusted-quote risk**, not pair-local isolation. Installation keeps the exact inverse-liquidity calculation; both earlier quantization counterexamples and the full-domain maximality regressions are retained. Shared Core code is unchanged.

Canonical metadata and all narrowing/unchecked range arithmetic have explicit preconditions and fuzz coverage. The token mint has no callback and is closed after the extension's positive-supply mint. Claim ordering preserves composable reentrancy without a blanket guard. Permit2's inherited infinite allowance remains disclosed: signatures can transfer tokens without a separate token approval. Arbitrary quote tokens and logo URLs remain untrusted. Indefinitely delayed starts and amount-dependent gross-up failures remain explicit behaviors, not newly fixed findings.

The exact supply envelope is `debit(1) .. min(1e30, debit(tickCap+1)-1)` for each order and aligned geometry; it may be empty. The independent oracle emits it for every valid geometry, including refusals. No unsupported geometry is silently clipped into the liquidity cap.

Any source change produces new bytecode and needs a new deployment; deployments of earlier revisions are unaffected.
