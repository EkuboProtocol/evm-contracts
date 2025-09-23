// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Snapshot, createSnapshot} from "../../src/types/snapshot.sol";

contract SnapshotTest is Test {
    function test_conversionToAndFrom(Snapshot snapshot) public pure {
        assertEq(
            Snapshot.unwrap(
                createSnapshot({
                    _timestamp: snapshot.timestamp(),
                    _secondsPerLiquidityCumulative: snapshot.secondsPerLiquidityCumulative(),
                    _tickCumulative: snapshot.tickCumulative()
                })
            ),
            Snapshot.unwrap(snapshot)
        );
    }

    function test_conversionFromAndTo(uint32 timestamp, uint160 secondsPerLiquidityCumulative, int64 tickCumulative)
        public
        pure
    {
        Snapshot snapshot = createSnapshot({
            _timestamp: timestamp,
            _secondsPerLiquidityCumulative: secondsPerLiquidityCumulative,
            _tickCumulative: tickCumulative
        });
        assertEq(snapshot.timestamp(), timestamp);
        assertEq(snapshot.secondsPerLiquidityCumulative(), secondsPerLiquidityCumulative);
        assertEq(snapshot.tickCumulative(), tickCumulative);
    }

    function test_conversionFromAndToDirtyBits(
        bytes32 timestampDirty,
        bytes32 secondsPerLiquidityCumulativeDirty,
        bytes32 tickCumulativeDirty
    ) public pure {
        uint32 ts;
        uint160 secondsPerLiquidityCumulative;
        int64 tickCumulative;

        assembly ("memory-safe") {
            ts := timestampDirty
            secondsPerLiquidityCumulative := secondsPerLiquidityCumulativeDirty
            tickCumulative := tickCumulativeDirty
        }

        Snapshot snapshot = createSnapshot({
            _timestamp: ts,
            _secondsPerLiquidityCumulative: secondsPerLiquidityCumulative,
            _tickCumulative: tickCumulative
        });
        assertEq(snapshot.timestamp(), ts, "timestamp");
        assertEq(
            snapshot.secondsPerLiquidityCumulative(), secondsPerLiquidityCumulative, "secondsPerLiquidityCumulative"
        );
        assertEq(snapshot.tickCumulative(), tickCumulative, "tickCumulative");
    }
}
