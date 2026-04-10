// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    TWAMMRecoverablePairConfig,
    createTWAMMRecoverablePairConfig
} from "../../src/types/twammRecoverablePairConfig.sol";

contract TWAMMRecoverablePairConfigTest is Test {
    function test_conversionToAndFrom(TWAMMRecoverablePairConfig config) public pure {
        TWAMMRecoverablePairConfig roundtrip = createTWAMMRecoverablePairConfig({
            _collateralFactorBps: config.collateralFactorBps(),
            _triggerHealthFactorX18: config.triggerHealthFactorX18(),
            _cancelHealthFactorX18: config.cancelHealthFactorX18(),
            _configured: config.configured()
        });
        assertEq(roundtrip.collateralFactorBps(), config.collateralFactorBps());
        assertEq(roundtrip.triggerHealthFactorX18(), config.triggerHealthFactorX18());
        assertEq(roundtrip.cancelHealthFactorX18(), config.cancelHealthFactorX18());
        assertEq(roundtrip.configured(), config.configured());
    }

    function test_conversionFromAndTo(
        uint16 collateralFactorBps,
        uint64 triggerHealthFactorX18,
        uint64 cancelHealthFactorX18,
        bool isConfigured
    ) public pure {
        TWAMMRecoverablePairConfig config = createTWAMMRecoverablePairConfig({
            _collateralFactorBps: collateralFactorBps,
            _triggerHealthFactorX18: triggerHealthFactorX18,
            _cancelHealthFactorX18: cancelHealthFactorX18,
            _configured: isConfigured
        });
        assertEq(config.collateralFactorBps(), collateralFactorBps);
        assertEq(config.triggerHealthFactorX18(), triggerHealthFactorX18);
        assertEq(config.cancelHealthFactorX18(), cancelHealthFactorX18);
        assertEq(config.configured(), isConfigured);
    }

    function test_parse(
        uint16 collateralFactorBps,
        uint64 triggerHealthFactorX18,
        uint64 cancelHealthFactorX18,
        bool isConfigured
    ) public pure {
        TWAMMRecoverablePairConfig config = createTWAMMRecoverablePairConfig({
            _collateralFactorBps: collateralFactorBps,
            _triggerHealthFactorX18: triggerHealthFactorX18,
            _cancelHealthFactorX18: cancelHealthFactorX18,
            _configured: isConfigured
        });

        (
            uint16 parsedCollateralFactorBps,
            uint64 parsedTriggerHealthFactorX18,
            uint64 parsedCancelHealthFactorX18,
            bool parsedConfigured
        ) = config.parse();

        assertEq(parsedCollateralFactorBps, collateralFactorBps);
        assertEq(parsedTriggerHealthFactorX18, triggerHealthFactorX18);
        assertEq(parsedCancelHealthFactorX18, cancelHealthFactorX18);
        assertEq(parsedConfigured, isConfigured);
    }
}
