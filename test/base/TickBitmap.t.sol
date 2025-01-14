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

    function next(int32 fromTick) public view returns (int32, bool) {
        return findNextInitializedTick(map, fromTick, tickSpacing);
    }

    function prev(int32 fromTick) public view returns (int32, bool) {
        return findPrevInitializedTick(map, fromTick, tickSpacing);
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

    function assertTbwi(int32 tick, uint32 tickSpacing, uint256 expectedWord, uint8 expectedIndex) public pure {
        (uint256 word, uint8 index) = tickToBitmapWordAndIndex(tick, tickSpacing);
        assertEq(word, expectedWord);
        assertEq(index, expectedIndex);
    }

    function test_tickToBitmapWordAndIndex(uint32 tickSpacing) public pure {
        // regardless of tick spacing, the 0 tick is in the middle of a word
        tickSpacing = uint32(bound(tickSpacing, 1, MAX_TICK_SPACING));
        int32 mul = int32(tickSpacing);
        assertTbwi(0, tickSpacing, 346574, 127);
        assertTbwi(mul, tickSpacing, 346574, 126);
        assertTbwi(mul * 127, tickSpacing, 346574, 0);
        assertTbwi(mul * 128, tickSpacing, 346575, 255);
        assertTbwi(mul * -1, tickSpacing, 346574, 128);
        assertTbwi(mul * -128, tickSpacing, 346574, 255);
        assertTbwi(mul * -129, tickSpacing, 346573, 0);
    }

    function test_tickToBitmapWordAndIndex_bitmapWordAndIndexToTick(int32 tick, uint32 tickSpacing) public pure {
        (tick, tickSpacing) = bound(tick, tickSpacing);
        (uint256 word, uint8 index) = tickToBitmapWordAndIndex(tick, tickSpacing);
        int32 calculatedTick = bitmapWordAndIndexToTick(word, index, tickSpacing);
        assertEq(tick, calculatedTick);
    }

    function checkNextTick(TickBitmap tbm, int32 fromTick, int32 expectedTick, bool expectedInitialized) private {
        (int32 nextTick, bool initialized) = tbm.next(fromTick);
        assertEq(nextTick, expectedTick);
        assertTrue(expectedInitialized);
    }

    function test_findNextInitializedTick(int32 tick, uint32 tickSpacing) public {
        (tick, tickSpacing) = bound(tick, tickSpacing);

        TickBitmap tbm = new TickBitmap(tickSpacing);

        tbm.flip(tick);

        checkNextTick(tbm, tick - 1, tick, true);
    }

    function checkPrevTick(TickBitmap tbm, int32 fromTick, int32 expectedTick, bool expectedInitialized) private {
        (int32 prevTick, bool initialized) = tbm.prev(fromTick);
        assertEq(prevTick, expectedTick);
        assertTrue(expectedInitialized);
    }

    function test_findPrevInitializedTick(int32 tick, uint32 tickSpacing) public {
        (tick, tickSpacing) = bound(tick, tickSpacing);

        TickBitmap tbm = new TickBitmap(tickSpacing);

        tbm.flip(tick);

        checkPrevTick(tbm, tick, tick, true);
    }
}
