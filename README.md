# Ekubo Protocol - EVM Contracts

[![License](https://img.shields.io/badge/License-Ekubo--License--V1-red.svg)](LICENSE)

This repository contains the core Solidity smart contracts for **Ekubo Protocol**, the most gas efficient and extensible automated market maker (AMM) for the Ethereum Virtual Machine.

## Overview

Ekubo Protocol is a suite of Smart Contracts providing comprehensive AMM infrastructure, including the following features:

- **Configurable pool types**: There are multiple ways to configure the base pool:
  - **Concentrated Liquidity**: Many positions provide liquidity within different price ranges and are efficiently aggregated
  - **Stableswap**: Many positions provide liquidity within the same price range
  - **Full range**: Many positions provide liquidity from the minimum to maximum price
- **Extensions**: Modular architecture enabling unique pool behavior through extensions
  - **TWAMM**: Time-Weighted Average Market Maker enabling on-chain dollar cost averaging
  - **Oracle**: Enables tracking historical prices for any token pair
  - **MEVCapture**: Collects additional fee revenue based on trading activity
  - **Ve33**: Voter-selected pool fees and single-token LP rewards
- **Flash Accounting**: All operations are settled only when necessary
- **NFT Positions**: Liquidity positions and DCA Orders are represented as non-fungible tokens

## Architecture

### Core Contract

This is the multi-chain ownerless and permissionless contract that enables all the functionality of Ekubo Protocol. Each pool has its own separate state in the singleton, but aggregation across pools is made efficient via flash accounting and extensive gas optimization.

- **[`Core.sol`](./src/Core.sol)**: The singleton contract that stores all the state for the AMM and holds all the tokens

### Stateful contracts

These contracts manage positions in the Ekubo Protocol Core contract

- **`Positions.sol`**: NFT-based liquidity position management
- **`Orders.sol`**: TWAMM order management as NFTs

### Base Contracts

These are useful for integrating or extending the functionality of Ekubo Protocol.

- **`BaseLocker.sol`**: Abstract base for contracts interacting with the flash accountant
- **`BaseExtension.sol`**: Contains default handlers for all the extension methods
- **`BaseNonfungibleToken.sol`**: Base NFT implementation with access control
- **`BasePositions.sol`**: Base NFT Positions contract implementation with abstract methods for determining the protocol fee to collect
- **`FlashAccountant.sol`**: Manages flash loans and token accounting
- **`ExposedStorage.sol`**: Provides access to internal storage for external queries

### Stateless Contracts

- **`Router.sol`**: High-level interface for swapping with multi-hop and splitting support
- **`MEVCaptureRouter.sol`**: Extension of the Router that also supports the MEV Capture pools

### Extensions

- **`extensions/Oracle.sol`**: Price oracle functionality
- **`extensions/TWAMM.sol`**: Time-Weighted Average Market Maker implementation
- **`extensions/MEVCapture.sol`**: MEV capture and redistribution mechanism
- **`extensions/Ve33.sol`**: ve(3,3)-style extension. See [user guide](./docs/ve33-user-guide.md) and [architecture notes](./docs/ve-integrated-extension.md).

### Utility Contracts

- **`Incentives.sol`**: Enables efficiently delivering multiple airdrops
- **`RevenueBuybacks.sol`**: Uses DCA orders to push revenue into buybacks of a specific token
- **`PositionsOwner.sol`**: Permissionlessly transfers collected revenue from a Positions contract to the Revenue Buybacks contract
- **`TokenWrapper.sol`**: Vested token implementation that tightly integrates with Ekubo Protocol for cheaper swaps
- **`TokenWrapperFactory.sol`**: Factory for deploying the TokenWrapper contract

## Solidity compilation on `next`

The experimental `solar` profile uses **Foundry v1.8.7** and standalone
**Solar v0.3.0** for development builds and tests:

```bash
FOUNDRY_PROFILE=solar forge build --offline
FOUNDRY_PROFILE=solar forge test --offline
```

Install Solar v0.3.0 from the [official release](https://github.com/paradigmxyz/solar/releases/tag/v0.3.0)
and put its binary **before Foundry's directory on `PATH`**. Foundry v1.8.7's
bundled Solar reports v0.2.0 and cannot compile this project's assembly. The
manually dispatched `Solar (next)` workflow pins and verifies the standalone
Linux binary. Run it against `next`; automatic branch checks are intentionally
not enabled while the compiler evaluation remains experimental.

The original `next` revision `6f40e4e` compiles with Solar, but its gate-vector
test exhausts memory and its solvency handler reads beyond empty revert data.
The Solar experiment splits independent vector scenarios into fresh call
frames and handles empty revert data explicitly. It retains all vector
assertions, invariant actions and resource limits; production contracts are
unchanged in the initial evaluation. The subsequent [gas follow-up](./solar-gas-followup.md)
refactors packed extension parameters without changing Core math, layouts or
interfaces. Do not exclude failing tests to claim migration readiness.
Solar reports Solidity language version 0.8.38 and warns about the project's
exact 0.8.33 pragmas; the Foundry progress label `Solar 0.8.33` is not the
actual compiler version.

Solar artifacts and cache live in `out/solar` and `cache/solar`. Its gas snapshot
checks and writes are disabled so experiments cannot replace the solc baselines.
Other profiles keep using solc 0.8.33, including release builds and deployment
scripts. Do not use the Solar profile for deployments: [upstream explicitly
warns against production use](https://github.com/paradigmxyz/solar#features-and-goals).
A successful compile alone does not establish runtime, gas, metadata or
deterministic deployment-address compatibility.

To compare compilers locally, stop other builds and run:

```bash
python3 bin/compare-compilers.py --output /path/to/new-results-directory \
  --solc /absolute/path/to/solc-0.8.33
```

This runs three uncached source builds per compiler, records deployed bytecode
sizes, and compares the same 33 cold Router/deposit gas fixtures. Logs, snapshots
and `summary.json` stay in the new results directory, not the tracked baselines.
Gas benefits are workload-dependent; inspect regressions as well as savings.
See the [compiler evaluation](./solar-evaluation.md) for results and release
boundaries.
Pass `--mixed-core` to also evaluate solc Core with Solar periphery in a
controlled test-only fixture. This is not a deployable mixed-compiler pipeline.
The [gas diff table](./solar-gas-diffs.md) lists all 33 before/after cases and the
broader whole-test increases for review.

## License

This project uses the **Ekubo DAO Shared Revenue License 1.0** (`ekubo-license-v1.eth`).

You can **use, modify, and build on** this code — as long as you **share 50% of any protocol revenue** from your deployed or derivative version (“Royalty Bearing Work”) with **Ekubo DAO** each quarter.

- Must include this license or the line:
  _“Licensed under the Ekubo DAO Shared Revenue License 1.0 at ekubo-license-v1.eth.”_
- Failing to pay or comply **automatically ends the license**.
- Ekubo DAO can update payment details or revenue definitions through governance.
- Software is provided **as-is**, with **no warranties**.

See the [full license](./LICENSE).

## Links

- **Website**: [ekubo.org](https://ekubo.org)
- **Documentation**: [docs.ekubo.org](https://docs.ekubo.org)
- **Discord**: [discord.ekubo.org](https://discord.ekubo.org)
- **Twitter**: [@EkuboProtocol](https://x.com/EkuboProtocol)
