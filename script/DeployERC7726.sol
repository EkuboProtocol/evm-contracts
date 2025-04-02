// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {Oracle} from "../src/extensions/Oracle.sol";
import {ERC7726} from "../src/lens/ERC7726.sol";

contract DeployERC7726 is Script {
    function run() public {
        Oracle oracle = Oracle(vm.envOr("ORACLE_ADDRESS", address(0x51d02A5948496a67827242EaBc5725531342527C)));
        uint32 twapDuration = uint32(vm.envOr("TWAP_DURATION", uint256(60)));
        address usdProxyToken = vm.envOr("USD_PROXY_TOKEN", address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));
        address btcProxyToken = vm.envOr("BTC_PROXY_TOKEN", address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599));

        bytes32 salt = vm.envOr("SALT", bytes32(0x0));

        vm.startBroadcast();

        new ERC7726{salt: salt}(oracle, usdProxyToken, btcProxyToken, twapDuration);

        vm.stopBroadcast();
    }
}
