// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {
    timeToBitmapWordAndIndex,
    bitmapWordAndIndexToTime,
    flipTime,
    findNextInitializedTime,
    searchForNextInitializedTime,
    nextValidTime
} from "../../src/math/timeBitmap.sol";
import {Bitmap} from "../../src/types/bitmap.sol";
import {RedBlackTreeLib} from "solady/utils/RedBlackTreeLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {StorageSlot} from "../../src/types/storageSlot.sol";

contract TimeBitmap {
    StorageSlot public constant slot = StorageSlot.wrap(0);

    function isInitialized(uint256 time) public view returns (bool) {
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
        Bitmap bitmap = Bitmap.wrap(uint256(slot.add(word).load()));
        return bitmap.isSet(uint8(index));
    }

    function flip(uint256 time) public {
        flipTime(slot, time);
    }

    function find(uint256 fromTime) public view returns (uint256, bool) {
        return findNextInitializedTime(slot, fromTime);
    }

    function search(uint256 fromTime, uint256 untilTime) public view returns (uint256, bool) {
        return search(type(uint256).max - 255, fromTime, untilTime);
    }

    function search(uint256 lastVirtualOrderExecutionTime, uint256 fromTime, uint256 untilTime)
        public
        view
        returns (uint256, bool)
    {
        return searchForNextInitializedTime(slot, lastVirtualOrderExecutionTime, fromTime, untilTime);
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
                uint256 time = initializedTimes[i] - 1;
                assertTrue(tbm.isInitialized(time));

                // check next from current is this time
                {
                    (uint256 timeNext, bool initialized) = tbm.find(time);
                    assertEq(timeNext, time);
                    assertTrue(initialized);
                }

                // check the next from this time is the time after it
                uint256 nextTime = initializedTimes[(i + 1) % initializedTimes.length] - 1;

                (uint256 nextFound, bool nextFoundInitialized) = tbm.find(time + 16);
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

    /// forge-config: default.isolate = true
    function test_gas_flip() public {
        TimeBitmap tbm = new TimeBitmap();
        tbm.flip(0);
        vm.snapshotGasLastCall("flip(0)");

        tbm.flip(16);
        vm.snapshotGasLastCall("flip(16) in same map");
    }

    /// forge-config: default.isolate = true
    function test_gas_next() public {
        TimeBitmap tbm = new TimeBitmap();
        tbm.find(0);
        vm.snapshotGasLastCall("next(0)");
    }

    /// forge-config: default.isolate = true
    function test_gas_next_set() public {
        TimeBitmap tbm = new TimeBitmap();

        tbm.flip(160);
        tbm.find(0);
        vm.snapshotGasLastCall("next(0) == 160");
    }

    function test_timeToBitmapWordAndIndex_bitmapWordAndIndexToTime(uint32 time) public pure {
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
        uint256 calculatedTime = bitmapWordAndIndexToTime(word, index);

        assertLe(calculatedTime, time);
        assertLt(time - calculatedTime, 16);
        assertEq(calculatedTime % 16, 0);
    }

    function checkNextTime(TimeBitmap tbm, uint32 fromTime, uint32 expectedTime, bool expectedInitialized)
        private
        view
    {}

    function test_findNextInitializedTime(uint256 time) public {
        time = (bound(time, 16, type(uint256).max) >> 4) << 4;

        TimeBitmap tbm = new TimeBitmap();
        tbm.flip(time);

        (uint256 nextTime, bool initialized) = tbm.find(time);
        assertEq(nextTime, time);
        assertEq(initialized, true);

        (nextTime, initialized) = tbm.find(time + 15);
        assertEq(nextTime, time);
        assertEq(initialized, true);
    }

    function test_findNextInitializedTime_does_not_wrap() public {
        TimeBitmap tbm = new TimeBitmap();

        (uint256 nextTime, bool initialized) = tbm.find(type(uint256).max);
        assertEq(nextTime, (type(uint256).max >> 4) << 4);
        assertFalse(initialized);
    }

    function findTimesInRange(TimeBitmap tbm, uint256 fromTime, uint256 endingTime)
        private
        view
        returns (uint256[] memory finds)
    {
        assert(fromTime < endingTime);
        finds = new uint256[](100);
        uint256 count = 0;

        while (fromTime != endingTime) {
            (uint256 n, bool i) = tbm.search(fromTime, endingTime);

            if (i) {
                finds[count++] = n;
            }

            fromTime = n;
        }

        assembly ("memory-safe") {
            mstore(finds, count)
        }
    }

    function test_searchForNextInitializedTime_invariant(
        uint256 currentTime,
        uint256 fromTime,
        uint256 lastVirtualOrderExecutionTime,
        uint256 initializedTime
    ) public {
        currentTime = bound(currentTime, 0, type(uint256).max);

        // must have been executed in last type(uint32).max
        lastVirtualOrderExecutionTime = bound(
            lastVirtualOrderExecutionTime, FixedPointMathLib.zeroFloorSub(currentTime, type(uint32).max), currentTime
        );
        // we are always searching starting at a time between the last virtual execution time and current time
        fromTime = bound(fromTime, lastVirtualOrderExecutionTime, currentTime);
        initializedTime = nextValidTime(
            lastVirtualOrderExecutionTime, bound(initializedTime, lastVirtualOrderExecutionTime, currentTime)
        );

        TimeBitmap tbm = new TimeBitmap();
        tbm.flip(initializedTime);

        (uint256 nextTime, bool initialized) = tbm.search({
            lastVirtualOrderExecutionTime: lastVirtualOrderExecutionTime,
            fromTime: fromTime,
            untilTime: currentTime
        });

        if (initializedTime > fromTime && initializedTime <= currentTime) {
            assertEq(nextTime, initializedTime, "initialized time between from and current");
            assertTrue(initialized, "time is initialized");
        } else {
            assertEq(nextTime, currentTime, "initialized time not between from and current");
            assertFalse(initialized, "time is not initialized");
        }
    }

    function test_searchForNextInitializedTime() public {
        TimeBitmap tbm = new TimeBitmap();

        tbm.flip(16);
        tbm.flip(96);
        tbm.flip(800);
        tbm.flip(992);
        tbm.flip(8_992);
        tbm.flip(10_000);
        tbm.flip(type(uint32).max - 15);

        (uint256 time, bool initialized) = tbm.search(0, 32);
        assertEq(time, 16);
        assertTrue(initialized);

        (time, initialized) = tbm.search(96, 100);
        assertEq(time, 100);
        assertFalse(initialized);

        (time, initialized) = tbm.search(96, 500);
        assertEq(time, 500);
        assertFalse(initialized);

        (time, initialized) = tbm.search(150, 500);
        assertEq(time, 500);
        assertFalse(initialized);

        (time, initialized) = tbm.search(150, 1000);
        assertEq(time, 800);
        assertTrue(initialized);

        (time, initialized) = tbm.search(800, 1000);
        assertEq(time, 992);
        assertTrue(initialized);

        (time, initialized) = tbm.search(1500, 8991);
        assertEq(time, 8_991);
        assertFalse(initialized);

        (time, initialized) = tbm.search(1500, 25000);
        assertEq(time, 8_992);
        assertTrue(initialized);

        (time, initialized) = tbm.search(8_992, 9_999);
        assertEq(time, 9_999);
        assertFalse(initialized);

        (time, initialized) = tbm.search(9_999, type(uint32).max);
        assertEq(time, 10_000);
        assertTrue(initialized);
    }

    function test_timesAreFoundInRange() public {
        TimeBitmap tbm = new TimeBitmap();

        tbm.flip(16);
        tbm.flip(96);
        tbm.flip(800);
        tbm.flip(992);
        tbm.flip(8_992);
        tbm.flip(10_000);

        uint256[] memory finds = findTimesInRange(tbm, 0, 15003);
        assertEq(finds[0], 16);
        assertEq(finds[1], 96);
        assertEq(finds[2], 800);
        assertEq(finds[3], 992);
        assertEq(finds[4], 8_992);
        assertEq(finds[5], 10_000);
        assertEq(finds.length, 6);
    }
}
