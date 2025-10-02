// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {CoreStorageLayout} from "../../src/libraries/CoreStorageLayout.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PositionId, createPositionId} from "../../src/types/positionId.sol";
import {PoolKey, createPoolConfig} from "../../src/types/poolKey.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";

contract CoreStorageLayoutTest is Test {
    using CoreStorageLayout for *;

    // Test that the same inputs always produce the same slot
    function test_isExtensionRegisteredSlot_deterministic(address extension) public pure {
        bytes32 slot1 = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        bytes32 slot2 = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        assertEq(slot1, slot2);
    }

    function test_poolStateSlot_deterministic(PoolId poolId) public pure {
        bytes32 slot1 = CoreStorageLayout.poolStateSlot(poolId);
        bytes32 slot2 = CoreStorageLayout.poolStateSlot(poolId);
        assertEq(slot1, slot2);
    }

    function test_poolFeesPerLiquiditySlot_deterministic(PoolId poolId) public pure {
        bytes32 slot1 = CoreStorageLayout.poolFeesPerLiquiditySlot(poolId);
        bytes32 slot2 = CoreStorageLayout.poolFeesPerLiquiditySlot(poolId);
        assertEq(slot1, slot2);
    }

    function test_poolTicksSlot_deterministic(PoolId poolId, int32 tick) public pure {
        bytes32 slot1 = CoreStorageLayout.poolTicksSlot(poolId, tick);
        bytes32 slot2 = CoreStorageLayout.poolTicksSlot(poolId, tick);
        assertEq(slot1, slot2);
    }

    function test_poolTickFeesPerLiquidityOutsideSlot_deterministic(PoolId poolId, int32 tick) public pure {
        (bytes32 first1, bytes32 second1) = CoreStorageLayout.poolTickFeesPerLiquidityOutsideSlot(poolId, tick);
        (bytes32 first2, bytes32 second2) = CoreStorageLayout.poolTickFeesPerLiquidityOutsideSlot(poolId, tick);
        assertEq(first1, first2);
        assertEq(second1, second2);
    }

    function test_tickBitmapsSlot_deterministic(PoolId poolId) public pure {
        bytes32 slot1 = CoreStorageLayout.tickBitmapsSlot(poolId);
        bytes32 slot2 = CoreStorageLayout.tickBitmapsSlot(poolId);
        assertEq(slot1, slot2);
    }

    function test_poolPositionsSlot_deterministic(PoolId poolId, address owner, PositionId positionId) public pure {
        bytes32 slot1 = CoreStorageLayout.poolPositionsSlot(poolId, owner, positionId);
        bytes32 slot2 = CoreStorageLayout.poolPositionsSlot(poolId, owner, positionId);
        assertEq(slot1, slot2);
    }

    function test_savedBalancesSlot_deterministic(address owner, address token0, address token1, bytes32 salt)
        public
        pure
    {
        bytes32 slot1 = CoreStorageLayout.savedBalancesSlot(owner, token0, token1, salt);
        bytes32 slot2 = CoreStorageLayout.savedBalancesSlot(owner, token0, token1, salt);
        assertEq(slot1, slot2);
    }

    // Test that different extensions produce different slots
    function test_isExtensionRegisteredSlot_uniqueness(address extension1, address extension2) public pure {
        vm.assume(extension1 != extension2);
        bytes32 slot1 = CoreStorageLayout.isExtensionRegisteredSlot(extension1);
        bytes32 slot2 = CoreStorageLayout.isExtensionRegisteredSlot(extension2);
        assertNotEq(slot1, slot2);
    }

    // Test that different pool IDs produce different pool state slots
    function test_poolStateSlot_uniqueness(PoolId poolId1, PoolId poolId2) public pure {
        vm.assume(PoolId.unwrap(poolId1) != PoolId.unwrap(poolId2));
        bytes32 slot1 = CoreStorageLayout.poolStateSlot(poolId1);
        bytes32 slot2 = CoreStorageLayout.poolStateSlot(poolId2);
        assertNotEq(slot1, slot2);
    }

    // Test that pool fees slots are consecutive and unique
    function test_poolFeesPerLiquiditySlot_consecutive(PoolId poolId) public pure {
        bytes32 firstSlot = CoreStorageLayout.poolFeesPerLiquiditySlot(poolId);
        bytes32 poolStateSlot = CoreStorageLayout.poolStateSlot(poolId);

        // First fees slot should be pool state slot + 1
        assertEq(uint256(firstSlot), uint256(poolStateSlot) + 1);

        // Second fees slot should be pool state slot + 2
        assertEq(uint256(firstSlot) + 1, uint256(poolStateSlot) + 2);
    }

    // Test that different ticks produce different tick slots for the same pool
    function test_poolTicksSlot_uniqueness(PoolId poolId, int32 tick1, int32 tick2) public pure {
        vm.assume(tick1 != tick2);
        bytes32 slot1 = CoreStorageLayout.poolTicksSlot(poolId, tick1);
        bytes32 slot2 = CoreStorageLayout.poolTicksSlot(poolId, tick2);
        assertNotEq(slot1, slot2);
    }

    // Test that tick fees per liquidity outside slots are properly separated
    function test_poolTickFeesPerLiquidityOutsideSlot_separation(PoolId poolId, int32 tick) public pure {
        (bytes32 first, bytes32 second) = CoreStorageLayout.poolTickFeesPerLiquidityOutsideSlot(poolId, tick);

        // The two slots should be different
        assertNotEq(first, second);

        // The difference should be FPL_OUTSIDE_OFFSET
        uint256 FPL_OUTSIDE_OFFSET = 0xffffffffff;
        assertEq(uint256(second), uint256(first) + FPL_OUTSIDE_OFFSET);
    }

    // Test that different position IDs produce different position slots
    function test_poolPositionsSlot_uniqueness_positionId(
        PoolId poolId,
        address owner,
        PositionId positionId1,
        PositionId positionId2
    ) public pure {
        vm.assume(PositionId.unwrap(positionId1) != PositionId.unwrap(positionId2));
        bytes32 slot1 = CoreStorageLayout.poolPositionsSlot(poolId, owner, positionId1);
        bytes32 slot2 = CoreStorageLayout.poolPositionsSlot(poolId, owner, positionId2);
        assertNotEq(slot1, slot2);
    }

    // Test that different owners produce different position slots
    function test_poolPositionsSlot_uniqueness_owner(
        PoolId poolId,
        address owner1,
        address owner2,
        PositionId positionId
    ) public pure {
        vm.assume(owner1 != owner2);
        bytes32 slot1 = CoreStorageLayout.poolPositionsSlot(poolId, owner1, positionId);
        bytes32 slot2 = CoreStorageLayout.poolPositionsSlot(poolId, owner2, positionId);
        assertNotEq(slot1, slot2);
    }

    // Test that different pool IDs produce different position slots
    function test_poolPositionsSlot_uniqueness_poolId(
        PoolId poolId1,
        PoolId poolId2,
        address owner,
        PositionId positionId
    ) public pure {
        vm.assume(PoolId.unwrap(poolId1) != PoolId.unwrap(poolId2));
        bytes32 slot1 = CoreStorageLayout.poolPositionsSlot(poolId1, owner, positionId);
        bytes32 slot2 = CoreStorageLayout.poolPositionsSlot(poolId2, owner, positionId);
        assertNotEq(slot1, slot2);
    }

    // Test that saved balances slots are unique for different parameters
    function test_savedBalancesSlot_uniqueness_owner(
        address owner1,
        address owner2,
        address token0,
        address token1,
        bytes32 salt
    ) public pure {
        vm.assume(owner1 != owner2);
        bytes32 slot1 = CoreStorageLayout.savedBalancesSlot(owner1, token0, token1, salt);
        bytes32 slot2 = CoreStorageLayout.savedBalancesSlot(owner2, token0, token1, salt);
        assertNotEq(slot1, slot2);
    }

    function test_savedBalancesSlot_uniqueness_token0(
        address owner,
        address token0_1,
        address token0_2,
        address token1,
        bytes32 salt
    ) public pure {
        vm.assume(token0_1 != token0_2);
        bytes32 slot1 = CoreStorageLayout.savedBalancesSlot(owner, token0_1, token1, salt);
        bytes32 slot2 = CoreStorageLayout.savedBalancesSlot(owner, token0_2, token1, salt);
        assertNotEq(slot1, slot2);
    }

    function test_savedBalancesSlot_uniqueness_token1(
        address owner,
        address token0,
        address token1_1,
        address token1_2,
        bytes32 salt
    ) public pure {
        vm.assume(token1_1 != token1_2);
        bytes32 slot1 = CoreStorageLayout.savedBalancesSlot(owner, token0, token1_1, salt);
        bytes32 slot2 = CoreStorageLayout.savedBalancesSlot(owner, token0, token1_2, salt);
        assertNotEq(slot1, slot2);
    }

    function test_savedBalancesSlot_uniqueness_salt(
        address owner,
        address token0,
        address token1,
        bytes32 salt1,
        bytes32 salt2
    ) public pure {
        vm.assume(salt1 != salt2);
        bytes32 slot1 = CoreStorageLayout.savedBalancesSlot(owner, token0, token1, salt1);
        bytes32 slot2 = CoreStorageLayout.savedBalancesSlot(owner, token0, token1, salt2);
        assertNotEq(slot1, slot2);
    }

    // Comprehensive collision tests between different storage types

    // Test that extension slots don't collide with pool state slots
    function test_noCollision_extension_poolState(address extension, PoolId poolId) public pure {
        bytes32 extensionSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        bytes32 poolStateSlot = CoreStorageLayout.poolStateSlot(poolId);
        assertNotEq(extensionSlot, poolStateSlot);
    }

    // Test that extension slots don't collide with pool fees slots
    function test_noCollision_extension_poolFees(address extension, PoolId poolId) public pure {
        bytes32 extensionSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        bytes32 poolFeesSlot = CoreStorageLayout.poolFeesPerLiquiditySlot(poolId);
        assertNotEq(extensionSlot, poolFeesSlot);
        assertNotEq(uint256(extensionSlot), uint256(poolFeesSlot) + 1);
    }

    // Test that extension slots don't collide with tick slots
    function test_noCollision_extension_ticks(address extension, PoolId poolId, int32 tick) public pure {
        vm.assume(tick >= MIN_TICK && tick <= MAX_TICK);
        bytes32 extensionSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        bytes32 tickSlot = CoreStorageLayout.poolTicksSlot(poolId, tick);
        assertNotEq(extensionSlot, tickSlot);
    }

    // Test that extension slots don't collide with tick fees per liquidity outside slots
    function test_noCollision_extension_tickFeesOutside(address extension, PoolId poolId, int32 tick) public pure {
        vm.assume(tick >= MIN_TICK && tick <= MAX_TICK);
        bytes32 extensionSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        (bytes32 first, bytes32 second) = CoreStorageLayout.poolTickFeesPerLiquidityOutsideSlot(poolId, tick);
        assertNotEq(extensionSlot, first);
        assertNotEq(extensionSlot, second);
    }

    // Test that extension slots don't collide with bitmap slots
    function test_noCollision_extension_bitmaps(address extension, PoolId poolId) public pure {
        bytes32 extensionSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        bytes32 bitmapSlot = CoreStorageLayout.tickBitmapsSlot(poolId);

        // Check that extension slot doesn't collide with any bitmap slot
        // Bitmaps can span a range, so we check a reasonable range
        for (uint256 i = 0; i < 1000; i++) {
            assertNotEq(uint256(extensionSlot), uint256(bitmapSlot) + i);
        }
    }

    // Test that extension slots don't collide with position slots
    function test_noCollision_extension_positions(
        address extension,
        PoolId poolId,
        address owner,
        PositionId positionId
    ) public pure {
        bytes32 extensionSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        bytes32 positionSlot = CoreStorageLayout.poolPositionsSlot(poolId, owner, positionId);
        assertNotEq(extensionSlot, positionSlot);
        // Positions occupy 3 consecutive slots
        assertNotEq(uint256(extensionSlot), uint256(positionSlot) + 1);
        assertNotEq(uint256(extensionSlot), uint256(positionSlot) + 2);
    }

    // Test that extension slots don't collide with saved balances slots
    function test_noCollision_extension_savedBalances(
        address extension,
        address owner,
        address token0,
        address token1,
        bytes32 salt
    ) public pure {
        bytes32 extensionSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        bytes32 savedBalancesSlot = CoreStorageLayout.savedBalancesSlot(owner, token0, token1, salt);
        assertNotEq(extensionSlot, savedBalancesSlot);
    }

    // Test that pool state slots don't collide with pool fees slots (except for the same pool)
    function test_noCollision_poolState_poolFees_differentPools(PoolId poolId1, PoolId poolId2) public pure {
        vm.assume(PoolId.unwrap(poolId1) != PoolId.unwrap(poolId2));
        bytes32 poolStateSlot1 = CoreStorageLayout.poolStateSlot(poolId1);
        bytes32 poolFeesSlot2 = CoreStorageLayout.poolFeesPerLiquiditySlot(poolId2);

        assertNotEq(poolStateSlot1, poolFeesSlot2);
        assertNotEq(uint256(poolStateSlot1), uint256(poolFeesSlot2) + 1);
    }

    // Test that pool state slots don't collide with tick slots
    function test_noCollision_poolState_ticks(PoolId poolId1, PoolId poolId2, int32 tick) public pure {
        vm.assume(tick >= MIN_TICK && tick <= MAX_TICK);
        bytes32 poolStateSlot = CoreStorageLayout.poolStateSlot(poolId1);
        bytes32 tickSlot = CoreStorageLayout.poolTicksSlot(poolId2, tick);

        // For the same pool, pool state is at offset 0, ticks start at TICKS_OFFSET
        // For different pools, they should never collide
        if (PoolId.unwrap(poolId1) == PoolId.unwrap(poolId2)) {
            // Same pool: pool state is at poolId, ticks are at poolId + TICKS_OFFSET + tick
            // These should never collide because TICKS_OFFSET is large
            assertNotEq(poolStateSlot, tickSlot);
        } else {
            // Different pools: should never collide
            assertNotEq(poolStateSlot, tickSlot);
        }
    }

    // Test that pool fees slots don't collide with tick slots
    function test_noCollision_poolFees_ticks(PoolId poolId1, PoolId poolId2, int32 tick) public pure {
        vm.assume(tick >= MIN_TICK && tick <= MAX_TICK);
        bytes32 poolFeesSlot = CoreStorageLayout.poolFeesPerLiquiditySlot(poolId1);
        bytes32 tickSlot = CoreStorageLayout.poolTicksSlot(poolId2, tick);

        assertNotEq(poolFeesSlot, tickSlot);
        assertNotEq(uint256(poolFeesSlot) + 1, uint256(tickSlot));
    }

    // Test that tick slots don't collide with tick fees outside slots for different ticks
    function test_noCollision_ticks_tickFeesOutside(PoolId poolId, int32 tick1, int32 tick2) public pure {
        vm.assume(tick1 >= MIN_TICK && tick1 <= MAX_TICK);
        vm.assume(tick2 >= MIN_TICK && tick2 <= MAX_TICK);
        vm.assume(tick1 != tick2);

        bytes32 tickSlot = CoreStorageLayout.poolTicksSlot(poolId, tick1);
        (bytes32 first, bytes32 second) = CoreStorageLayout.poolTickFeesPerLiquidityOutsideSlot(poolId, tick2);

        assertNotEq(tickSlot, first);
        assertNotEq(tickSlot, second);
    }

    // Test that bitmap slots don't collide with position slots
    function test_noCollision_bitmaps_positions(PoolId poolId1, PoolId poolId2, address owner, PositionId positionId)
        public
        pure
    {
        bytes32 bitmapSlot = CoreStorageLayout.tickBitmapsSlot(poolId1);
        bytes32 positionSlot = CoreStorageLayout.poolPositionsSlot(poolId2, owner, positionId);

        // Check that bitmap slots don't collide with position slots
        // We check a reasonable range of bitmap slots
        for (uint256 i = 0; i < 1000; i++) {
            assertNotEq(uint256(bitmapSlot) + i, uint256(positionSlot));
            assertNotEq(uint256(bitmapSlot) + i, uint256(positionSlot) + 1);
            assertNotEq(uint256(bitmapSlot) + i, uint256(positionSlot) + 2);
        }
    }

    // Test that position slots don't collide with saved balances slots
    function test_noCollision_positions_savedBalances(
        PoolId poolId,
        address owner1,
        PositionId positionId,
        address owner2,
        address token0,
        address token1,
        bytes32 salt
    ) public pure {
        bytes32 positionSlot = CoreStorageLayout.poolPositionsSlot(poolId, owner1, positionId);
        bytes32 savedBalancesSlot = CoreStorageLayout.savedBalancesSlot(owner2, token0, token1, salt);

        assertNotEq(positionSlot, savedBalancesSlot);
        assertNotEq(uint256(positionSlot) + 1, uint256(savedBalancesSlot));
        assertNotEq(uint256(positionSlot) + 2, uint256(savedBalancesSlot));
    }

    // Test with realistic pool IDs derived from pool keys
    function test_noCollision_realisticPoolIds(
        address token0,
        address token1,
        uint64 fee,
        uint32 tickSpacing,
        address extension,
        int32 tick,
        address owner,
        bytes24 salt,
        int32 tickLower,
        int32 tickUpper
    ) public pure {
        // Ensure valid inputs
        vm.assume(token0 < token1);
        vm.assume(tick >= MIN_TICK && tick <= MAX_TICK);
        vm.assume(tickLower >= MIN_TICK && tickLower <= MAX_TICK);
        vm.assume(tickUpper >= MIN_TICK && tickUpper <= MAX_TICK);
        vm.assume(tickLower < tickUpper);

        // Create a realistic pool key and derive pool ID
        PoolKey memory poolKey =
            PoolKey({token0: token0, token1: token1, config: createPoolConfig(fee, tickSpacing, extension)});
        PoolId poolId = poolKey.toPoolId();

        // Create a position ID
        PositionId positionId = createPositionId(salt, tickLower, tickUpper);

        // Get all the different storage slots
        bytes32 extensionSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        bytes32 poolStateSlot = CoreStorageLayout.poolStateSlot(poolId);
        bytes32 poolFeesSlot = CoreStorageLayout.poolFeesPerLiquiditySlot(poolId);
        bytes32 tickSlot = CoreStorageLayout.poolTicksSlot(poolId, tick);
        (bytes32 tickFeesFirst, bytes32 tickFeesSecond) =
            CoreStorageLayout.poolTickFeesPerLiquidityOutsideSlot(poolId, tick);
        bytes32 bitmapSlot = CoreStorageLayout.tickBitmapsSlot(poolId);
        bytes32 positionSlot = CoreStorageLayout.poolPositionsSlot(poolId, owner, positionId);
        bytes32 savedBalancesSlot =
            CoreStorageLayout.savedBalancesSlot(owner, token0, token1, bytes32(uint256(uint160(extension))));

        // Verify no collisions between different storage types
        assertNotEq(extensionSlot, poolStateSlot);
        assertNotEq(extensionSlot, poolFeesSlot);
        assertNotEq(extensionSlot, tickSlot);
        assertNotEq(extensionSlot, tickFeesFirst);
        assertNotEq(extensionSlot, tickFeesSecond);
        assertNotEq(extensionSlot, bitmapSlot);
        assertNotEq(extensionSlot, positionSlot);
        assertNotEq(extensionSlot, savedBalancesSlot);

        assertNotEq(poolStateSlot, tickSlot);
        assertNotEq(poolStateSlot, tickFeesFirst);
        assertNotEq(poolStateSlot, tickFeesSecond);
        assertNotEq(poolStateSlot, bitmapSlot);
        assertNotEq(poolStateSlot, positionSlot);
        assertNotEq(poolStateSlot, savedBalancesSlot);

        assertNotEq(poolFeesSlot, tickSlot);
        assertNotEq(poolFeesSlot, tickFeesFirst);
        assertNotEq(poolFeesSlot, tickFeesSecond);
        assertNotEq(poolFeesSlot, bitmapSlot);
        assertNotEq(poolFeesSlot, positionSlot);
        assertNotEq(poolFeesSlot, savedBalancesSlot);

        assertNotEq(tickSlot, bitmapSlot);
        assertNotEq(tickSlot, positionSlot);
        assertNotEq(tickSlot, savedBalancesSlot);

        assertNotEq(tickFeesFirst, bitmapSlot);
        assertNotEq(tickFeesFirst, positionSlot);
        assertNotEq(tickFeesFirst, savedBalancesSlot);

        assertNotEq(tickFeesSecond, bitmapSlot);
        assertNotEq(tickFeesSecond, positionSlot);
        assertNotEq(tickFeesSecond, savedBalancesSlot);

        assertNotEq(bitmapSlot, positionSlot);
        assertNotEq(bitmapSlot, savedBalancesSlot);

        assertNotEq(positionSlot, savedBalancesSlot);
    }

    // Test that the offsets are large enough to prevent collisions within a pool
    function test_offsetsSufficient(PoolId poolId) public pure {
        uint256 TICKS_OFFSET = 0xffffffff;
        uint256 FPL_OUTSIDE_OFFSET = 0xffffffffff;
        uint256 BITMAPS_OFFSET = 0xffffffffffff;

        bytes32 poolStateSlot = CoreStorageLayout.poolStateSlot(poolId);
        bytes32 poolFeesSlot = CoreStorageLayout.poolFeesPerLiquiditySlot(poolId);
        bytes32 minTickSlot = CoreStorageLayout.poolTicksSlot(poolId, MIN_TICK);
        bytes32 maxTickSlot = CoreStorageLayout.poolTicksSlot(poolId, MAX_TICK);
        (bytes32 minTickFeesFirst, bytes32 minTickFeesSecond) =
            CoreStorageLayout.poolTickFeesPerLiquidityOutsideSlot(poolId, MIN_TICK);
        (bytes32 maxTickFeesFirst, bytes32 maxTickFeesSecond) =
            CoreStorageLayout.poolTickFeesPerLiquidityOutsideSlot(poolId, MAX_TICK);
        bytes32 bitmapSlot = CoreStorageLayout.tickBitmapsSlot(poolId);

        // Pool state is at offset 0
        assertEq(uint256(poolStateSlot), uint256(PoolId.unwrap(poolId)));

        // Pool fees are at offsets 1 and 2 (using unchecked to allow wrapping)
        unchecked {
            assertEq(uint256(poolFeesSlot), uint256(poolStateSlot) + 1);
        }

        // Verify the actual computed slots match expected values
        // The library uses assembly to add tick (as int32) to TICKS_OFFSET
        // When tick is negative, it's represented in two's complement
        // All arithmetic here uses unchecked to match the assembly behavior (wrapping)
        uint256 minTickOffset;
        uint256 maxTickOffset;
        assembly ("memory-safe") {
            minTickOffset := add(TICKS_OFFSET, MIN_TICK)
            maxTickOffset := add(TICKS_OFFSET, MAX_TICK)
        }
        unchecked {
            assertEq(uint256(minTickSlot), uint256(poolStateSlot) + minTickOffset);
            assertEq(uint256(maxTickSlot), uint256(poolStateSlot) + maxTickOffset);
        }

        // Verify tick fees outside slots
        uint256 minTickFplOffset;
        uint256 maxTickFplOffset;
        assembly ("memory-safe") {
            minTickFplOffset := add(FPL_OUTSIDE_OFFSET, MIN_TICK)
            maxTickFplOffset := add(FPL_OUTSIDE_OFFSET, MAX_TICK)
        }
        unchecked {
            assertEq(uint256(minTickFeesFirst), uint256(poolStateSlot) + minTickFplOffset);
            assertEq(uint256(maxTickFeesFirst), uint256(poolStateSlot) + maxTickFplOffset);
            assertEq(uint256(minTickFeesSecond), uint256(poolStateSlot) + minTickFplOffset + FPL_OUTSIDE_OFFSET);
            assertEq(uint256(maxTickFeesSecond), uint256(poolStateSlot) + maxTickFplOffset + FPL_OUTSIDE_OFFSET);
        }

        // Bitmaps start at BITMAPS_OFFSET
        unchecked {
            assertEq(uint256(bitmapSlot), uint256(poolStateSlot) + BITMAPS_OFFSET);
        }

        // Verify that the offsets themselves are properly sized to prevent collisions
        // These checks don't depend on the pool ID and verify the offset constants

        // TICKS_OFFSET should be large enough to not overlap with pool state/fees
        // Even with MIN_TICK (negative), the result should be > 2
        assertTrue(minTickOffset > 2);

        // FPL_OUTSIDE_OFFSET should be large enough to not overlap with ticks
        // The max tick slot is at TICKS_OFFSET + MAX_TICK
        // The min tick fees slot is at FPL_OUTSIDE_OFFSET + MIN_TICK
        // These should not overlap
        assertTrue(minTickFplOffset > maxTickOffset);

        // BITMAPS_OFFSET should be large enough to not overlap with tick fees outside
        // The max tick fees second slot is at 2*FPL_OUTSIDE_OFFSET + MAX_TICK
        assertTrue(BITMAPS_OFFSET > maxTickFplOffset + FPL_OUTSIDE_OFFSET);
    }
}
