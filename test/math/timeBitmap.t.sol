// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

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
        return search(type(uint256).max - 4095, fromTime, untilTime);
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
        time = (time >> 8) << 8;

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

                (uint256 nextFound, bool nextFoundInitialized) = tbm.find(time + 256);
                if (nextFoundInitialized) {
                    assertEq(nextFound, nextTime);
                }

                assertLe(nextFound - time, 65536);
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

        tbm.flip(256);
        vm.snapshotGasLastCall("flip(256) in same map");
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

        tbm.flip(2560);
        tbm.find(0);
        vm.snapshotGasLastCall("next(0) == 2560");
    }

    function test_timeToBitmapWordAndIndex_bitmapWordAndIndexToTime(uint32 time) public pure {
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
        uint256 calculatedTime = bitmapWordAndIndexToTime(word, index);

        assertLe(calculatedTime, time);
        assertLt(time - calculatedTime, 256);
        assertEq(calculatedTime % 256, 0);
    }

    function checkNextTime(TimeBitmap tbm, uint32 fromTime, uint32 expectedTime, bool expectedInitialized)
        private
        view {}

    function test_findNextInitializedTime(uint256 time) public {
        time = (bound(time, 256, type(uint256).max) >> 8) << 8;

        TimeBitmap tbm = new TimeBitmap();
        tbm.flip(time);

        (uint256 nextTime, bool initialized) = tbm.find(time);
        assertEq(nextTime, time);
        assertEq(initialized, true);

        (nextTime, initialized) = tbm.find(time + 255);
        assertEq(nextTime, time);
        assertEq(initialized, true);
    }

    function test_findNextInitializedTime_does_not_wrap() public {
        TimeBitmap tbm = new TimeBitmap();

        (uint256 nextTime, bool initialized) = tbm.find(type(uint256).max);
        assertEq(nextTime, (type(uint256).max >> 8) << 8);
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
            lastVirtualOrderExecutionTime: lastVirtualOrderExecutionTime, fromTime: fromTime, untilTime: currentTime
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

        tbm.flip(256);
        tbm.flip(6 * 256);
        tbm.flip(50 * 256);
        tbm.flip(62 * 256);
        tbm.flip(562 * 256);
        tbm.flip(625 * 256);
        tbm.flip(type(uint32).max - 4095);

        (uint256 time, bool initialized) = tbm.search(0, 512);
        assertEq(time, 256);
        assertTrue(initialized);

        (time, initialized) = tbm.search(6 * 256, 6 * 256 + 64);
        assertEq(time, 6 * 256 + 64);
        assertFalse(initialized);

        (time, initialized) = tbm.search(6 * 256, 31 * 256 + 64);
        assertEq(time, 31 * 256 + 64);
        assertFalse(initialized);

        (time, initialized) = tbm.search(10 * 256 - 10, 31 * 256 + 64);
        assertEq(time, 31 * 256 + 64);
        assertFalse(initialized);

        (time, initialized) = tbm.search(10 * 256 - 10, 62 * 256 + 5181);
        assertEq(time, 50 * 256);
        assertTrue(initialized);

        (time, initialized) = tbm.search(50 * 256, 62 * 256 + 5181);
        assertEq(time, 62 * 256);
        assertTrue(initialized);

        (time, initialized) = tbm.search(93 * 256 + 140, 562 * 256 - 10);
        assertEq(time, 562 * 256 - 10);
        assertFalse(initialized);

        (time, initialized) = tbm.search(93 * 256 + 140, 1000 * 256);
        assertEq(time, 562 * 256);
        assertTrue(initialized);

        (time, initialized) = tbm.search(562 * 256, 625 * 256 - 1);
        assertEq(time, 625 * 256 - 1);
        assertFalse(initialized);

        (time, initialized) = tbm.search(625 * 256 - 1, type(uint32).max);
        assertEq(time, 625 * 256);
        assertTrue(initialized);
    }

    function test_timesAreFoundInRange() public {
        TimeBitmap tbm = new TimeBitmap();

        tbm.flip(256);
        tbm.flip(6 * 256);
        tbm.flip(50 * 256);
        tbm.flip(62 * 256);
        tbm.flip(562 * 256);
        tbm.flip(625 * 256);

        uint256[] memory finds = findTimesInRange(tbm, 0, 240_048);
        assertEq(finds.length, 6, "len");
        assertEq(finds[0], 256, "t0");
        assertEq(finds[1], 6 * 256, "t1");
        assertEq(finds[2], 50 * 256, "t2");
        assertEq(finds[3], 62 * 256, "t3");
        assertEq(finds[4], 562 * 256, "t4");
        assertEq(finds[5], 625 * 256, "t5");
    }
}
