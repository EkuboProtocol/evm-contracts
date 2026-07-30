// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    ScheduledEmissionRateConfig,
    createScheduledEmissionRateConfig
} from "../../src/types/scheduledEmissionRateConfig.sol";
import {Ve33EmissionRateConfig, createVe33EmissionRateConfig} from "../../src/types/ve33EmissionRateConfig.sol";

contract ScheduledEmissionRateConfigTest is Test {
    function test_conversionToAndFrom(ScheduledEmissionRateConfig scheduledConfig) public pure {
        assertEq(
            ScheduledEmissionRateConfig.unwrap(
                createScheduledEmissionRateConfig(
                    scheduledConfig.emissionRateConfig(), scheduledConfig.nextConfigTime()
                )
            ),
            ScheduledEmissionRateConfig.unwrap(scheduledConfig)
        );
    }

    function test_conversionFromAndTo(uint160 targetRate, uint32 scheduleDuration, uint64 nextConfigTime) public pure {
        Ve33EmissionRateConfig config = createVe33EmissionRateConfig(targetRate, scheduleDuration);
        ScheduledEmissionRateConfig scheduledConfig = createScheduledEmissionRateConfig(config, nextConfigTime);

        assertEq(scheduledConfig.emissionRateConfig().targetRate(), targetRate);
        assertEq(scheduledConfig.emissionRateConfig().scheduleDuration(), scheduleDuration);
        assertEq(scheduledConfig.nextConfigTime(), nextConfigTime);
    }

    function test_conversionFromAndToDirtyBits(bytes32 configDirty, bytes32 nextConfigTimeDirty) public pure {
        Ve33EmissionRateConfig config = Ve33EmissionRateConfig.wrap(configDirty);
        uint64 nextConfigTime;

        assembly ("memory-safe") {
            nextConfigTime := nextConfigTimeDirty
        }

        ScheduledEmissionRateConfig scheduledConfig = createScheduledEmissionRateConfig(config, nextConfigTime);
        assertEq(scheduledConfig.emissionRateConfig().targetRate(), config.targetRate(), "targetRate");
        assertEq(scheduledConfig.emissionRateConfig().scheduleDuration(), config.scheduleDuration(), "scheduleDuration");
        assertEq(scheduledConfig.nextConfigTime(), nextConfigTime, "nextConfigTime");
    }

    function test_parse(uint160 targetRate, uint32 scheduleDuration, uint64 nextConfigTime) public pure {
        Ve33EmissionRateConfig config = createVe33EmissionRateConfig(targetRate, scheduleDuration);
        ScheduledEmissionRateConfig scheduledConfig = createScheduledEmissionRateConfig(config, nextConfigTime);

        (Ve33EmissionRateConfig parsedConfig, uint64 parsedNextConfigTime) = scheduledConfig.parse();
        assertEq(parsedConfig.targetRate(), targetRate, "targetRate");
        assertEq(parsedConfig.scheduleDuration(), scheduleDuration, "scheduleDuration");
        assertEq(parsedNextConfigTime, nextConfigTime, "nextConfigTime");
    }
}
