// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IOracle} from "../src/interfaces/extensions/IOracle.sol";
import {ERC7726} from "../src/lens/ERC7726.sol";

/// @title ERC-7726 Oracle Deployment Script
/// @notice Deploys the Ekubo ERC-7726 Oracle implementation with configurable parameters
/// @dev This script is designed for mainnet deployment and uses environment variables for configuration.
///      Default values are provided for mainnet addresses but can be overridden via environment variables.
///
/// Environment Variables:
/// - ORACLE_ADDRESS: Address of the deployed Ekubo Oracle extension (default: mainnet address)
/// - TWAP_DURATION: Time window in seconds for TWAP calculations (default: 60 seconds)
/// - USD_PROXY_TOKEN: Token address to use as USD proxy (default: USDC mainnet address)
/// - BTC_PROXY_TOKEN: Token address to use as BTC proxy (default: WBTC mainnet address)
/// - SALT: Salt for CREATE2 deployment (default: 0x0, always uses CREATE2)
///
/// Usage:
/// forge script script/DeployERC7726.sol:DeployERC7726 --rpc-url $RPC_URL --broadcast --verify
contract DeployERC7726 is Script {
    /// @notice Default Ekubo Oracle address on Ethereum mainnet
    address private constant DEFAULT_ORACLE_ADDRESS = 0x51d02A5948496a67827242EaBc5725531342527C;

    /// @notice Default USDC address on Ethereum mainnet (used as USD proxy)
    address private constant DEFAULT_USD_PROXY_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice Default WBTC address on Ethereum mainnet (used as BTC proxy)
    address private constant DEFAULT_BTC_PROXY_TOKEN = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    /// @notice Default TWAP duration in seconds (1 minute)
    uint32 private constant DEFAULT_TWAP_DURATION = 60;

    /// @notice Emitted when the ERC7726 oracle is successfully deployed
    /// @param erc7726Oracle The deployed ERC7726 contract address
    /// @param oracleExtension The Ekubo Oracle extension address used
    /// @param usdProxy The USD proxy token address
    /// @param btcProxy The BTC proxy token address
    /// @param twapDuration The TWAP duration in seconds
    event ERC7726Deployed(
        address indexed erc7726Oracle,
        address indexed oracleExtension,
        address usdProxy,
        address btcProxy,
        uint32 twapDuration
    );

    /// @notice Main deployment function
    /// @dev Validates the deployment environment and parameters before deploying
    function run() public {
        // Ensure we're deploying on mainnet
        require(block.chainid == 1, "DeployERC7726: Mainnet only");

        // Load configuration from environment variables with fallback defaults
        IOracle oracle = IOracle(vm.envOr("ORACLE_ADDRESS", DEFAULT_ORACLE_ADDRESS));
        uint32 twapDuration = uint32(vm.envOr("TWAP_DURATION", uint256(DEFAULT_TWAP_DURATION)));
        address usdProxyToken = vm.envOr("USD_PROXY_TOKEN", DEFAULT_USD_PROXY_TOKEN);
        address btcProxyToken = vm.envOr("BTC_PROXY_TOKEN", DEFAULT_BTC_PROXY_TOKEN);
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));

        // Validate configuration parameters
        require(address(oracle) != address(0), "DeployERC7726: Invalid oracle address");
        require(usdProxyToken != address(0), "DeployERC7726: Invalid USD proxy token");
        require(btcProxyToken != address(0), "DeployERC7726: Invalid BTC proxy token");
        require(twapDuration > 0, "DeployERC7726: Invalid TWAP duration");
        require(usdProxyToken != btcProxyToken, "DeployERC7726: USD and BTC proxies must be different");

        // Log deployment parameters
        console.log("Deploying ERC7726 Oracle with parameters:");
        console.log("  Oracle Extension:", address(oracle));
        console.log("  USD Proxy Token:", usdProxyToken);
        console.log("  BTC Proxy Token:", btcProxyToken);
        console.log("  TWAP Duration:", twapDuration, "seconds");
        console.log("  Salt:", vm.toString(salt));

        vm.startBroadcast();

        // Deploy the ERC7726 oracle
        ERC7726 deployedOracle = new ERC7726{salt: salt}(oracle, usdProxyToken, btcProxyToken, twapDuration);

        vm.stopBroadcast();

        // Log successful deployment
        console.log("ERC7726 Oracle deployed at:", address(deployedOracle));

        emit ERC7726Deployed(address(deployedOracle), address(oracle), usdProxyToken, btcProxyToken, twapDuration);
    }
}
