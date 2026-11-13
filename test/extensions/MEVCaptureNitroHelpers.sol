// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "../../src/interfaces/ICore.sol";
import {MEVCaptureNitro} from "../../src/extensions/MEVCaptureNitro.sol";

address constant ARB_SYS = address(0x64);

/// @dev TIMESTAMP PUSH0 MSTORE PUSH1 0x20 PUSH0 RETURN: answers every call with `block.timestamp`, so one clock unit
///   is one second as in MEV Capture v2.1
bytes constant ARB_SYS_TIMESTAMP_CLOCK = hex"425f5260205ff3";
/// @dev NUMBER PUSH0 MSTORE PUSH1 0x20 PUSH0 RETURN: answers every call with `block.number`, so `vm.roll` moves the
///   L2 block number that the extension sees
bytes constant ARB_SYS_NUMBER_CLOCK = hex"435f5260205ff3";

/// @notice Independent statement of the priority surcharge rule: nothing up to the free allowance, then `slope` per
///   wei of priority fee per gas, never more than `cap`
function expectedPrioritySurcharge(uint256 gasPrice, uint256 baseFee, uint256 free, uint256 slope, uint256 cap)
    pure
    returns (uint256)
{
    if (slope == 0 || gasPrice <= baseFee) return 0;
    uint256 tip = gasPrice - baseFee;
    if (tip <= free) return 0;
    uint256 excess = tip - free;
    // the smallest excess at which the cap is reached
    uint256 saturation = cap / slope + (cap % slope == 0 ? 0 : 1);
    return excess >= saturation ? cap : excess * slope;
}

/// @notice Deployable anywhere (skips Core registration) to test constructor validation
contract MEVCaptureNitroUnregistered is MEVCaptureNitro {
    constructor(
        ICore core,
        uint32 a,
        uint8 b,
        uint8 c,
        uint8 d,
        uint64 e,
        uint32 f,
        uint8 g,
        uint64 priorityFree,
        uint64 prioritySlope,
        uint64 priorityCap
    ) MEVCaptureNitro(core, a, b, c, d, e, f, g, priorityFree, prioritySlope, priorityCap) {}

    function _registerInConstructor() internal pure override returns (bool) {
        return false;
    }
}
