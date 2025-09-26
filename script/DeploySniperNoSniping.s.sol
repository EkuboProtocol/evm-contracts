// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {Script} from "forge-std/Script.sol";
import {SniperNoSniping, sniperNoSnipingCallPoints} from "../src/SniperNoSniping.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ITWAMM} from "../src/interfaces/extensions/ITWAMM.sol";
import {findExtensionSalt} from "./DeployCore.s.sol";

contract DeploySniperNoSniping is Script {
    function run() public {
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));
        ITWAMM twamm = ITWAMM(payable(vm.envAddress("TWAMM_ADDRESS")));

        vm.startBroadcast();

        uint256 orderDurationMagnitude = 4;
        uint128 tokenTotalSupply = 69_420_000e18;
        uint64 poolFee = uint64((uint256(1) << 64) / 100);
        uint32 tickSpacing = 1000;

        new SniperNoSniping{
            salt: findExtensionSalt(
                salt,
                keccak256(
                    abi.encodePacked(
                        type(SniperNoSniping).creationCode,
                        abi.encode(core, twamm, orderDurationMagnitude, tokenTotalSupply, poolFee, tickSpacing)
                    )
                ),
                sniperNoSnipingCallPoints()
            )
        }({
            core: core,
            twamm: twamm,
            orderDurationMagnitude: orderDurationMagnitude,
            tokenTotalSupply: tokenTotalSupply,
            poolFee: poolFee,
            tickSpacing: tickSpacing
        });

        vm.stopBroadcast();
    }
}
