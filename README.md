# Ekubo Protocol - Solidity Contracts

[![License](https://img.shields.io/badge/License-Ekubo--DAO--SRL--1.0-blue.svg)](LICENSE)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)

This repository contains the core Solidity smart contracts for **Ekubo Protocol**, a next-generation automated market maker (AMM).

## Overview

Ekubo Protocol is a comprehensive DeFi infrastructure that provides:

- **Concentrated Liquidity**: Efficient capital utilization through concentrated liquidity positions
- **Multiple Pool Configurations**: Support for pools with different fee tiers and tick spacings
- **Extension System**: Modular architecture allowing custom pool behaviors through extensions
- **TWAMM Integration**: Time-Weighted Average Market Maker for large order execution
- **Flash Loans**: Built-in flash loan functionality for arbitrage and liquidations
- **NFT Positions**: Liquidity positions represented as non-fungible tokens

## Architecture

### Core Contracts

- **`Core.sol`**: The main singleton contract managing all pools, positions, and swaps
- **`Router.sol`**: High-level interface for swapping with multi-hop support
- **`Positions.sol`**: NFT-based liquidity position management
- **`Orders.sol`**: TWAMM order management as NFTs

### Base Contracts

- **`BaseLocker.sol`**: Abstract base for contracts interacting with the flash accountant
- **`BaseNonfungibleToken.sol`**: Base NFT implementation with access control
- **`FlashAccountant.sol`**: Manages flash loans and token accounting
- **`ExposedStorage.sol`**: Provides access to internal storage for external queries

### Extensions

- **`extensions/Oracle.sol`**: Price oracle functionality
- **`extensions/TWAMM.sol`**: Time-Weighted Average Market Maker implementation
- **`extensions/MEVCapture.sol`**: MEV capture and redistribution mechanism

### Libraries and Types

- **`CoreLib.sol`**: Core contract interaction utilities
- **`PoolKey.sol`**: Pool identification and validation
- **`Position.sol`**: Position data structures and calculations
- **Math Libraries**: Comprehensive mathematical operations for AMM calculations

## Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh/) - Ethereum development toolkit
- [Git](https://git-scm.com/) - Version control

### Installation

1. **Clone the repository**
   ```bash
   git clone https://github.com/EkuboProtocol/solidity.git
   cd solidity
   ```

2. **Install dependencies**
   ```bash
   forge install
   ```

3. **Build the contracts**
   ```bash
   forge build
   ```

### Testing

Run the comprehensive test suite:

```bash
forge test
```

For verbose output:
```bash
forge test -vvv
```

Run specific tests:
```bash
forge test --match-contract CoreTest
forge test --match-test testSwap
```

### Gas Snapshots

Generate gas usage snapshots:
```bash
forge snapshot
```

## Development

### Code Style

The codebase follows strict formatting and style guidelines:

- **Solidity Version**: `0.8.28`
- **Formatting**: Use `forge fmt` to format code
- **Optimization**: Contracts are optimized with `via_ir = true` and high optimizer runs

### Testing Strategy

- **Unit Tests**: Comprehensive coverage of individual contract functions
- **Integration Tests**: End-to-end testing of complex workflows
- **Invariant Tests**: Property-based testing for critical system invariants
- **Fuzz Tests**: Randomized input testing for edge cases

### Documentation

All contracts include comprehensive NatSpec documentation:

- `@title` and `@notice` for contracts and interfaces
- `@param` and `@return` for all function parameters
- `@dev` for implementation details
- `@inheritdoc` for inherited functions

## Key Features

### Concentrated Liquidity

Liquidity providers can concentrate their capital within specific price ranges, improving capital efficiency and earning higher fees on their deposits.

### Extension System

The modular extension system allows for custom pool behaviors:
- Custom fee structures
- Oracle integration
- MEV capture mechanisms
- Time-weighted average market making

### Flash Loans

Built-in flash loan functionality enables:
- Arbitrage opportunities
- Liquidation mechanisms
- Complex DeFi strategies
- Gas-efficient operations

### Multi-Hop Swaps

Efficient routing through multiple pools:
- User-specified routes
- Slippage protection
- Gas optimization
- Batch operations

## Security

### Best Practices

- All contracts use checked arithmetic
- Comprehensive input validation
- Reentrancy protection
- Access control mechanisms

## Contributing

We welcome contributions from the community! Please see our [Contributing Guidelines](CONTRIBUTING.md) for details on:

- Code style and standards
- Testing requirements
- Pull request process
- Issue reporting

## License

This project is licensed under the Ekubo DAO SRL 1.0 License - see the [LICENSE](LICENSE) file for details.

## Links

- **Website**: [ekubo.org](https://ekubo.org)
- **Documentation**: [docs.ekubo.org](https://docs.ekubo.org)
- **Discord**: [discord.gg/ekubo](https://discord.gg/ekubo)
- **Twitter**: [@EkuboProtocol](https://twitter.com/EkuboProtocol)

## Acknowledgments

Built with ❤️ by the Ekubo team and contributors.
