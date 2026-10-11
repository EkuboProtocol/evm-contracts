# Local plain-WETH fixture

`weth9-0x4200-base-52449112.hex` is the 2,041-byte runtime read from
Base WETH `0x4200000000000000000000000000000000000006` at block 52,449,112.
Keccak: `0x8a3a1f6a9f9dce633117adee5b458245835a8645a8c8726a26382a4622508b1c`.

`weth9-source.txt` is the unmodified GPL-3.0-or-later source (including license)
from ethereum-optimism/optimism commit
`5877ee24cc9aaef5848c1372e0e196707fb336a0`, path
`packages/contracts-bedrock/src/vendor/WETH9.sol`.
It is outside Foundry's Solidity compilation paths because its compiler is 0.5.17.

Reproduce with solc `0.5.17+commit.d19bba13`:

```sh
solc-0.5.17 --standard-json < test/fixtures/weth9-build-input.json > weth9-output.json
```

Optimizer enabled, 10,000 runs. The resulting runtime's executable bytes are
identical to the fixture after removing each runtime's final CBOR metadata
(`last two bytes interpreted as a big-endian length, plus two`). The complete
runtime is **not** identical: source-path/build metadata differs. This proves
the local source/executable correspondence, not the original deployment build
metadata or live release provenance. Compiler binary SHA-256 and comparison
details are recorded in the correction packet's `weth9-source-reproduction.json`.

Tests etch this runtime at synthetic high/low quote addresses to force both
token orders, populate metadata slots 0–2 as in `ZeroSeedLaunch.t.sol`, and fund
the test by an actual local WETH deposit. There is no fork, live deployment,
credential use, real issuance or remote signing. The 6-decimal quote tests use
a separate plain synthetic token only for arithmetic coverage.
