// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {TickInfo, createTickInfo} from "../../src/types/tickInfo.sol";

contract TickInfoTest is Test {
    function test_conversionToAndFrom(TickInfo info) public pure {
        assertEq(
            TickInfo.unwrap(
                createTickInfo({
                    _liquidityDelta: info.liquidityDelta(),
                    _positionCount: info.positionCount(),
                    _secondsOutside: info.secondsOutside()
                })
            ),
            TickInfo.unwrap(info)
        );
    }

    function test_conversionFromAndTo(int128 liquidityDelta, uint64 positionCount, uint64 secondsOutside) public pure {
        TickInfo info = createTickInfo({
            _liquidityDelta: liquidityDelta,
            _positionCount: positionCount,
            _secondsOutside: secondsOutside
        });
        assertEq(info.liquidityDelta(), liquidityDelta);
        assertEq(info.positionCount(), positionCount);
        assertEq(info.secondsOutside(), secondsOutside);
    }

    function test_conversionFromAndToDirtyBits(
        bytes32 liquidityDeltaDirty,
        bytes32 positionCountDirty,
        bytes32 secondsOutsideDirty
    ) public pure {
        int128 liquidityDelta;
        uint64 positionCount;
        uint64 secondsOutside;

        assembly ("memory-safe") {
            liquidityDelta := signextend(15, liquidityDeltaDirty)
            positionCount := and(positionCountDirty, 0xFFFFFFFFFFFFFFFF)
            secondsOutside := and(secondsOutsideDirty, 0xFFFFFFFFFFFFFFFF)
        }

        TickInfo info = createTickInfo({
            _liquidityDelta: liquidityDelta,
            _positionCount: positionCount,
            _secondsOutside: secondsOutside
        });
        assertEq(info.liquidityDelta(), liquidityDelta, "liquidityDelta");
        assertEq(info.positionCount(), positionCount, "positionCount");
        assertEq(info.secondsOutside(), secondsOutside, "secondsOutside");
    }
}
