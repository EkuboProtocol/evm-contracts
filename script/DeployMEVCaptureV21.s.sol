// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {MEVCaptureV21, mevCaptureV21CallPoints} from "../src/extensions/MEVCaptureV21.sol";
import {deployExtension} from "./DeployAll.s.sol";

/// @title DeployMEVCaptureV21
/// @notice Deploys MEVCaptureV21 for the current Core with the recommended Ethereum defaults, overridable by env
contract DeployMEVCaptureV21 is Script {
    function run() public returns (address deployed, bytes32 salt) {
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", address(0x00000000000014aA86C5d3c41765bb24e11bd701))));
        bytes32 startingSalt = vm.envOr("SALT", bytes32(0));
        address expectedAddress = vm.envOr("EXPECTED_ADDRESS", address(0));

        uint32 halfLife = uint32(vm.envOr("HALF_LIFE", uint256(120)));
        uint8 slopeK = uint8(vm.envOr("SLOPE_K", uint256(4)));
        uint8 segmentExp = uint8(vm.envOr("SEGMENT_EXP", uint256(0)));
        uint8 jLin = uint8(vm.envOr("J_LIN", uint256(16)));
        uint64 maxFee = uint64(vm.envOr("MAX_FEE", uint256(1 << 63)));
        uint32 clampTicks = uint32(vm.envOr("CLAMP_TICKS", uint256(2500)));
        uint8 mGate = uint8(vm.envOr("M_GATE", uint256(3)));

        bytes memory initCode = abi.encodePacked(
            type(MEVCaptureV21).creationCode,
            abi.encode(core, halfLife, slopeK, segmentExp, jLin, maxFee, clampTicks, mGate)
        );
        vm.startBroadcast();
        (deployed, salt) =
            deployExtension(initCode, startingSalt, mevCaptureV21CallPoints(), expectedAddress, "MEVCaptureV21");
        vm.stopBroadcast();
    }
}
