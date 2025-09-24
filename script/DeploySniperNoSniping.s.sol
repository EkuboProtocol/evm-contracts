// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Script} from "forge-std/Script.sol";
import {Positions} from "../src/Positions.sol";
import {Router} from "../src/Router.sol";
import {Orders} from "../src/Orders.sol";
import {SniperNoSniping} from "../src/SniperNoSniping.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ITWAMM} from "../src/interfaces/extensions/ITWAMM.sol";

contract DeploySniperNoSniping is Script {
    function run() public {
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));
        ITWAMM twamm = ITWAMM(payable(vm.envAddress("TWAMM_ADDRESS")));

        vm.startBroadcast();

        new SniperNoSniping{salt: salt}({
            core: core,
            twamm: twamm,
            orderDurationMagnitude: 4,
            tokenTotalSupply: 1_000_000_000e9,
            poolFee: uint64((uint256(1) << 64) / 100),
            tickSpacing: 1000
        });

        vm.stopBroadcast();
    }
}
