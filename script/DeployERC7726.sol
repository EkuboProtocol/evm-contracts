// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Script} from "forge-std/Script.sol";
import {IOracle} from "../src/interfaces/extensions/IOracle.sol";
import {ERC7726} from "../src/lens/ERC7726.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";

contract DeployERC7726 is Script {
    /// @notice Default USDC address on Ethereum mainnet (used as USD proxy)
    address private constant DEFAULT_USD_PROXY_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @notice Default WBTC address on Ethereum mainnet (used as BTC proxy)
    address private constant DEFAULT_BTC_PROXY_TOKEN = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    /// @notice Default TWAP duration in seconds (1 minute)
    uint32 private constant DEFAULT_TWAP_DURATION = 60;

    /// @notice Main deployment function
    /// @dev Validates the deployment environment and parameters before deploying
    function run() public {
        require(block.chainid == 1, "DeployERC7726: Mainnet only");

        // Load configuration from environment variables with fallback defaults
        IOracle oracle = IOracle(vm.envAddress("ORACLE_ADDRESS"));
        uint32 twapDuration = uint32(vm.envOr("TWAP_DURATION", uint256(DEFAULT_TWAP_DURATION)));
        address usdProxyToken = vm.envOr("USD_PROXY_TOKEN", DEFAULT_USD_PROXY_TOKEN);
        address btcProxyToken = vm.envOr("BTC_PROXY_TOKEN", DEFAULT_BTC_PROXY_TOKEN);
        address ethProxyToken = vm.envOr("ETH_PROXY_TOKEN", NATIVE_TOKEN_ADDRESS);
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));

        vm.startBroadcast();

        new ERC7726{salt: salt}(oracle, usdProxyToken, btcProxyToken, ethProxyToken, twapDuration);

        vm.stopBroadcast();
    }
}
