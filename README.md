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

### Utility Contracts

- **`Incentives.sol`**: Enables efficiently delivering multiple airdrops
- **`RevenueBuybacks.sol`**: Uses DCA orders to push revenue into buybacks of a specific token
- **`PositionsOwner.sol`**: Permissionlessly transfers collected revenue from a Positions contract to the Revenue Buybacks contract
- **`TokenWrapper.sol`**: Vested token implementation that tightly integrates with Ekubo Protocol for cheaper swaps
- **`TokenWrapperFactory.sol`**: Factory for deploying the TokenWrapper contract

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
