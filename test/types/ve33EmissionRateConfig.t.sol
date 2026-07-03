// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {Ve33EmissionRateConfig, createVe33EmissionRateConfig} from "../../src/types/ve33EmissionRateConfig.sol";

contract Ve33EmissionRateConfigTest is Test {
    function test_conversionToAndFrom(Ve33EmissionRateConfig config) public pure {
        Ve33EmissionRateConfig recreated = createVe33EmissionRateConfig(config.targetRate(), config.scheduleDuration());

        assertEq(recreated.targetRate(), config.targetRate(), "targetRate");
        assertEq(recreated.scheduleDuration(), config.scheduleDuration(), "scheduleDuration");
    }

    function test_conversionFromAndTo(uint160 targetRate, uint32 scheduleDuration) public pure {
        Ve33EmissionRateConfig config = createVe33EmissionRateConfig(targetRate, scheduleDuration);
        assertEq(config.targetRate(), targetRate);
        assertEq(config.scheduleDuration(), scheduleDuration);
    }

    function test_conversionFromAndToDirtyBits(bytes32 targetRateDirty, bytes32 scheduleDurationDirty) public pure {
        uint160 targetRate;
        uint32 scheduleDuration;

        assembly ("memory-safe") {
            targetRate := targetRateDirty
            scheduleDuration := scheduleDurationDirty
        }

        Ve33EmissionRateConfig config = createVe33EmissionRateConfig(targetRate, scheduleDuration);
        assertEq(config.targetRate(), targetRate, "targetRate");
        assertEq(config.scheduleDuration(), scheduleDuration, "scheduleDuration");
    }
}
