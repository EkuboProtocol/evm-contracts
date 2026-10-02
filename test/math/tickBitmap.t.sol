// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {
    tickToBitmapWordAndIndex,
    bitmapWordAndIndexToTick,
    flipTick,
    loadBitmap,
    findNextInitializedTick,
    findPrevInitializedTick
} from "../../src/math/tickBitmap.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING_EXP} from "../../src/math/constants.sol";
import {RedBlackTreeLib} from "solady/utils/RedBlackTreeLib.sol";
import {StorageSlot} from "../../src/types/storageSlot.sol";

contract TickBitmap {
    StorageSlot public constant slot = StorageSlot.wrap(0);
    // we use an immutable because this is a constraint that the bitmap expects
    uint8 public immutable tickSpacingExp;

    constructor(uint8 _tickSpacingExp) {
        assert(_tickSpacingExp <= MAX_TICK_SPACING_EXP);
        tickSpacingExp = _tickSpacingExp;
    }

    function tickSpacing() internal view returns (int32) {
        return int32(uint32(uint256(1) << tickSpacingExp));
    }

    function isInitialized(int32 tick) public view returns (bool) {
        assert(tick % tickSpacing() == 0);
        (uint256 word, uint256 index) = tickToBitmapWordAndIndex(tick, tickSpacingExp);
        return loadBitmap(slot, word).isSet(uint8(index));
    }

    function flip(int32 tick) public {
        // this is an expectation for how the bitmap is used in core
        require((tick % tickSpacing()) == 0, "mod");
        require(tick <= MAX_TICK, "max");
        require(tick >= MIN_TICK, "min");
        flipTick(slot, tick, tickSpacingExp);
    }

    function next(int32 fromTick) public view returns (int32, bool) {
        return next(fromTick, 0);
    }

    function next(int32 fromTick, uint256 skipAhead) public view returns (int32, bool) {
        return findNextInitializedTick(slot, fromTick, tickSpacingExp, skipAhead);
    }

    function prev(int32 fromTick) public view returns (int32, bool) {
        return prev(fromTick, 0);
    }

    function prev(int32 fromTick, uint256 skipAhead) public view returns (int32, bool) {
        return findPrevInitializedTick(slot, fromTick, tickSpacingExp, skipAhead);
    }
}

contract TickBitmapHandler is StdUtils, StdAssertions {
    using RedBlackTreeLib for *;

    TickBitmap tbm;

    RedBlackTreeLib.Tree tree;

    constructor(TickBitmap _tbm) {
        tbm = _tbm;
    }

    function flip(int32 tick) public {
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        int32 ts = int32(uint32(uint256(1) << tbm.tickSpacingExp()));
        tick = (tick / ts) * ts;

        tbm.flip(tick);
        if (tbm.isInitialized(tick)) {
            tree.insert(uint256(int256(tick) - type(int32).min));
        } else {
            tree.remove(uint256(int256(tick) - type(int32).min));
        }
    }

    function checkAllTicksMatchRedBlackTree() public view {
        uint256[] memory initialized = tree.values();
        int32 p;
        for (uint256 i = 0; i < initialized.length; i++) {
            int32 t = int32(int256(initialized[i]) + type(int32).min);
            assertTrue(tbm.isInitialized(t));

            {
                (int32 pT, bool pI) = tbm.prev(t - 1, type(uint256).max);
                if (i != 0) {
                    assertEq(pT, p);
                    assertTrue(pI);
                } else {
                    assertEq(pT, MIN_TICK);
                    assertFalse(pI);
                }
            }

            (int32 tt, bool tI) = tbm.prev(t, type(uint256).max);
            assertEq(tt, t);
            assertTrue(tI);

            {
                (int32 nt, bool nI) = tbm.next(t, type(uint256).max);

                if (i != initialized.length - 1) {
                    int32 n = int32(int256(initialized[i + 1]) + type(int32).min);
                    assertEq(nt, n);
                    assertTrue(nI);
                } else {
                    assertEq(nt, MAX_TICK);
                    assertFalse(nI);
                }
            }

            p = t;
        }
    }
}

