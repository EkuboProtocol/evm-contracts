// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    ScheduledVe33EmissionRateConfig,
    createScheduledVe33EmissionRateConfig
} from "../../src/types/scheduledVe33EmissionRateConfig.sol";
import {Ve33EmissionRateConfig, createVe33EmissionRateConfig} from "../../src/types/ve33EmissionRateConfig.sol";

contract ScheduledVe33EmissionRateConfigTest is Test {
    function test_conversionToAndFrom(ScheduledVe33EmissionRateConfig scheduledConfig) public pure {
        assertEq(
            ScheduledVe33EmissionRateConfig.unwrap(
                createScheduledVe33EmissionRateConfig(
                    scheduledConfig.emissionRateConfig(), scheduledConfig.nextConfigTime()
                )
            ),
            ScheduledVe33EmissionRateConfig.unwrap(scheduledConfig)
        );
    }

    function test_conversionFromAndTo(uint160 minEmissionsRate, uint32 scheduleDuration, uint64 nextConfigTime)
        public
        pure
    {
        Ve33EmissionRateConfig config = createVe33EmissionRateConfig(minEmissionsRate, scheduleDuration);
        ScheduledVe33EmissionRateConfig scheduledConfig = createScheduledVe33EmissionRateConfig(config, nextConfigTime);

        assertEq(scheduledConfig.emissionRateConfig().minEmissionsRate(), minEmissionsRate);
        assertEq(scheduledConfig.emissionRateConfig().scheduleDuration(), scheduleDuration);
        assertEq(scheduledConfig.nextConfigTime(), nextConfigTime);
    }

    function test_conversionFromAndToDirtyBits(bytes32 configDirty, bytes32 nextConfigTimeDirty) public pure {
        Ve33EmissionRateConfig config;
        uint64 nextConfigTime;

        assembly ("memory-safe") {
            config := configDirty
            nextConfigTime := nextConfigTimeDirty
        }

        ScheduledVe33EmissionRateConfig scheduledConfig = createScheduledVe33EmissionRateConfig(config, nextConfigTime);
        assertEq(scheduledConfig.emissionRateConfig().minEmissionsRate(), config.minEmissionsRate(), "minEmissionsRate");
        assertEq(scheduledConfig.emissionRateConfig().scheduleDuration(), config.scheduleDuration(), "scheduleDuration");
        assertEq(scheduledConfig.nextConfigTime(), nextConfigTime, "nextConfigTime");
    }

    function test_parse(uint160 minEmissionsRate, uint32 scheduleDuration, uint64 nextConfigTime) public pure {
        Ve33EmissionRateConfig config = createVe33EmissionRateConfig(minEmissionsRate, scheduleDuration);
        ScheduledVe33EmissionRateConfig scheduledConfig = createScheduledVe33EmissionRateConfig(config, nextConfigTime);

        (Ve33EmissionRateConfig parsedConfig, uint64 parsedNextConfigTime) = scheduledConfig.parse();
        assertEq(parsedConfig.minEmissionsRate(), minEmissionsRate, "minEmissionsRate");
        assertEq(parsedConfig.scheduleDuration(), scheduleDuration, "scheduleDuration");
        assertEq(parsedNextConfigTime, nextConfigTime, "nextConfigTime");
    }
}
