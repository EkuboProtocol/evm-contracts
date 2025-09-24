// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

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
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING} from "../../src/math/constants.sol";
import {RedBlackTreeLib} from "solady/utils/RedBlackTreeLib.sol";

contract TickBitmap {
    bytes32 public constant storageOffset = 0;
    // we use an immutable because this is a constraint that the bitmap expects
    uint32 public immutable tickSpacing;

    constructor(uint32 _tickSpacing) {
        assert(_tickSpacing <= MAX_TICK_SPACING);
        assert(_tickSpacing > 0);
        tickSpacing = _tickSpacing;
    }

    function isInitialized(int32 tick) public view returns (bool) {
        assert(tick % int32(tickSpacing) == 0);
        (uint256 word, uint256 index) = tickToBitmapWordAndIndex(tick, tickSpacing);
        return loadBitmap(storageOffset, word).isSet(uint8(index));
    }

    function flip(int32 tick) public {
        // this is an expectation for how the bitmap is used in core
        require((tick % int32(tickSpacing)) == 0, "mod");
        require(tick <= MAX_TICK, "max");
        require(tick >= MIN_TICK, "min");
        flipTick(storageOffset, tick, tickSpacing);
    }

    function next(int32 fromTick) public view returns (int32, bool) {
        return next(fromTick, 0);
    }

    function next(int32 fromTick, uint256 skipAhead) public view returns (int32, bool) {
        return findNextInitializedTick(storageOffset, fromTick, tickSpacing, skipAhead);
    }

    function prev(int32 fromTick) public view returns (int32, bool) {
        return prev(fromTick, 0);
    }

    function prev(int32 fromTick, uint256 skipAhead) public view returns (int32, bool) {
        return findPrevInitializedTick(storageOffset, fromTick, tickSpacing, skipAhead);
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
        int32 ts = int32(tbm.tickSpacing());
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
        TickBitmap tbm = new TickBitmap(100);
        excludeContract(address(tbm));
        tbh = new TickBitmapHandler(tbm);
    }

    function invariant_checkAllTicksMatchRedBlackTree() public view {
        tbh.checkAllTicksMatchRedBlackTree();
    }
}

contract TickBitmapTest is Test {
    function test_gas_tickToBitmapWordAndIndex() public returns (uint256 word, uint256 index) {
        vm.startSnapshotGas("tickToBitmapWordAndIndex(150,100)");
        (word, index) = tickToBitmapWordAndIndex(150, 100);
        vm.stopSnapshotGas();
    }

    function test_gas_next_entire_map() public {
        TickBitmap tbm = new TickBitmap(100);
        // incurs about ~6930 sloads which is 14553000 gas minimum
        (int32 t, bool i) = tbm.next(MIN_TICK, type(uint256).max);
        vm.snapshotGasLastCall("ts = 100, next(MIN_TICK, type(uint256).max)");
        assertEq(t, MAX_TICK);
        assertFalse(i);
    }

    function test_gas_prev_entire_map() public {
        TickBitmap tbm = new TickBitmap(100);
        // incurs about ~6930 sloads which is 14553000 gas minimum
        (int32 t, bool i) = tbm.prev(MAX_TICK, type(uint256).max);
        vm.snapshotGasLastCall("ts = 100, prev(MAX_TICK, type(uint256).max)");
        assertEq(t, MIN_TICK);
        assertFalse(i);
    }

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

    function test_gas_next_set() public {
        TickBitmap tbm = new TickBitmap(100);

        tbm.flip(3000);
        tbm.next(0);
        vm.snapshotGasLastCall("next(0) == 3000");
    }

    function test_gas_prev() public {
        TickBitmap tbm = new TickBitmap(100);

        tbm.prev(0);
        vm.snapshotGasLastCall("prev(0)");
    }

    function test_gas_prev_set() public {
        TickBitmap tbm = new TickBitmap(100);

        tbm.flip(-3000);
        tbm.prev(0);
        vm.snapshotGasLastCall("prev(0) == -3000");
    }

    function boundTick(int32 tick) private pure returns (int32) {
        return int32(bound(tick, MIN_TICK, MAX_TICK));
    }

    function boundTickSpacing(uint32 tickSpacing) private pure returns (uint32) {
        return uint32(bound(tickSpacing, 1, MAX_TICK_SPACING));
    }

    function assertTbwi(int32 tick, uint32 tickSpacing, uint256 expectedWord, uint256 expectedIndex) public pure {
        (uint256 word, uint256 index) = tickToBitmapWordAndIndex(tick, tickSpacing);
        assertEq(word, expectedWord);
        assertEq(index, expectedIndex);
    }

    function test_tickToBitmapWordAndIndex(uint32 tickSpacing) public pure {
        // regardless of tick spacing, the 0 tick is in the middle of a word
        tickSpacing = boundTickSpacing(tickSpacing);
        int32 mul = int32(tickSpacing);

        uint256 word = 349303;
        assertTbwi(0, tickSpacing, word, 127);
        // positive ticks
        assertTbwi(mul - 1, tickSpacing, word, 127);
        assertTbwi(mul, tickSpacing, word, 128);
        assertTbwi((mul * 127) + (mul - 1), tickSpacing, word, 254);
        assertTbwi(mul * 128, tickSpacing, word, 255);
        assertTbwi(mul * 128 + (mul - 1), tickSpacing, word, 255);
        assertTbwi(mul * 129, tickSpacing, word + 1, 0);

        // negative ticks
        assertTbwi(-1, tickSpacing, word, 126);
        assertTbwi(-mul, tickSpacing, word, 126);
        assertTbwi(-mul * 126, tickSpacing, word, 1);
        assertTbwi(-mul * 127, tickSpacing, word, 0);
        assertTbwi((-mul * 127) - 1, tickSpacing, word - 1, 255);
    }

    function test_tickToBitmapWordAndIndex_min_max_values() public pure {
        // min/max tick are in a single bitmap at max tick spacing
        assertTbwi(MAX_TICK, MAX_TICK_SPACING, 349303, 254);
        assertTbwi(MIN_TICK, MAX_TICK_SPACING, 349303, 0);
    }

    function test_tickToBitmapWordAndIndex_bitmapWordAndIndexToTick(int32 tick, uint32 tickSpacing) public pure {
        (tick, tickSpacing) = (boundTick(tick), boundTickSpacing(tickSpacing));

        (uint256 word, uint256 index) = tickToBitmapWordAndIndex(tick, tickSpacing);
        int32 calculatedTick = bitmapWordAndIndexToTick(word, index, tickSpacing);

        assertLe(calculatedTick, tick);
        assertGt(calculatedTick + int32(tickSpacing), tick);
        assertEq(calculatedTick % int32(tickSpacing), 0);
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
        (tick, tickSpacing) = (boundTick(tick), boundTickSpacing(tickSpacing));

        // rounds towards zero on purpose
        tick = (tick / int32(tickSpacing)) * int32(tickSpacing);

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
        (tick, tickSpacing) = (boundTick(tick), boundTickSpacing(tickSpacing));

        tick = (tick / int32(tickSpacing)) * int32(tickSpacing);

        TickBitmap tbm = new TickBitmap(tickSpacing);

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
        TickBitmap tbm = new TickBitmap(10);

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