contract TickBitmapInvariantTest is Test {
    TickBitmapHandler tbh;

    function setUp() public {
        TickBitmap tbm = new TickBitmap(2);
        excludeContract(address(tbm));
        tbh = new TickBitmapHandler(tbm);
    }

    function invariant_checkAllTicksMatchRedBlackTree() public view {
        tbh.checkAllTicksMatchRedBlackTree();
    }
}

contract TickBitmapTest is Test {
    function test_gas_tickToBitmapWordAndIndex() public returns (uint256 word, uint256 index) {
        vm.startSnapshotGas("tickToBitmapWordAndIndex(150,2)");
        (word, index) = tickToBitmapWordAndIndex(150, 2);
        vm.stopSnapshotGas();
    }

    /// forge-config: default.isolate = true
    function test_gas_next_entire_map() public {
        TickBitmap tbm = new TickBitmap(2);
        // incurs about ~6930 sloads which is 14553000 gas minimum
        (int32 t, bool i) = tbm.next(MIN_TICK, type(uint256).max);
        vm.snapshotGasLastCall("ts exp = 2, next(MIN_TICK, type(uint256).max)");
        assertEq(t, MAX_TICK);
        assertFalse(i);
    }

    /// forge-config: default.isolate = true
    function test_gas_prev_entire_map() public {
        TickBitmap tbm = new TickBitmap(2);
        // incurs about ~6930 sloads which is 14553000 gas minimum
        (int32 t, bool i) = tbm.prev(MAX_TICK, type(uint256).max);
        vm.snapshotGasLastCall("ts exp = 2, prev(MAX_TICK, type(uint256).max)");
        assertEq(t, MIN_TICK);
        assertFalse(i);
    }

    /// forge-config: default.isolate = true
    function test_gas_flip() public {
        TickBitmap tbm = new TickBitmap(2);

        tbm.flip(0);
        vm.snapshotGasLastCall("flip(0)");
    }

    /// forge-config: default.isolate = true
    function test_gas_next() public {
        TickBitmap tbm = new TickBitmap(2);

        tbm.next(0);
        vm.snapshotGasLastCall("next(0)");
    }

    /// forge-config: default.isolate = true
    function test_gas_next_set() public {
        TickBitmap tbm = new TickBitmap(2);

        tbm.flip(3000);
        tbm.next(0);
        vm.snapshotGasLastCall("next(0) == 3000");
    }

    /// forge-config: default.isolate = true
    function test_gas_prev() public {
        TickBitmap tbm = new TickBitmap(2);

        tbm.prev(0);
        vm.snapshotGasLastCall("prev(0)");
    }

    /// forge-config: default.isolate = true
    function test_gas_prev_set() public {
        TickBitmap tbm = new TickBitmap(2);

        tbm.flip(-3000);
        tbm.prev(0);
        vm.snapshotGasLastCall("prev(0) == -3000");
    }

    function boundTick(int32 tick) private pure returns (int32) {
        return int32(bound(tick, MIN_TICK, MAX_TICK));
    }

    function boundTickSpacingExp(uint8 tickSpacingExp) private pure returns (uint8) {
        return uint8(bound(tickSpacingExp, 0, MAX_TICK_SPACING_EXP));
    }

    function spacingOf(uint8 tickSpacingExp) private pure returns (int32) {
        return int32(uint32(uint256(1) << tickSpacingExp));
    }

    function assertTbwi(int32 tick, uint8 tickSpacingExp, uint256 expectedWord, uint256 expectedIndex) public pure {
        (uint256 word, uint256 index) = tickToBitmapWordAndIndex(tick, tickSpacingExp);
        assertEq(word, expectedWord);
        assertEq(index, expectedIndex);
    }

    function test_tickToBitmapWordAndIndex(uint8 tickSpacingExp) public pure {
        tickSpacingExp = boundTickSpacingExp(tickSpacingExp);
        // regardless of tick spacing, the 0 tick is in the middle of a word
        int32 mul = spacingOf(tickSpacingExp);

        uint256 word = 349303;
        assertTbwi(0, tickSpacingExp, word, 127);
        // positive ticks
        assertTbwi(mul - 1, tickSpacingExp, word, 127);
        assertTbwi(mul, tickSpacingExp, word, 128);
        assertTbwi((mul * 127) + (mul - 1), tickSpacingExp, word, 254);
        assertTbwi(mul * 128, tickSpacingExp, word, 255);
        assertTbwi(mul * 128 + (mul - 1), tickSpacingExp, word, 255);
        assertTbwi(mul * 129, tickSpacingExp, word + 1, 0);

        // negative ticks
        assertTbwi(-1, tickSpacingExp, word, 126);
        assertTbwi(-mul, tickSpacingExp, word, 126);
        assertTbwi(-mul * 126, tickSpacingExp, word, 1);
        assertTbwi(-mul * 127, tickSpacingExp, word, 0);
        assertTbwi((-mul * 127) - 1, tickSpacingExp, word - 1, 255);
    }

    function test_tickToBitmapWordAndIndex_min_max_values() public pure {
        // min/max tick with the largest spacing: the whole range spans two bitmap words
        assertTbwi(MAX_TICK, MAX_TICK_SPACING_EXP, 349304, 40);
        assertTbwi(MIN_TICK, MAX_TICK_SPACING_EXP, 349302, 213);
    }

    function test_tickToBitmapWordAndIndex_bitmapWordAndIndexToTick(int32 tick, uint8 tickSpacingExp) public pure {
        tickSpacingExp = boundTickSpacingExp(tickSpacingExp);
        tick = boundTick(tick);
        int32 tickSpacing = spacingOf(tickSpacingExp);

        (uint256 word, uint256 index) = tickToBitmapWordAndIndex(tick, tickSpacingExp);
        int32 calculatedTick = bitmapWordAndIndexToTick(word, index, tickSpacingExp);

        assertLe(calculatedTick, tick);
        assertGt(calculatedTick + tickSpacing, tick);
        assertEq(calculatedTick % tickSpacing, 0);
    }

    function test_tickToBitmapWordAndIndex_zero_tick_always_centered_within_word(uint8 tickSpacingExp) public pure {
        tickSpacingExp = boundTickSpacingExp(tickSpacingExp);
        (, uint256 index) = tickToBitmapWordAndIndex(0, tickSpacingExp);
        assertEq(index, 127, "always centered");
    }

    function test_tickToBitmapWordAndIndex_contiguous_range(int32 tick, uint8 tickSpacingExp) public pure {
        tickSpacingExp = boundTickSpacingExp(tickSpacingExp);
        tick = boundTick(tick);
        int32 tickSpacing = spacingOf(tickSpacingExp);

        (uint256 word, uint256 index) = tickToBitmapWordAndIndex(tick, tickSpacingExp);
        (uint256 wordPrev, uint256 indexPrev) = tickToBitmapWordAndIndex(tick - tickSpacing, tickSpacingExp);
        (uint256 wordNext, uint256 indexNext) = tickToBitmapWordAndIndex(tick + tickSpacing, tickSpacingExp);
        assertGe(word, wordPrev, "word is always increasing");
        assertGe(wordNext, word, "word is always increasing");
        if (wordNext == word) {
            assertGt(indexNext, index, "if in same word, indexNext is greater than index");
        } else {
            assertEq(indexNext, 0, "if in next word, indexNext is always zero");
        }
        if (wordPrev == word) {
            assertGt(index, indexPrev, "if in same word, previous index is less than current index");
        } else {
            assertEq(indexPrev, 255, "if in previous word, previous index is 255");
        }
    }

    function test_tickToBitmapWordAndIndex_results_always_within_bounds(int32 tick, uint8 tickSpacingExp) public pure {
        tickSpacingExp = boundTickSpacingExp(tickSpacingExp);
        tick = boundTick(tick);

        (uint256 word, uint256 index) = tickToBitmapWordAndIndex(tick, tickSpacingExp);
        assertLe(word, type(uint32).max, "word always fits in 32 bits");
        assertLt(index, 256, "index always fits 8 bits");
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

    function test_findNextInitializedTick(int32 tick, uint8 tickSpacingExp) public {
        tickSpacingExp = boundTickSpacingExp(tickSpacingExp);
        tick = boundTick(tick);
        int32 tickSpacing = spacingOf(tickSpacingExp);

        // round toward zero to a multiple on purpose (stays within [MIN_TICK, MAX_TICK])
        tick = (tick / tickSpacing) * tickSpacing;
        assertEq(tick % tickSpacing, 0);

        TickBitmap tbm = new TickBitmap(tickSpacingExp);
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

    function test_maxTickSpacingExp_behavior() public {
        TickBitmap tbm = new TickBitmap(MAX_TICK_SPACING_EXP);
        // at max spacing the range spans two bitmap words, so a full-range search needs skip-ahead,
        // but same-word lookups still need none
        checkPrevTick(tbm, MAX_TICK, 67633152, false, 0);
        checkNextTick(tbm, MIN_TICK, -67108864, false, 0);

        checkPrevTick(tbm, MAX_TICK, MIN_TICK, false, type(uint256).max);
        checkNextTick(tbm, MIN_TICK, MAX_TICK, false, type(uint256).max);

        // MIN_TICK and MAX_TICK are not multiples of the max spacing, so flip the nearest multiples inside the range
        int32 minMultiple = -169 * 524288;
        int32 maxMultiple = 169 * 524288;
        tbm.flip(minMultiple);
        tbm.flip(maxMultiple);
        checkPrevTick(tbm, MAX_TICK - 1, maxMultiple, true, type(uint256).max);
        checkNextTick(tbm, MIN_TICK, minMultiple, true, type(uint256).max);
    }

    function test_findPrevInitializedTick(int32 tick, uint8 tickSpacingExp) public {
        tickSpacingExp = boundTickSpacingExp(tickSpacingExp);
        tick = boundTick(tick);
        int32 tickSpacing_ = spacingOf(tickSpacingExp);

        tick = (tick / tickSpacing_) * tickSpacing_;

        TickBitmap tbm = new TickBitmap(tickSpacingExp);

        tbm.flip(tick);

        checkPrevTick(tbm, tick, tick, true, 0);
    }

    function findTicksInRange(TickBitmap tbm, int32 fromTick, int32 endingTick, uint256 skipAhead)
        private
        view
        returns (int32[] memory finds)
    {
        assert(fromTick != endingTick);
        bool increasing = fromTick < endingTick;
        finds = new int32[](100);
        uint256 count = 0;

        while (true) {
            if (increasing && fromTick > endingTick) break;
            if (!increasing && fromTick < endingTick) break;

            (int32 n, bool i) = increasing ? tbm.next(fromTick, skipAhead) : tbm.prev(fromTick, skipAhead);

            if (i) {
                finds[count++] = n;
            }

            fromTick = increasing ? n : n - 1;
        }

        assembly ("memory-safe") {
            mstore(finds, count)
        }
    }

    function test_ticksAreFoundInRange(uint256 skipAhead) public {
        skipAhead = bound(skipAhead, 0, 128);
        TickBitmap tbm = new TickBitmap(2);

        tbm.flip(-10000);
        tbm.flip(-1000);
        tbm.flip(-20);
        tbm.flip(100);
        tbm.flip(800);
        tbm.flip(9000);

        int32[] memory finds = findTicksInRange(tbm, -15005, 15003, skipAhead);
        assertEq(finds[0], -10000);
        assertEq(finds[1], -1000);
        assertEq(finds[2], -20);
        assertEq(finds[3], 100);
        assertEq(finds[4], 800);
        assertEq(finds[5], 9000);
        assertEq(finds.length, 6);

        finds = findTicksInRange(tbm, 15005, -15003, skipAhead);
        assertEq(finds[5], -10000);
        assertEq(finds[4], -1000);
        assertEq(finds[3], -20);
        assertEq(finds[2], 100);
        assertEq(finds[1], 800);
        assertEq(finds[0], 9000);
        assertEq(finds.length, 6);
    }
}
