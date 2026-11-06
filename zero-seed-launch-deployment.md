# Zero-seed launch deployment

This source is deployed on Robinhood Chain (chain ID **4663**) against canonical Core. Deployments of earlier revisions are unchanged and keep their own ABIs; never attach this ABI to another address.

## Deployed contracts

| | Extension | Periphery |
|---|---|---|
| Contract | `ZeroSeedLaunch` | `ZeroSeedLaunchPeriphery` |
| Address | `0x517621Ea1bf51F31826819b118fa4dfEb4D198D2` | `0x52378E3Cf26554bc83bBA4fa9ADe6d70Cfa23921` |
| Constructor | `(Core)` | `(Core, extension)` |
| CREATE2 salt | base + **301** | base |
| Deployment block | 106030313 | 106030346 |
| Transaction | `0x14d3b906d6da20a356abcff59aabf2149ba30e5a97a10f13b0f986c96db93443` | `0xee9ff4f4e51bafe33720e99090bb095846c966cf8366332387477f66d5c6d6cd` |
| Runtime bytes | 18,366 | 6,123 |
| Runtime keccak256 | `0xa66e365089d80b017edeb98237831260bf9e1b7d5f3965d42be5672de6b0d70e` | `0x171cccc4d1e60be2d8ad9ebb5bc43da0fbf49ba21b67a32cedbaf7ca474d8c55` |

Both contracts have exact creation and runtime matches on Sourcify: [extension](https://sourcify.dev/server/v2/contract/4663/0x517621Ea1bf51F31826819b118fa4dfEb4D198D2), [periphery](https://sourcify.dev/server/v2/contract/4663/0x52378E3Cf26554bc83bBA4fa9ADe6d70Cfa23921). Index launches from the extension deployment block.

## Inputs and deterministic identity

- Factory: `0x4e59b44847b379578588920cA78FbF26c0B4956C` (Arachnid deterministic deployer).
- Core: `0x00000000000014aA86C5d3c41765bb24e11bd701`.
- Base salt: `0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd`.
- Forge 1.8.3; solc **0.8.33+commit.64118f21**, via IR, optimizer **9,999,999** runs, **Osaka**, metadata bytecode hash **IPFS**. Locked dependencies from `foundry.lock`.

The extension's required address prefix is **0x51**, from before-initialize (1), before-swap (64) and before-update-position (16). Salt search uses the **init hash including Core constructor arguments**, not creationCode alone. Periphery constructor arguments include the extension, and its runtime hash resolves all LAUNCH immutable occurrences to that address. The compiled ABI is independent of those immutable values.

Both deployments are calls to the factory with `value = 0` and data = **32-byte salt ++ init code**, extension first. The extension constructor registers itself in Core; the periphery takes the extension as an immutable. Factory replay against existing code reverts.

## Reproduction

From a checkout of this source:

```sh
forge build --offline
python3 script/launch-stdjson.py . /path/to/solc-0.8.33 src/extensions/ZeroSeedLaunch.sol ZeroSeedLaunch packet
python3 script/launch-stdjson.py . /path/to/solc-0.8.33 src/ZeroSeedLaunchPeriphery.sol ZeroSeedLaunchPeriphery packet
python3 script/launch-stdjson.py . /path/to/solc-0.8.33 src/LaunchToken.sol LaunchToken packet
python3 script/launch-packet.py . packet
forge test --offline --match-test test_unsignedPacket_localFactory_runtimeAndGas
```

Standard-JSON recompilation reproduces Forge creation code, runtime template and metadata byte for byte for extension, periphery and launch token; immutable offsets are labelled from the compiler AST, not inferred from byte patterns. `launch-packet.py` writes the init code, factory calldata and expected resolved runtime for both contracts.

The rehearsal test installs the known factory runtime into the **local test EVM**, deploys canonical local Core, sends the exact factory salt/init-code shape, independently mines the callpoint salt in Solidity and checks both addresses, full resolved runtime hashes, Core registration and periphery.LAUNCH. It does not connect to a live chain. Raw execution gas is **3,765,720** for the extension and **1,268,287** for the periphery, excluding transaction intrinsic and calldata gas.

## Verifying the deployment

At one recorded block:

1. `eth_chainId == 4663`, and Core's **full runtime** equals the `Core` artifact.
2. The **full runtime bytes** at both addresses equal the `*.runtime.expected.hex` output, not just their lengths or hashes.
3. Core emitted `ExtensionRegistered` for the extension, and the registration slot `keccak256(abi.encode(extension, uint256(0)))` equals one.
4. `periphery.LAUNCH()` equals the extension; CORE, ACCOUNTANT and LAUNCH immutables match the compiler-labelled offsets.
5. `previewInstallation` reproduces the default range vector from `zero-seed-launch.md`: `-13815500 → -9210300` derives spacing 17990 and installs `-13798330 → -9210880`.
