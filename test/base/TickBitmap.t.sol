// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {TickBitmap, tickToBitmapWordAndIndex, bitmapWordAndIndexToTick} from "../../src/base/TickBitmap.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, tickToSqrtRatio} from "../../src/math/ticks.sol";
import {Bitmap} from "../../src/math/bitmap.sol";

contract MockTickBitmap is TickBitmap {
    mapping(uint256 => Bitmap) public map;

    function nextInitializedTick(int32 fromTick, uint256 skipAhead, uint32 tickSpacing)
        public
        view
        returns (int32 tick, bool initialized)
    {
        (tick, initialized) = findNextInitializedTick(map, fromTick, skipAhead, tickSpacing);
    }

    function toggleInitializedTick(int32 tick, uint32 tickSpacing) public {
        flipTick(map, tick, tickSpacing);
    }
}

contract TickBitmapTest is Test {
    MockTickBitmap public tbm;

    function setUp() public {
        tbm = new MockTickBitmap();
    }

    function test_tickToBitmapWordAndIndex_bitmapWordAndIndexToTick(int32 tick, uint32 tickSpacing) public pure {
        tickSpacing = uint32(bound(tickSpacing, 1, MAX_TICK_SPACING));
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        tick += int32(tickSpacing) - (tick % int32(tickSpacing));
        (uint256 word, uint8 index) = tickToBitmapWordAndIndex(tick, tickSpacing);
        int32 calculatedTick = bitmapWordAndIndexToTick(word, index, tickSpacing);
        assertEq(tick, calculatedTick);
    }

    function test_nextInitializedTick(int32 tick, uint32 tickSpacing) public {
        tickSpacing = uint32(bound(tickSpacing, 1, MAX_TICK_SPACING));
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        tick += int32(tickSpacing) - (tick % int32(tickSpacing));

        tbm.toggleInitializedTick(tick, tickSpacing);
        (int32 nextTick, bool initialized) = tbm.nextInitializedTick(tick - 1, 0, tickSpacing);
        assertEq(nextTick, tick);
        assertTrue(initialized);
    }
}
