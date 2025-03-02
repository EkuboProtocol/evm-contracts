// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {
    timeToBitmapWordAndIndex,
    bitmapWordAndIndexToTime,
    flipTime,
    findNextInitializedTime
} from "../../src/math/timeBitmap.sol";
import {Bitmap} from "../../src/math/bitmap.sol";
import {RedBlackTreeLib} from "solady/utils/RedBlackTreeLib.sol";

contract TimeBitmap {
    mapping(uint256 => Bitmap) public map;

    function isInitialized(uint32 time) public view returns (bool) {
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
        return map[word].isSet(uint8(index));
    }

    function flip(uint32 time) public {
        flipTime(map, time);
    }

    function next(uint32 fromTime) public view returns (uint32, bool) {
        return findNextInitializedTime(map, fromTime);
    }
}

contract TimeBitmapHandler is StdUtils, StdAssertions {
    using RedBlackTreeLib for *;

    TimeBitmap tbm;

    RedBlackTreeLib.Tree tree;

    constructor(TimeBitmap _tbm) {
        tbm = _tbm;
    }

    function flip(uint32 time) public {
        time = (time >> 4) << 4;

        tbm.flip(time);
        if (tbm.isInitialized(time)) {
            tree.insert(uint256(time) + 1);
        } else {
            tree.remove(uint256(time) + 1);
        }
    }

    function checkAllTimesMatchRedBlackTree() public view {
        unchecked {
            uint256[] memory initializedTimes = tree.values();

            for (uint256 i = 0; i < initializedTimes.length; i++) {
                uint32 time = uint32(initializedTimes[i] - 1);
                assertTrue(tbm.isInitialized(time));

                // check next from one second before equals this time
                {
                    (uint32 timeNext, bool initialized) = tbm.next(time - 1);
                    assertEq(timeNext, time);
                    assertTrue(initialized);
                }

                // check the next from this time is the time after it
                uint32 nextTime = uint32(initializedTimes[(i + 1) % initializedTimes.length] - 1);

                (uint32 nextFound, bool nextFoundInitialized) = tbm.next(time);
                if (nextFoundInitialized) {
                    assertEq(nextFound, nextTime);
                }

                assertLe(nextFound - time, 4096);
            }
        }
    }
}

contract TimeBitmapInvariantTest is Test {
    TimeBitmapHandler tbh;

    function setUp() public {
        TimeBitmap tbm = new TimeBitmap();
        excludeContract(address(tbm));
        tbh = new TimeBitmapHandler(tbm);
    }

    function invariant_checkAllTimesMatchRedBlackTree() public view {
        tbh.checkAllTimesMatchRedBlackTree();
    }
}

contract TimeBitmapTest is Test {
    function test_gas_timeToBitmapWordAndIndex() public returns (uint256 word, uint256 index) {
        vm.startSnapshotGas("timeToBitmapWordAndIndex(150)");
        (word, index) = timeToBitmapWordAndIndex(150);
        vm.stopSnapshotGas();
    }

    function test_gas_flip() public {
        TimeBitmap tbm = new TimeBitmap();
        tbm.flip(0);
        vm.snapshotGasLastCall("flip(0)");
    }

    function test_gas_next() public {
        TimeBitmap tbm = new TimeBitmap();
        tbm.next(0);
        vm.snapshotGasLastCall("next(0)");
    }

    function test_gas_next_set() public {
        TimeBitmap tbm = new TimeBitmap();

        tbm.flip(160);
        tbm.next(0);
        vm.snapshotGasLastCall("next(0) == 160");
    }

    function test_timeToBitmapWordAndIndex_bitmapWordAndIndexToTime(uint32 time) public pure {
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
        uint32 calculatedTime = bitmapWordAndIndexToTime(word, index);

        assertLe(calculatedTime, time);
        assertLt(time - calculatedTime, 16);
        assertEq(calculatedTime % 16, 0);
    }

    function checkNextTime(TimeBitmap tbm, uint32 fromTime, uint32 expectedTime, bool expectedInitialized)
        private
        view
    {}

    function test_findNextInitializedTime(uint32 time) public {
        time = (time >> 4) << 4;
        vm.assume(time != 0);

        TimeBitmap tbm = new TimeBitmap();
        tbm.flip(time);

        (uint32 nextTime, bool initialized) = tbm.next(time - 1);
        assertEq(nextTime, time);
        assertEq(initialized, true);
    }

    function test_findNextInitializedTime_wraps_initialized() public {
        TimeBitmap tbm = new TimeBitmap();
        tbm.flip(0);

        (uint32 nextTime, bool initialized) = tbm.next(type(uint32).max);
        assertEq(nextTime, 0);
        assertTrue(initialized);
    }

    function test_findNextInitializedTime_wraps_initialized_middle() public {
        TimeBitmap tbm = new TimeBitmap();
        tbm.flip(2032);

        (uint32 nextTime, bool initialized) = tbm.next(type(uint32).max);
        assertEq(nextTime, 2032);
        assertTrue(initialized);
    }

    function test_findNextInitializedTime_wraps_not_initialized() public {
        TimeBitmap tbm = new TimeBitmap();

        (uint32 nextTime, bool initialized) = tbm.next(type(uint32).max);
        assertEq(nextTime, 4080);
        assertFalse(initialized);
    }

    function test_findNextInitializedTime_wraps_less_than_max() public {
        TimeBitmap tbm = new TimeBitmap();

        (uint32 nextTime, bool initialized) = tbm.next(type(uint32).max - 16);
        assertEq(nextTime, type(uint32).max - 15);
        assertFalse(initialized);
    }

    function test_findNextInitializedTime_wraps_less_than_max_2() public {
        TimeBitmap tbm = new TimeBitmap();

        (uint32 nextTime, bool initialized) = tbm.next(type(uint32).max - 15);
        assertEq(nextTime, 4080);
        assertFalse(initialized);
    }

    function findTimesInRange(TimeBitmap tbm, uint32 fromTime, uint32 endingTime)
        private
        view
        returns (uint32[] memory finds)
    {
        assert(fromTime < endingTime);
        finds = new uint32[](100);
        uint256 count = 0;

        while (true) {
            if (fromTime > endingTime) break;

            (uint32 n, bool i) = tbm.next(fromTime);

            if (i) {
                finds[count++] = n;
            }

            fromTime = n;
        }

        assembly ("memory-safe") {
            mstore(finds, count)
        }
    }

    function test_timesAreFoundInRange() public {
        TimeBitmap tbm = new TimeBitmap();

        tbm.flip(16);
        tbm.flip(96);
        tbm.flip(800);
        tbm.flip(992);
        tbm.flip(8_992);
        tbm.flip(10_000);

        uint32[] memory finds = findTimesInRange(tbm, 0, 15003);
        assertEq(finds[0], 16);
        assertEq(finds[1], 96);
        assertEq(finds[2], 800);
        assertEq(finds[3], 992);
        assertEq(finds[4], 8_992);
        assertEq(finds[5], 10_000);
        assertEq(finds.length, 6);
    }
}
