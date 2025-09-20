// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Observation, createObservation} from "../../src/types/observation.sol";

contract ObservationTest is Test {
    function test_conversionToAndFrom(Observation observation) public pure {
        // Test that field extraction works correctly by reconstructing and comparing fields
        Observation reconstructed = createObservation({
            _secondsPerLiquidityCumulative: observation.secondsPerLiquidityCumulative(),
            _tickCumulative: observation.tickCumulative()
        });

        assertEq(reconstructed.secondsPerLiquidityCumulative(), observation.secondsPerLiquidityCumulative());
        assertEq(reconstructed.tickCumulative(), observation.tickCumulative());
    }

    function test_conversionFromAndTo(uint160 secondsPerLiquidityCumulative, int64 tickCumulative) public pure {
        Observation observation = createObservation({
            _secondsPerLiquidityCumulative: secondsPerLiquidityCumulative,
            _tickCumulative: tickCumulative
        });
        assertEq(observation.secondsPerLiquidityCumulative(), secondsPerLiquidityCumulative);
        assertEq(observation.tickCumulative(), tickCumulative);
    }

    function test_conversionFromAndToDirtyBits(bytes32 secondsPerLiquidityCumulativeDirty, bytes32 tickCumulativeDirty)
        public
        pure
    {
        uint160 secondsPerLiquidityCumulative;
        int64 tickCumulative;

        assembly ("memory-safe") {
            secondsPerLiquidityCumulative := secondsPerLiquidityCumulativeDirty
            tickCumulative := tickCumulativeDirty
        }

        Observation observation = createObservation({
            _secondsPerLiquidityCumulative: secondsPerLiquidityCumulative,
            _tickCumulative: tickCumulative
        });
        assertEq(
            observation.secondsPerLiquidityCumulative(), secondsPerLiquidityCumulative, "secondsPerLiquidityCumulative"
        );
        assertEq(observation.tickCumulative(), tickCumulative, "tickCumulative");
    }
}
