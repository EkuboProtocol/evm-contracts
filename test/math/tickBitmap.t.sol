// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    tickToBitmapWordAndIndex,
    bitmapWordAndIndexToTick,
    flipTick,
    findNextInitializedTick,
    findPrevInitializedTick
} from "../../src/math/tickBitmap.sol";
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
        return next(fromTick, 0);
    }

    function next(int32 fromTick, uint256 skipAhead) public view returns (int32, bool) {
        return findNextInitializedTick(map, fromTick, tickSpacing, skipAhead);
    }

    function prev(int32 fromTick) public view returns (int32, bool) {
        return prev(fromTick, 0);
    }

    function prev(int32 fromTick, uint256 skipAhead) public view returns (int32, bool) {
        return findPrevInitializedTick(map, fromTick, tickSpacing, skipAhead);
    }
}

contract TickBitmapTest is Test {
    function test_gas_flip() public {
        TickBitmap tbm = new TickBitmap(100);

        tbm.flip(0);
        vm.snapshotGasLastCall("flip(0)");
    }

    function test_gas_next() public {
        TickBitmap tbm = new TickBitmap(100);

        tbm.next(0);
        vm.snapshotGasLastCall("next(0)");
    }

    function test_gas_prev() public {
        TickBitmap tbm = new TickBitmap(100);

        tbm.prev(0);
        vm.snapshotGasLastCall("prev(0)");
    }

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

    function checkNextTick(
        TickBitmap tbm,
        int32 fromTick,
        int32 expectedTick,
        bool expectedInitialized,
        uint256 skipAhead
    ) private view {
        (int32 nextTick, bool initialized) = tbm.next(fromTick, skipAhead);
        assertEq(nextTick, expectedTick);
        assertEq(initialized, expectedInitialized);
    }

    function test_findNextInitializedTick(int32 tick, uint32 tickSpacing) public {
        (tick, tickSpacing) = bound(tick, tickSpacing);

        TickBitmap tbm = new TickBitmap(tickSpacing);

        tbm.flip(tick);

        checkNextTick(tbm, tick - 1, tick, true, 0);
    }

    function checkPrevTick(
        TickBitmap tbm,
        int32 fromTick,
        int32 expectedTick,
        bool expectedInitialized,
        uint256 skipAhead
    ) private view {
        (int32 prevTick, bool initialized) = tbm.prev(fromTick, skipAhead);
        assertEq(prevTick, expectedTick);
        assertEq(initialized, expectedInitialized);
    }

    function test_maxTickSpacing_behavior() public {
        TickBitmap tbm = new TickBitmap(MAX_TICK_SPACING);
        // no skip ahead required at max tick spacing
        checkPrevTick(tbm, MAX_TICK, MIN_TICK, false, 0);
        checkPrevTick(tbm, MAX_TICK, MIN_TICK, false, type(uint256).max);

        checkNextTick(tbm, MIN_TICK, MAX_TICK, false, 0);
        checkNextTick(tbm, MIN_TICK, MAX_TICK, false, type(uint256).max);

        tbm.flip(MIN_TICK);
        tbm.flip(MAX_TICK);
        checkPrevTick(tbm, MAX_TICK - 1, MIN_TICK, true, 0);
        checkPrevTick(tbm, MAX_TICK - 1, MIN_TICK, true, type(uint256).max);

        checkNextTick(tbm, MIN_TICK, MAX_TICK, true, 0);
        checkNextTick(tbm, MIN_TICK, MAX_TICK, true, type(uint256).max);
    }

    function test_findPrevInitializedTick(int32 tick, uint32 tickSpacing) public {
        (tick, tickSpacing) = bound(tick, tickSpacing);

        TickBitmap tbm = new TickBitmap(tickSpacing);

        tbm.flip(tick);

        checkPrevTick(tbm, tick, tick, true, 0);
    }

    function test_complex_example_next_tick() public {
        TickBitmap tbm = new TickBitmap(10);

        tbm.flip(-10000);
        tbm.flip(-1000);
        tbm.flip(-20);
        tbm.flip(100);
        tbm.flip(800);
        tbm.flip(9000);

        checkNextTick(tbm, -15000, -14090, false, 0);
        checkNextTick(tbm, -14090, -11530, false, 0);
        checkNextTick(tbm, -11530, -10000, true, 0);
        checkNextTick(tbm, -10000, -8970, false, 0);
        checkNextTick(tbm, -8970, -6410, false, 0);
        checkNextTick(tbm, -6410, -3850, false, 0);
        checkNextTick(tbm, -3850, -1290, false, 0);
        checkNextTick(tbm, -1290, -1000, true, 0);
        checkNextTick(tbm, -1000, -20, true, 0);
        checkNextTick(tbm, -20, 100, true, 0);
        checkNextTick(tbm, 100, 800, true, 0);
        checkNextTick(tbm, 800, 1270, false, 0);
        checkNextTick(tbm, 1270, 3830, false, 0);
        checkNextTick(tbm, 3830, 6390, false, 0);
        checkNextTick(tbm, 6390, 8950, false, 0);
        checkNextTick(tbm, 8950, 9000, true, 0);

        checkNextTick(tbm, -15000, -10000, true, 5);
        checkNextTick(tbm, -10000, -1000, true, 5);
        checkNextTick(tbm, -1000, -20, true, 5);
        checkNextTick(tbm, -20, 100, true, 5);
        checkNextTick(tbm, 100, 800, true, 5);
        checkNextTick(tbm, 800, 9000, true, 5);
    }

    function test_complex_example_prev_tick() public {
        TickBitmap tbm = new TickBitmap(10);

        tbm.flip(-10000);
        tbm.flip(-1000);
        tbm.flip(-20);
        tbm.flip(100);
        tbm.flip(800);
        tbm.flip(9000);

        checkPrevTick(tbm, 15000, 14080, false, 0);
        checkPrevTick(tbm, 14079, 11520, false, 0);
        checkPrevTick(tbm, 11519, 9000, true, 0);
        checkPrevTick(tbm, 9000, 9000, true, 0);
        checkPrevTick(tbm, 8999, 8960, false, 0);
        checkPrevTick(tbm, 8959, 6400, false, 0);
        checkPrevTick(tbm, 6399, 3840, false, 0);
        checkPrevTick(tbm, 3839, 1280, false, 0);
        checkPrevTick(tbm, 1279, 800, true, 0);
        checkPrevTick(tbm, 800, 800, true, 0);
        checkPrevTick(tbm, 799, 100, true, 0);
        checkPrevTick(tbm, 99, -20, true, 0);
        checkPrevTick(tbm, -20, -20, true, 0);
        checkPrevTick(tbm, -21, -1000, true, 0);
        checkPrevTick(tbm, -1001, -1280, false, 0);
        checkPrevTick(tbm, -1281, -3840, false, 0);
        checkPrevTick(tbm, -3841, -6400, false, 0);
        checkPrevTick(tbm, -6401, -8960, false, 0);
        checkPrevTick(tbm, -8961, -10000, true, 0);

        checkPrevTick(tbm, 15000, 9000, true, 5);
        checkPrevTick(tbm, 8999, 800, true, 5);
        checkPrevTick(tbm, 799, 100, true, 5);
        checkPrevTick(tbm, 99, -20, true, 5);
        checkPrevTick(tbm, -21, -1000, true, 5);
        checkPrevTick(tbm, -1001, -10000, true, 5);
    }
}
