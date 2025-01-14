// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    tickToBitmapWordAndIndex,
    bitmapWordAndIndexToTick,
    flipTick,
    findNextInitializedTick,
    findPrevInitializedTick
} from "../../src/base/TickBitmap.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, tickToSqrtRatio} from "../../src/math/ticks.sol";
import {Bitmap} from "../../src/math/bitmap.sol";

contract TickBitmap {
    mapping(uint256 => Bitmap) public map;
    // we use an immutable because this is a constraint that the bitmap expects
    uint32 public immutable tickSpacing;

    constructor(uint32 _tickSpacing) {
        tickSpacing = _tickSpacing;
    }

    function flip(int32 tick) public {
        // this is another expectation for how the bitmap is used in core
        assert(tick % int32(tickSpacing) == 0);
        flipTick(map, tick, tickSpacing);
    }

    function next(int32 fromTick, uint256 skipAhead) public view returns (int32 tick, bool initialized) {
        (tick, initialized) = findNextInitializedTick(map, fromTick, tickSpacing, skipAhead);
    }

    function prev(int32 fromTick, uint256 skipAhead) public view returns (int32 tick, bool initialized) {
        (tick, initialized) = findPrevInitializedTick(map, fromTick, tickSpacing, skipAhead);
    }
}

contract TickBitmapTest is Test {
    function bound(int32 tick, uint32 tickSpacing) private pure returns (int32, uint32) {
        tickSpacing = uint32(bound(tickSpacing, 1, MAX_TICK_SPACING));
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        // rounds towards zero to a multiple of tick spacing
        tick = (tick / int32(tickSpacing)) * int32(tickSpacing);
        return (tick, tickSpacing);
    }

    function test_tickToBitmapWordAndIndex_bitmapWordAndIndexToTick(int32 tick, uint32 tickSpacing) public pure {
        (tick, tickSpacing) = bound(tick, tickSpacing);
        (uint256 word, uint8 index) = tickToBitmapWordAndIndex(tick, tickSpacing);
        int32 calculatedTick = bitmapWordAndIndexToTick(word, index, tickSpacing);
        assertEq(tick, calculatedTick);
    }

    function test_findNextInitializedTick(int32 tick, uint32 tickSpacing) public {
        (tick, tickSpacing) = bound(tick, tickSpacing);

        TickBitmap tbm = new TickBitmap(tickSpacing);

        tbm.flip(tick);
        (int32 nextTick, bool initialized) = tbm.next(tick - 1, 0);
        assertEq(nextTick, tick);
        assertTrue(initialized);
    }

    function test_findPrevInitializedTick(int32 tick, uint32 tickSpacing) public {
        (tick, tickSpacing) = bound(tick, tickSpacing);

        TickBitmap tbm = new TickBitmap(tickSpacing);

        tbm.flip(tick);
        (int32 prevTick, bool initialized) = tbm.prev(tick, 0);
        assertEq(prevTick, tick);
        assertTrue(initialized);
    }
}
