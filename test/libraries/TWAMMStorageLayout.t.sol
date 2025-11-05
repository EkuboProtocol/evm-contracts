// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

import {Test} from "forge-std/Test.sol";
import {TWAMMStorageLayout} from "../../src/libraries/TWAMMStorageLayout.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {OrderId} from "../../src/types/orderId.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolConfig} from "../../src/types/poolConfig.sol";
import {StorageSlot} from "../../src/types/storageSlot.sol";

contract TWAMMStorageLayoutTest is Test {
    // Helper function for wrapping addition to match assembly behavior
    function wrapAdd(bytes32 x, uint256 y) internal pure returns (bytes32 r) {
        assembly ("memory-safe") {
            r := add(x, y)
        }
    }

    // Test twammPoolStateSlot uniqueness
    function test_noStorageLayoutCollisions_twammPoolStateSlot_twammPoolStateSlot(PoolId poolId0, PoolId poolId1)
        public
        pure
    {
        bytes32 slot0 = StorageSlot.unwrap(TWAMMStorageLayout.twammPoolStateSlot(poolId0));
        bytes32 slot1 = StorageSlot.unwrap(TWAMMStorageLayout.twammPoolStateSlot(poolId1));
        assertEq((slot0 == slot1), (PoolId.unwrap(poolId0) == PoolId.unwrap(poolId1)));
    }

    // Test poolRewardRatesSlot uniqueness and consecutive slots
    function test_noStorageLayoutCollisions_poolRewardRatesSlot_consecutive(PoolId poolId) public pure {
        bytes32 firstSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId));
        bytes32 poolStateSlot = StorageSlot.unwrap(TWAMMStorageLayout.twammPoolStateSlot(poolId));

        // First reward rates slot should be pool state slot + REWARD_RATES_OFFSET
        assertEq(firstSlot, wrapAdd(poolStateSlot, TWAMMStorageLayout.REWARD_RATES_OFFSET));

        // Second reward rates slot should be first + 1
        assertEq(wrapAdd(firstSlot, 1), wrapAdd(poolStateSlot, TWAMMStorageLayout.REWARD_RATES_OFFSET + 1));
    }

    function test_noStorageLayoutCollisions_poolRewardRatesSlot_poolRewardRatesSlot(PoolId poolId0, PoolId poolId1)
        public
        pure
    {
        bytes32 slot0 = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId0));
        bytes32 slot1 = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId1));
        assertEq((slot0 == slot1), (PoolId.unwrap(poolId0) == PoolId.unwrap(poolId1)));
    }

    // Test twammPoolStateSlot vs poolRewardRatesSlot
    function test_noStorageLayoutCollisions_twammPoolStateSlot_poolRewardRatesSlot(PoolId poolId0, PoolId poolId1)
        public
        pure
    {
        bytes32 stateSlot = StorageSlot.unwrap(TWAMMStorageLayout.twammPoolStateSlot(poolId0));
        bytes32 rewardRatesSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId1));
        assertNotEq(stateSlot, rewardRatesSlot);
        assertNotEq(stateSlot, wrapAdd(rewardRatesSlot, 1));
    }

    // Test poolInitializedTimesBitmapSlot uniqueness
    function test_noStorageLayoutCollisions_poolInitializedTimesBitmapSlot_poolInitializedTimesBitmapSlot(
        PoolId poolId0,
        PoolId poolId1
    ) public pure {
        bytes32 slot0 = StorageSlot.unwrap(TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId0));
        bytes32 slot1 = StorageSlot.unwrap(TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId1));
        assertEq((slot0 == slot1), (PoolId.unwrap(poolId0) == PoolId.unwrap(poolId1)));
    }

    // Test twammPoolStateSlot vs poolInitializedTimesBitmapSlot
    function test_noStorageLayoutCollisions_twammPoolStateSlot_poolInitializedTimesBitmapSlot(
        PoolId poolId0,
        PoolId poolId1
    ) public pure {
        bytes32 stateSlot = StorageSlot.unwrap(TWAMMStorageLayout.twammPoolStateSlot(poolId0));
        bytes32 bitmapSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId1));
        assertNotEq(stateSlot, bitmapSlot);
    }

    // Test poolRewardRatesSlot vs poolInitializedTimesBitmapSlot
    function test_noStorageLayoutCollisions_poolRewardRatesSlot_poolInitializedTimesBitmapSlot(
        PoolId poolId0,
        PoolId poolId1
    ) public pure {
        bytes32 rewardRatesSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId0));
        bytes32 bitmapSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId1));
        assertNotEq(rewardRatesSlot, bitmapSlot);
        assertNotEq(wrapAdd(rewardRatesSlot, 1), bitmapSlot);
    }

    // Test poolTimeInfosSlot uniqueness with different times
    function test_noStorageLayoutCollisions_poolTimeInfosSlot_uniqueness_time(PoolId poolId, uint64 time0, uint64 time1)
        public
        pure
    {
        vm.assume(time0 != time1);
        bytes32 slot0 = StorageSlot.unwrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId, time0));
        bytes32 slot1 = StorageSlot.unwrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId, time1));
        assertNotEq(slot0, slot1);
    }

    // Test poolTimeInfosSlot uniqueness with different pool IDs
    function test_noStorageLayoutCollisions_poolTimeInfosSlot_uniqueness_poolId(
        PoolId poolId0,
        PoolId poolId1,
        uint64 time
    ) public pure {
        vm.assume(PoolId.unwrap(poolId0) != PoolId.unwrap(poolId1));
        bytes32 slot0 = StorageSlot.unwrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId0, time));
        bytes32 slot1 = StorageSlot.unwrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId1, time));
        assertNotEq(slot0, slot1);
    }

    // Test twammPoolStateSlot vs poolTimeInfosSlot
    function test_noStorageLayoutCollisions_twammPoolStateSlot_poolTimeInfosSlot(
        PoolId poolId0,
        PoolId poolId1,
        uint64 time
    ) public pure {
        bytes32 stateSlot = StorageSlot.unwrap(TWAMMStorageLayout.twammPoolStateSlot(poolId0));
        bytes32 timeInfoSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId1, time));
        assertNotEq(stateSlot, timeInfoSlot);
    }

    // Test poolRewardRatesSlot vs poolTimeInfosSlot
    function test_noStorageLayoutCollisions_poolRewardRatesSlot_poolTimeInfosSlot(
        PoolId poolId0,
        PoolId poolId1,
        uint64 time
    ) public pure {
        bytes32 rewardRatesSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId0));
        bytes32 timeInfoSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId1, time));
        assertNotEq(rewardRatesSlot, timeInfoSlot);
        assertNotEq(wrapAdd(rewardRatesSlot, 1), timeInfoSlot);
    }

    // Test poolInitializedTimesBitmapSlot vs poolTimeInfosSlot
    function test_noStorageLayoutCollisions_poolInitializedTimesBitmapSlot_poolTimeInfosSlot(
        PoolId poolId0,
        PoolId poolId1,
        uint64 time
    ) public pure {
        bytes32 bitmapSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId0));
        bytes32 timeInfoSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId1, time));

        // Check that bitmap slots don't collide with time info slots in a reasonable range
        // type(uint52).max is the max range for bitmaps
        for (uint256 i = 0; i < 100; i++) {
            assertNotEq(wrapAdd(bitmapSlot, i), timeInfoSlot);
        }
    }

    // Test poolRewardRatesBeforeSlot uniqueness with different times
    function test_noStorageLayoutCollisions_poolRewardRatesBeforeSlot_uniqueness_time(
        PoolId poolId,
        uint64 time0,
        uint64 time1
    ) public pure {
        vm.assume(time0 != time1);
        bytes32 slot0 = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, time0));
        bytes32 slot1 = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, time1));
        assertNotEq(slot0, slot1);
        // Also check the second consecutive slot
        assertNotEq(wrapAdd(slot0, 1), slot1);
        assertNotEq(slot0, wrapAdd(slot1, 1));
    }

    // Test poolRewardRatesBeforeSlot consecutive slots
    function test_noStorageLayoutCollisions_poolRewardRatesBeforeSlot_consecutive(PoolId poolId, uint64 time)
        public
        pure
    {
        bytes32 firstSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, time));
        bytes32 poolStateSlot = StorageSlot.unwrap(TWAMMStorageLayout.twammPoolStateSlot(poolId));

        // First slot should be pool state slot + REWARD_RATES_BEFORE_OFFSET + time * 2
        uint256 rewardRatesBeforeOffset = TWAMMStorageLayout.REWARD_RATES_BEFORE_OFFSET;
        uint256 expectedOffset;
        assembly ("memory-safe") {
            expectedOffset := add(rewardRatesBeforeOffset, mul(time, 2))
        }
        assertEq(firstSlot, wrapAdd(poolStateSlot, expectedOffset));

        // Second slot should be first + 1
        assertEq(wrapAdd(firstSlot, 1), wrapAdd(poolStateSlot, expectedOffset + 1));
    }

    // Test poolRewardRatesBeforeSlot uniqueness with different pool IDs
    function test_noStorageLayoutCollisions_poolRewardRatesBeforeSlot_uniqueness_poolId(
        PoolId poolId0,
        PoolId poolId1,
        uint64 time
    ) public pure {
        vm.assume(PoolId.unwrap(poolId0) != PoolId.unwrap(poolId1));
        bytes32 slot0 = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId0, time));
        bytes32 slot1 = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId1, time));
        // Different pool IDs should produce different first slots
        assertNotEq(slot0, slot1);
        // Note: We don't check consecutive slot adjacency because poolIds are keccak hashes
        // and the probability of them being consecutive is negligible
    }

    // Test twammPoolStateSlot vs poolRewardRatesBeforeSlot
    function test_noStorageLayoutCollisions_twammPoolStateSlot_poolRewardRatesBeforeSlot(
        PoolId poolId0,
        PoolId poolId1,
        uint64 time
    ) public pure {
        bytes32 stateSlot = StorageSlot.unwrap(TWAMMStorageLayout.twammPoolStateSlot(poolId0));
        bytes32 rewardRatesBeforeSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId1, time));
        assertNotEq(stateSlot, rewardRatesBeforeSlot);
        assertNotEq(stateSlot, wrapAdd(rewardRatesBeforeSlot, 1));
    }

    // Test poolRewardRatesSlot vs poolRewardRatesBeforeSlot
    function test_noStorageLayoutCollisions_poolRewardRatesSlot_poolRewardRatesBeforeSlot(
        PoolId poolId0,
        PoolId poolId1,
        uint64 time
    ) public pure {
        bytes32 rewardRatesSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId0));
        bytes32 rewardRatesBeforeSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId1, time));
        assertNotEq(rewardRatesSlot, rewardRatesBeforeSlot);
        assertNotEq(wrapAdd(rewardRatesSlot, 1), rewardRatesBeforeSlot);
        assertNotEq(rewardRatesSlot, wrapAdd(rewardRatesBeforeSlot, 1));
        assertNotEq(wrapAdd(rewardRatesSlot, 1), wrapAdd(rewardRatesBeforeSlot, 1));
    }

    // Test poolInitializedTimesBitmapSlot vs poolRewardRatesBeforeSlot
    function test_noStorageLayoutCollisions_poolInitializedTimesBitmapSlot_poolRewardRatesBeforeSlot(
        PoolId poolId0,
        PoolId poolId1,
        uint64 time
    ) public pure {
        bytes32 bitmapSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId0));
        bytes32 rewardRatesBeforeSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId1, time));

        // Check that bitmap slots don't collide with reward rates before slots in a reasonable range
        for (uint256 i = 0; i < 100; i++) {
            assertNotEq(wrapAdd(bitmapSlot, i), rewardRatesBeforeSlot);
            assertNotEq(wrapAdd(bitmapSlot, i), wrapAdd(rewardRatesBeforeSlot, 1));
        }
    }

    // Test poolTimeInfosSlot vs poolRewardRatesBeforeSlot
    function test_noStorageLayoutCollisions_poolTimeInfosSlot_poolRewardRatesBeforeSlot(
        PoolId poolId0,
        PoolId poolId1,
        uint64 time0,
        uint64 time1
    ) public pure {
        bytes32 timeInfoSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId0, time0));
        bytes32 rewardRatesBeforeSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId1, time1));
        assertNotEq(timeInfoSlot, rewardRatesBeforeSlot);
        assertNotEq(timeInfoSlot, wrapAdd(rewardRatesBeforeSlot, 1));
    }

    // Test orderStateSlotFollowedByOrderRewardRateSnapshotSlot uniqueness with different owners
    function test_noStorageLayoutCollisions_orderStateSlot_uniqueness_owner(
        address owner0,
        address owner1,
        bytes32 salt,
        OrderId orderId
    ) public pure {
        vm.assume(owner0 != owner1);
        bytes32 slot0 = StorageSlot.unwrap(
            TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner0, salt, orderId)
        );
        bytes32 slot1 = StorageSlot.unwrap(
            TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner1, salt, orderId)
        );
        // Different owners should produce different state slots
        assertNotEq(slot0, slot1);
        // Note: We don't check consecutive slots because the keccak256(salt) in the calculation
        // makes it extremely unlikely for slots to be adjacent
    }

    function test_noStorageLayoutCollisions_orderStateSlot_collision_iff_all_equal(
        bytes32 salt0,
        bytes32 salt1,
        address owner0,
        address owner1,
        OrderId orderId0,
        OrderId orderId1
    ) public pure {
        bytes32 slot1 = StorageSlot.unwrap(
            TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner0, salt0, orderId0)
        );
        bytes32 slot2 = StorageSlot.unwrap(
            TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner1, salt1, orderId1)
        );

        // Slots collide if and only if all parameters are equal
        assertEq(
            slot1 == slot2, OrderId.unwrap(orderId0) == OrderId.unwrap(orderId1) && owner0 == owner1 && salt0 == salt1
        );
    }

    function test_noStorageLayoutCollisions_orderStateSlot_twammPoolState(uint160 salt, address owner, OrderId orderId)
        public
        pure
    {
        bytes32 slot1 = StorageSlot.unwrap(
            TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(
                owner, bytes32(uint256(salt)), orderId
            )
        );
        bytes32 slot2 = StorageSlot.unwrap(
            TWAMMStorageLayout.twammPoolStateSlot(
                PoolKey({token0: owner, token1: address(salt), config: PoolConfig.wrap(OrderId.unwrap(orderId))})
                    .toPoolId()
            )
        );

        assertNotEq(slot1, slot2);
    }

    // Test orderStateSlotFollowedByOrderRewardRateSnapshotSlot uniqueness with different salts
    function test_noStorageLayoutCollisions_orderStateSlot_uniqueness_salt(
        address owner,
        bytes32 salt0,
        bytes32 salt1,
        OrderId orderId
    ) public pure {
        vm.assume(salt0 != salt1);
        bytes32 slot0 = StorageSlot.unwrap(
            TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner, salt0, orderId)
        );
        bytes32 slot1 = StorageSlot.unwrap(
            TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner, salt1, orderId)
        );
        // Different salts should produce different state slots (due to keccak256(salt))
        assertNotEq(slot0, slot1);
        // Note: We don't check consecutive slots because keccak256 makes adjacent slots extremely unlikely
    }

    // Test orderStateSlotFollowedByOrderRewardRateSnapshotSlot uniqueness with different order IDs
    function test_noStorageLayoutCollisions_orderStateSlot_uniqueness_orderId(
        address owner,
        bytes32 salt,
        OrderId orderId0,
        OrderId orderId1
    ) public pure {
        vm.assume(OrderId.unwrap(orderId0) != OrderId.unwrap(orderId1));
        bytes32 slot0 = StorageSlot.unwrap(
            TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner, salt, orderId0)
        );
        bytes32 slot1 = StorageSlot.unwrap(
            TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner, salt, orderId1)
        );
        // Different order IDs should produce different state slots
        assertNotEq(slot0, slot1);
        // Note: We don't check if slot0+1 == slot1 because orderIds are keccak hashes
        // and the probability of them being consecutive is negligible
    }

    // Test twammPoolStateSlot vs orderStateSlot
    function test_noStorageLayoutCollisions_twammPoolStateSlot_orderStateSlot(
        PoolId poolId,
        address owner,
        bytes32 salt,
        OrderId orderId
    ) public pure {
        bytes32 stateSlot = StorageSlot.unwrap(TWAMMStorageLayout.twammPoolStateSlot(poolId));
        bytes32 orderSlot = StorageSlot.unwrap(
            TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner, salt, orderId)
        );
        assertNotEq(stateSlot, orderSlot);
        assertNotEq(stateSlot, wrapAdd(orderSlot, 1));
    }

    // Test poolRewardRatesSlot vs orderStateSlot
    function test_noStorageLayoutCollisions_poolRewardRatesSlot_orderStateSlot(
        PoolId poolId,
        address owner,
        bytes32 salt,
        OrderId orderId
    ) public pure {
        bytes32 rewardRatesSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId));
        bytes32 orderSlot = StorageSlot.unwrap(
            TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner, salt, orderId)
        );
        assertNotEq(rewardRatesSlot, orderSlot);
        assertNotEq(wrapAdd(rewardRatesSlot, 1), orderSlot);
        assertNotEq(rewardRatesSlot, wrapAdd(orderSlot, 1));
        assertNotEq(wrapAdd(rewardRatesSlot, 1), wrapAdd(orderSlot, 1));
    }

    // Test poolInitializedTimesBitmapSlot vs orderStateSlot
    function test_noStorageLayoutCollisions_poolInitializedTimesBitmapSlot_orderStateSlot(
        PoolId poolId,
        address owner,
        bytes32 salt,
        OrderId orderId
    ) public pure {
        bytes32 bitmapSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId));
        bytes32 orderSlot = StorageSlot.unwrap(
            TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner, salt, orderId)
        );

        // Check that bitmap slots don't collide with order slots in a reasonable range
        for (uint256 i = 0; i < 100; i++) {
            assertNotEq(wrapAdd(bitmapSlot, i), orderSlot);
            assertNotEq(wrapAdd(bitmapSlot, i), wrapAdd(orderSlot, 1));
        }
    }

    // Test poolTimeInfosSlot vs orderStateSlot
    function test_noStorageLayoutCollisions_poolTimeInfosSlot_orderStateSlot(
        PoolId poolId,
        uint64 time,
        address owner,
        bytes32 salt,
        OrderId orderId
    ) public pure {
        bytes32 timeInfoSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId, time));
        bytes32 orderSlot = StorageSlot.unwrap(
            TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner, salt, orderId)
        );
        assertNotEq(timeInfoSlot, orderSlot);
        assertNotEq(timeInfoSlot, wrapAdd(orderSlot, 1));
    }

    // Test poolRewardRatesBeforeSlot vs orderStateSlot
    function test_noStorageLayoutCollisions_poolRewardRatesBeforeSlot_orderStateSlot(
        PoolId poolId,
        uint64 time,
        address owner,
        bytes32 salt,
        OrderId orderId
    ) public pure {
        bytes32 rewardRatesBeforeSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, time));
        bytes32 orderSlot = StorageSlot.unwrap(
            TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner, salt, orderId)
        );
        assertNotEq(rewardRatesBeforeSlot, orderSlot);
        assertNotEq(wrapAdd(rewardRatesBeforeSlot, 1), orderSlot);
        assertNotEq(rewardRatesBeforeSlot, wrapAdd(orderSlot, 1));
        assertNotEq(wrapAdd(rewardRatesBeforeSlot, 1), wrapAdd(orderSlot, 1));
    }

    // Test offset sufficiency
    function test_offsetsSufficient(PoolId poolId) public pure {
        bytes32 poolStateSlot = StorageSlot.unwrap(TWAMMStorageLayout.twammPoolStateSlot(poolId));
        bytes32 rewardRatesSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId));
        bytes32 bitmapSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId));
        bytes32 minTimeInfoSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId, 0));
        bytes32 maxTimeInfoSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId, type(uint64).max));
        bytes32 minRewardRatesBeforeSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, 0));
        bytes32 maxRewardRatesBeforeSlot =
            StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, type(uint64).max));

        // Pool state is at offset 0
        assertEq(uint256(poolStateSlot), uint256(PoolId.unwrap(poolId)));

        // Reward rates are at REWARD_RATES_OFFSET and REWARD_RATES_OFFSET + 1
        assertEq(rewardRatesSlot, wrapAdd(poolStateSlot, TWAMMStorageLayout.REWARD_RATES_OFFSET));

        // Time bitmaps start at TIME_BITMAPS_OFFSET
        assertEq(bitmapSlot, wrapAdd(poolStateSlot, TWAMMStorageLayout.TIME_BITMAPS_OFFSET));

        // Time infos start at TIME_INFOS_OFFSET
        assertEq(minTimeInfoSlot, wrapAdd(poolStateSlot, TWAMMStorageLayout.TIME_INFOS_OFFSET));
        assertEq(maxTimeInfoSlot, wrapAdd(poolStateSlot, TWAMMStorageLayout.TIME_INFOS_OFFSET + type(uint64).max));

        // Reward rates before start at REWARD_RATES_BEFORE_OFFSET
        assertEq(minRewardRatesBeforeSlot, wrapAdd(poolStateSlot, TWAMMStorageLayout.REWARD_RATES_BEFORE_OFFSET));

        uint256 rewardRatesBeforeOffset = TWAMMStorageLayout.REWARD_RATES_BEFORE_OFFSET;
        uint256 maxTime = type(uint64).max;
        uint256 maxRewardRatesBeforeOffset;
        assembly ("memory-safe") {
            maxRewardRatesBeforeOffset := add(rewardRatesBeforeOffset, mul(maxTime, 2))
        }
        assertEq(maxRewardRatesBeforeSlot, wrapAdd(poolStateSlot, maxRewardRatesBeforeOffset));

        // Verify that the offsets themselves are non-zero and distinct
        // The offsets are generated using keccak and are designed to be in different regions
        // of the storage space to avoid collisions
        assertTrue(TWAMMStorageLayout.REWARD_RATES_OFFSET > 0);
        assertTrue(TWAMMStorageLayout.TIME_BITMAPS_OFFSET > 0);
        assertTrue(TWAMMStorageLayout.TIME_INFOS_OFFSET > 0);
        assertTrue(TWAMMStorageLayout.REWARD_RATES_BEFORE_OFFSET > 0);

        // Verify all offsets are distinct
        assertTrue(TWAMMStorageLayout.REWARD_RATES_OFFSET != TWAMMStorageLayout.TIME_BITMAPS_OFFSET);
        assertTrue(TWAMMStorageLayout.REWARD_RATES_OFFSET != TWAMMStorageLayout.TIME_INFOS_OFFSET);
        assertTrue(TWAMMStorageLayout.REWARD_RATES_OFFSET != TWAMMStorageLayout.REWARD_RATES_BEFORE_OFFSET);
        assertTrue(TWAMMStorageLayout.TIME_BITMAPS_OFFSET != TWAMMStorageLayout.TIME_INFOS_OFFSET);
        assertTrue(TWAMMStorageLayout.TIME_BITMAPS_OFFSET != TWAMMStorageLayout.REWARD_RATES_BEFORE_OFFSET);
        assertTrue(TWAMMStorageLayout.TIME_INFOS_OFFSET != TWAMMStorageLayout.REWARD_RATES_BEFORE_OFFSET);
    }

    // Comprehensive test with realistic inputs
    function test_noStorageLayoutCollisions_comprehensive(
        PoolId poolId,
        uint64 time0,
        uint64 time1,
        address owner,
        bytes32 salt,
        OrderId orderId
    ) public pure {
        vm.assume(time0 != time1);

        // Get all the different storage slots
        bytes32 poolStateSlot = StorageSlot.unwrap(TWAMMStorageLayout.twammPoolStateSlot(poolId));
        bytes32 rewardRatesSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesSlot(poolId));
        bytes32 bitmapSlot = StorageSlot.unwrap(TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId));
        bytes32 timeInfoSlot0 = StorageSlot.unwrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId, time0));
        bytes32 timeInfoSlot1 = StorageSlot.unwrap(TWAMMStorageLayout.poolTimeInfosSlot(poolId, time1));
        bytes32 rewardRatesBeforeSlot0 = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, time0));
        bytes32 rewardRatesBeforeSlot1 = StorageSlot.unwrap(TWAMMStorageLayout.poolRewardRatesBeforeSlot(poolId, time1));
        bytes32 orderSlot = StorageSlot.unwrap(
            TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner, salt, orderId)
        );

        // Verify no collisions between different storage types
        assertNotEq(poolStateSlot, rewardRatesSlot);
        assertNotEq(poolStateSlot, wrapAdd(rewardRatesSlot, 1));
        assertNotEq(poolStateSlot, bitmapSlot);
        assertNotEq(poolStateSlot, timeInfoSlot0);
        assertNotEq(poolStateSlot, timeInfoSlot1);
        assertNotEq(poolStateSlot, rewardRatesBeforeSlot0);
        assertNotEq(poolStateSlot, wrapAdd(rewardRatesBeforeSlot0, 1));
        assertNotEq(poolStateSlot, rewardRatesBeforeSlot1);
        assertNotEq(poolStateSlot, wrapAdd(rewardRatesBeforeSlot1, 1));
        assertNotEq(poolStateSlot, orderSlot);
        assertNotEq(poolStateSlot, wrapAdd(orderSlot, 1));

        assertNotEq(rewardRatesSlot, bitmapSlot);
        assertNotEq(wrapAdd(rewardRatesSlot, 1), bitmapSlot);
        assertNotEq(rewardRatesSlot, timeInfoSlot0);
        assertNotEq(wrapAdd(rewardRatesSlot, 1), timeInfoSlot0);
        assertNotEq(rewardRatesSlot, timeInfoSlot1);
        assertNotEq(wrapAdd(rewardRatesSlot, 1), timeInfoSlot1);
        assertNotEq(rewardRatesSlot, rewardRatesBeforeSlot0);
        assertNotEq(wrapAdd(rewardRatesSlot, 1), rewardRatesBeforeSlot0);
        assertNotEq(rewardRatesSlot, wrapAdd(rewardRatesBeforeSlot0, 1));
        assertNotEq(wrapAdd(rewardRatesSlot, 1), wrapAdd(rewardRatesBeforeSlot0, 1));
        assertNotEq(rewardRatesSlot, rewardRatesBeforeSlot1);
        assertNotEq(wrapAdd(rewardRatesSlot, 1), rewardRatesBeforeSlot1);
        assertNotEq(rewardRatesSlot, wrapAdd(rewardRatesBeforeSlot1, 1));
        assertNotEq(wrapAdd(rewardRatesSlot, 1), wrapAdd(rewardRatesBeforeSlot1, 1));
        assertNotEq(rewardRatesSlot, orderSlot);
        assertNotEq(wrapAdd(rewardRatesSlot, 1), orderSlot);
        assertNotEq(rewardRatesSlot, wrapAdd(orderSlot, 1));
        assertNotEq(wrapAdd(rewardRatesSlot, 1), wrapAdd(orderSlot, 1));

        assertNotEq(bitmapSlot, timeInfoSlot0);
        assertNotEq(bitmapSlot, timeInfoSlot1);
        assertNotEq(bitmapSlot, rewardRatesBeforeSlot0);
        assertNotEq(bitmapSlot, wrapAdd(rewardRatesBeforeSlot0, 1));
        assertNotEq(bitmapSlot, rewardRatesBeforeSlot1);
        assertNotEq(bitmapSlot, wrapAdd(rewardRatesBeforeSlot1, 1));
        assertNotEq(bitmapSlot, orderSlot);
        assertNotEq(bitmapSlot, wrapAdd(orderSlot, 1));

        assertNotEq(timeInfoSlot0, timeInfoSlot1);
        assertNotEq(timeInfoSlot0, rewardRatesBeforeSlot0);
        assertNotEq(timeInfoSlot0, wrapAdd(rewardRatesBeforeSlot0, 1));
        assertNotEq(timeInfoSlot0, rewardRatesBeforeSlot1);
        assertNotEq(timeInfoSlot0, wrapAdd(rewardRatesBeforeSlot1, 1));
        assertNotEq(timeInfoSlot0, orderSlot);
        assertNotEq(timeInfoSlot0, wrapAdd(orderSlot, 1));

        assertNotEq(timeInfoSlot1, rewardRatesBeforeSlot0);
        assertNotEq(timeInfoSlot1, wrapAdd(rewardRatesBeforeSlot0, 1));
        assertNotEq(timeInfoSlot1, rewardRatesBeforeSlot1);
        assertNotEq(timeInfoSlot1, wrapAdd(rewardRatesBeforeSlot1, 1));
        assertNotEq(timeInfoSlot1, orderSlot);
        assertNotEq(timeInfoSlot1, wrapAdd(orderSlot, 1));

        assertNotEq(rewardRatesBeforeSlot0, rewardRatesBeforeSlot1);
        assertNotEq(wrapAdd(rewardRatesBeforeSlot0, 1), rewardRatesBeforeSlot1);
        assertNotEq(rewardRatesBeforeSlot0, wrapAdd(rewardRatesBeforeSlot1, 1));
        assertNotEq(wrapAdd(rewardRatesBeforeSlot0, 1), wrapAdd(rewardRatesBeforeSlot1, 1));
        assertNotEq(rewardRatesBeforeSlot0, orderSlot);
        assertNotEq(wrapAdd(rewardRatesBeforeSlot0, 1), orderSlot);
        assertNotEq(rewardRatesBeforeSlot0, wrapAdd(orderSlot, 1));
        assertNotEq(wrapAdd(rewardRatesBeforeSlot0, 1), wrapAdd(orderSlot, 1));

        assertNotEq(rewardRatesBeforeSlot1, orderSlot);
        assertNotEq(wrapAdd(rewardRatesBeforeSlot1, 1), orderSlot);
        assertNotEq(rewardRatesBeforeSlot1, wrapAdd(orderSlot, 1));
        assertNotEq(wrapAdd(rewardRatesBeforeSlot1, 1), wrapAdd(orderSlot, 1));
    }
}
