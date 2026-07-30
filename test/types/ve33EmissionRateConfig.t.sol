// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {Ve33EmissionRateConfig, createVe33EmissionRateConfig} from "../../src/types/ve33EmissionRateConfig.sol";

contract Ve33EmissionRateConfigTest is Test {
    function test_conversionToAndFrom(Ve33EmissionRateConfig config) public pure {
        Ve33EmissionRateConfig recreated =
            createVe33EmissionRateConfig(config.minEmissionsRate(), config.scheduleDuration());

        assertEq(Ve33EmissionRateConfig.unwrap(recreated), Ve33EmissionRateConfig.unwrap(config));
    }

    function test_conversionFromAndTo(uint160 minEmissionsRate, uint32 scheduleDuration) public pure {
        Ve33EmissionRateConfig config = createVe33EmissionRateConfig(minEmissionsRate, scheduleDuration);
        assertEq(config.minEmissionsRate(), minEmissionsRate);
        assertEq(config.scheduleDuration(), scheduleDuration);
    }

    function test_conversionFromAndToDirtyBits(bytes32 minEmissionsRateDirty, bytes32 scheduleDurationDirty)
        public
        pure
    {
        uint160 minEmissionsRate;
        uint32 scheduleDuration;

        assembly ("memory-safe") {
            minEmissionsRate := minEmissionsRateDirty
            scheduleDuration := scheduleDurationDirty
        }

        Ve33EmissionRateConfig config = createVe33EmissionRateConfig(minEmissionsRate, scheduleDuration);
        assertEq(config.minEmissionsRate(), minEmissionsRate, "minEmissionsRate");
        assertEq(config.scheduleDuration(), scheduleDuration, "scheduleDuration");
    }
}
