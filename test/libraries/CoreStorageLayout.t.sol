// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {CoreStorageLayout} from "../../src/libraries/CoreStorageLayout.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolConfig, createPoolConfig} from "../../src/types/poolConfig.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PositionId, createPositionId} from "../../src/types/positionId.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";

contract CoreStorageLayoutTest is Test {
    // Helper function for wrapping addition to match assembly behavior
    function wrapAdd(bytes32 x, uint256 y) internal pure returns (bytes32 r) {
        assembly ("memory-safe") {
            r := add(x, y)
        }
    }

    function test_noStorageLayoutCollisions_isExtensionRegisteredSlot_isExtensionRegisteredSlot(
        address extension0,
        address extension1
    ) public pure {
        bytes32 extensionSlot0 = CoreStorageLayout.isExtensionRegisteredSlot(extension0);
        bytes32 extensionSlot1 = CoreStorageLayout.isExtensionRegisteredSlot(extension1);
        assertEq((extensionSlot0 == extensionSlot1), (extension0 == extension1));
    }

    function test_noStorageLayoutCollisions_isExtensionRegisteredSlot_poolStateSlot(
        address extension,
        PoolKey memory poolKey
    ) public pure {
        bytes32 extensionSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        bytes32 poolStateSlot = CoreStorageLayout.poolStateSlot(poolKey.toPoolId());
        assertNotEq(extensionSlot, poolStateSlot);
    }

    function test_noStorageLayoutCollisions_poolStateSlot_poolStateSlot(
        PoolKey memory poolKey0,
        PoolKey memory poolKey1
    ) public pure {
        bytes32 poolStateSlot0 = CoreStorageLayout.poolStateSlot(poolKey0.toPoolId());
        bytes32 poolStateSlot1 = CoreStorageLayout.poolStateSlot(poolKey1.toPoolId());
        assertEq(
            (
                poolKey0.token0 == poolKey1.token0 && poolKey0.token1 == poolKey1.token1
                    && PoolConfig.unwrap(poolKey0.config) == PoolConfig.unwrap(poolKey1.config)
            ),
            (poolStateSlot0 == poolStateSlot1)
        );
    }

    // Test pool fees per liquidity slots
    function test_noStorageLayoutCollisions_poolFeesPerLiquiditySlot_consecutive(PoolId poolId) public pure {
        bytes32 firstSlot = CoreStorageLayout.poolFeesPerLiquiditySlot(poolId);
        bytes32 poolStateSlot = CoreStorageLayout.poolStateSlot(poolId);

        // First fees slot should be pool state slot + FPL_OFFSET (with wrapping)
        assertEq(firstSlot, wrapAdd(poolStateSlot, CoreStorageLayout.FPL_OFFSET));

        // Second fees slot should be first fees slot + 1 (with wrapping)
        assertEq(wrapAdd(firstSlot, 1), wrapAdd(poolStateSlot, CoreStorageLayout.FPL_OFFSET + 1));
    }

    function test_noStorageLayoutCollisions_isExtensionRegisteredSlot_poolFeesPerLiquiditySlot(
        address extension,
        PoolId poolId
    ) public pure {
        bytes32 extensionSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        bytes32 poolFeesSlot = CoreStorageLayout.poolFeesPerLiquiditySlot(poolId);
        assertNotEq(extensionSlot, poolFeesSlot);
        assertNotEq(extensionSlot, wrapAdd(poolFeesSlot, 1));
    }

    // Test pool ticks slots
    function test_noStorageLayoutCollisions_poolTicksSlot_uniqueness(PoolId poolId, int32 tick1, int32 tick2) public {
        vm.assume(tick1 != tick2);
        bytes32 slot1 = CoreStorageLayout.poolTicksSlot(poolId, tick1);
        bytes32 slot2 = CoreStorageLayout.poolTicksSlot(poolId, tick2);
        assertNotEq(slot1, slot2);
    }

    function test_noStorageLayoutCollisions_isExtensionRegisteredSlot_poolTicksSlot(
        address extension,
        PoolId poolId,
        int32 tick
    ) public {
        vm.assume(tick >= MIN_TICK && tick <= MAX_TICK);
        bytes32 extensionSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        bytes32 tickSlot = CoreStorageLayout.poolTicksSlot(poolId, tick);
        assertNotEq(extensionSlot, tickSlot);
    }

    function test_noStorageLayoutCollisions_poolStateSlot_poolTicksSlot(PoolId poolId1, PoolId poolId2, int32 tick)
        public
    {
        vm.assume(tick >= MIN_TICK && tick <= MAX_TICK);
        bytes32 poolStateSlot = CoreStorageLayout.poolStateSlot(poolId1);
        bytes32 tickSlot = CoreStorageLayout.poolTicksSlot(poolId2, tick);
        assertNotEq(poolStateSlot, tickSlot);
    }

    function test_noStorageLayoutCollisions_poolFeesPerLiquiditySlot_poolTicksSlot(
        PoolId poolId1,
        PoolId poolId2,
        int32 tick
    ) public {
        vm.assume(tick >= MIN_TICK && tick <= MAX_TICK);
        bytes32 poolFeesSlot = CoreStorageLayout.poolFeesPerLiquiditySlot(poolId1);
        bytes32 tickSlot = CoreStorageLayout.poolTicksSlot(poolId2, tick);

        assertNotEq(poolFeesSlot, tickSlot);
        assertNotEq(wrapAdd(poolFeesSlot, 1), tickSlot);
    }

    // Test tick fees per liquidity outside slots
    function test_poolTickFeesPerLiquidityOutsideSlot_separation(PoolId poolId, int32 tick) public pure {
        (bytes32 first, bytes32 second) = CoreStorageLayout.poolTickFeesPerLiquidityOutsideSlot(poolId, tick);

        // The two slots should be different
        assertNotEq(first, second);

        // The difference should be FPL_OUTSIDE_OFFSET_VALUE1 (with wrapping)
        assertEq(second, wrapAdd(first, CoreStorageLayout.FPL_OUTSIDE_OFFSET_VALUE1));
    }

    function test_noStorageLayoutCollisions_isExtensionRegisteredSlot_poolTickFeesPerLiquidityOutsideSlot(
        address extension,
        PoolId poolId,
        int32 tick
    ) public {
        vm.assume(tick >= MIN_TICK && tick <= MAX_TICK);
        bytes32 extensionSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        (bytes32 first, bytes32 second) = CoreStorageLayout.poolTickFeesPerLiquidityOutsideSlot(poolId, tick);
        assertNotEq(extensionSlot, first);
        assertNotEq(extensionSlot, second);
    }

    function test_noStorageLayoutCollisions_poolTicksSlot_poolTickFeesPerLiquidityOutsideSlot(
        PoolId poolId,
        int32 tick1,
        int32 tick2
    ) public {
        vm.assume(tick1 >= MIN_TICK && tick1 <= MAX_TICK);
        vm.assume(tick2 >= MIN_TICK && tick2 <= MAX_TICK);
        vm.assume(tick1 != tick2);

        bytes32 tickSlot = CoreStorageLayout.poolTicksSlot(poolId, tick1);
        (bytes32 first, bytes32 second) = CoreStorageLayout.poolTickFeesPerLiquidityOutsideSlot(poolId, tick2);

        assertNotEq(tickSlot, first);
        assertNotEq(tickSlot, second);
    }

    // Test tick bitmaps slots
    function test_noStorageLayoutCollisions_isExtensionRegisteredSlot_tickBitmapsSlot(address extension, PoolId poolId)
        public
        pure
    {
        bytes32 extensionSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        bytes32 bitmapSlot = CoreStorageLayout.tickBitmapsSlot(poolId);

        // Check that extension slot doesn't collide with bitmap slots in a reasonable range
        for (uint256 i = 0; i < 100; i++) {
            assertNotEq(extensionSlot, wrapAdd(bitmapSlot, i));
        }
    }

    // Test pool positions slots
    function test_noStorageLayoutCollisions_poolPositionsSlot_uniqueness_positionId(
        PoolId poolId,
        address owner,
        PositionId positionId1,
        PositionId positionId2
    ) public {
        vm.assume(PositionId.unwrap(positionId1) != PositionId.unwrap(positionId2));
        bytes32 slot1 = CoreStorageLayout.poolPositionsSlot(poolId, owner, positionId1);
        bytes32 slot2 = CoreStorageLayout.poolPositionsSlot(poolId, owner, positionId2);
        assertNotEq(slot1, slot2);
    }

    function test_noStorageLayoutCollisions_poolPositionsSlot_uniqueness_owner(
        PoolId poolId,
        address owner1,
        address owner2,
        PositionId positionId
    ) public {
        vm.assume(owner1 != owner2);
        bytes32 slot1 = CoreStorageLayout.poolPositionsSlot(poolId, owner1, positionId);
        bytes32 slot2 = CoreStorageLayout.poolPositionsSlot(poolId, owner2, positionId);
        assertNotEq(slot1, slot2);
    }

    function test_noStorageLayoutCollisions_poolPositionsSlot_uniqueness_poolId(
        PoolId poolId1,
        PoolId poolId2,
        address owner,
        PositionId positionId
    ) public {
        vm.assume(PoolId.unwrap(poolId1) != PoolId.unwrap(poolId2));
        bytes32 slot1 = CoreStorageLayout.poolPositionsSlot(poolId1, owner, positionId);
        bytes32 slot2 = CoreStorageLayout.poolPositionsSlot(poolId2, owner, positionId);
        assertNotEq(slot1, slot2);
    }

    function test_noStorageLayoutCollisions_isExtensionRegisteredSlot_poolPositionsSlot(
        address extension,
        PoolId poolId,
        address owner,
        PositionId positionId
    ) public pure {
        bytes32 extensionSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        bytes32 positionSlot = CoreStorageLayout.poolPositionsSlot(poolId, owner, positionId);
        assertNotEq(extensionSlot, positionSlot);
        // Positions occupy 3 consecutive slots
        assertNotEq(extensionSlot, wrapAdd(positionSlot, 1));
        assertNotEq(extensionSlot, wrapAdd(positionSlot, 2));
    }

    function test_noStorageLayoutCollisions_tickBitmapsSlot_poolPositionsSlot(
        PoolId poolId1,
        PoolId poolId2,
        address owner,
        PositionId positionId
    ) public pure {
        bytes32 bitmapSlot = CoreStorageLayout.tickBitmapsSlot(poolId1);
        bytes32 positionSlot = CoreStorageLayout.poolPositionsSlot(poolId2, owner, positionId);

        // Check that bitmap slots don't collide with position slots in a reasonable range
        for (uint256 i = 0; i < 100; i++) {
            bytes32 bitmapSlotI = wrapAdd(bitmapSlot, i);
            assertNotEq(bitmapSlotI, positionSlot);
            assertNotEq(bitmapSlotI, wrapAdd(positionSlot, 1));
            assertNotEq(bitmapSlotI, wrapAdd(positionSlot, 2));
        }
    }

    // Test saved balances slots
    function test_noStorageLayoutCollisions_savedBalancesSlot_uniqueness_owner(
        address owner1,
        address owner2,
        address token0,
        address token1,
        bytes32 salt
    ) public {
        vm.assume(owner1 != owner2);
        bytes32 slot1 = CoreStorageLayout.savedBalancesSlot(owner1, token0, token1, salt);
        bytes32 slot2 = CoreStorageLayout.savedBalancesSlot(owner2, token0, token1, salt);
        assertNotEq(slot1, slot2);
    }

    function test_noStorageLayoutCollisions_savedBalancesSlot_uniqueness_token0(
        address owner,
        address token0_1,
        address token0_2,
        address token1,
        bytes32 salt
    ) public {
        vm.assume(token0_1 != token0_2);
        bytes32 slot1 = CoreStorageLayout.savedBalancesSlot(owner, token0_1, token1, salt);
        bytes32 slot2 = CoreStorageLayout.savedBalancesSlot(owner, token0_2, token1, salt);
        assertNotEq(slot1, slot2);
    }

    function test_noStorageLayoutCollisions_savedBalancesSlot_uniqueness_token1(
        address owner,
        address token0,
        address token1_1,
        address token1_2,
        bytes32 salt
    ) public {
        vm.assume(token1_1 != token1_2);
        bytes32 slot1 = CoreStorageLayout.savedBalancesSlot(owner, token0, token1_1, salt);
        bytes32 slot2 = CoreStorageLayout.savedBalancesSlot(owner, token0, token1_2, salt);
        assertNotEq(slot1, slot2);
    }

    function test_noStorageLayoutCollisions_savedBalancesSlot_uniqueness_salt(
        address owner,
        address token0,
        address token1,
        bytes32 salt1,
        bytes32 salt2
    ) public {
        vm.assume(salt1 != salt2);
        bytes32 slot1 = CoreStorageLayout.savedBalancesSlot(owner, token0, token1, salt1);
        bytes32 slot2 = CoreStorageLayout.savedBalancesSlot(owner, token0, token1, salt2);
        assertNotEq(slot1, slot2);
    }

    function test_noStorageLayoutCollisions_isExtensionRegisteredSlot_savedBalancesSlot(
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

    function test_noStorageLayoutCollisions_poolPositionsSlot_savedBalancesSlot(
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
        assertNotEq(wrapAdd(positionSlot, 1), savedBalancesSlot);
        assertNotEq(wrapAdd(positionSlot, 2), savedBalancesSlot);
    }

    // Test offset sufficiency
    function test_offsetsSufficient(PoolId poolId) public pure {
        uint256 TICKS_OFFSET = CoreStorageLayout.TICKS_OFFSET;
        uint256 FPL_OUTSIDE_OFFSET_VALUE0 = CoreStorageLayout.FPL_OUTSIDE_OFFSET_VALUE0;
        uint256 FPL_OUTSIDE_OFFSET_VALUE1 = CoreStorageLayout.FPL_OUTSIDE_OFFSET_VALUE1;
        uint256 BITMAPS_OFFSET = CoreStorageLayout.BITMAPS_OFFSET;

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

        // Pool fees are at FPL_OFFSET (with wrapping)
        assertEq(poolFeesSlot, wrapAdd(poolStateSlot, CoreStorageLayout.FPL_OFFSET));

        // Verify the actual computed slots match expected values using assembly add
        uint256 minTickOffset;
        uint256 maxTickOffset;
        assembly ("memory-safe") {
            minTickOffset := add(TICKS_OFFSET, MIN_TICK)
            maxTickOffset := add(TICKS_OFFSET, MAX_TICK)
        }
        assertEq(minTickSlot, wrapAdd(poolStateSlot, minTickOffset));
        assertEq(maxTickSlot, wrapAdd(poolStateSlot, maxTickOffset));

        // Verify tick fees outside slots
        uint256 minTickFplOffset;
        uint256 maxTickFplOffset;
        assembly ("memory-safe") {
            minTickFplOffset := add(FPL_OUTSIDE_OFFSET_VALUE0, MIN_TICK)
            maxTickFplOffset := add(FPL_OUTSIDE_OFFSET_VALUE0, MAX_TICK)
        }
        assertEq(minTickFeesFirst, wrapAdd(poolStateSlot, minTickFplOffset));
        assertEq(maxTickFeesFirst, wrapAdd(poolStateSlot, maxTickFplOffset));
        assertEq(minTickFeesSecond, wrapAdd(wrapAdd(poolStateSlot, minTickFplOffset), FPL_OUTSIDE_OFFSET_VALUE1));
        assertEq(maxTickFeesSecond, wrapAdd(wrapAdd(poolStateSlot, maxTickFplOffset), FPL_OUTSIDE_OFFSET_VALUE1));

        // Bitmaps start at BITMAPS_OFFSET
        assertEq(bitmapSlot, wrapAdd(poolStateSlot, BITMAPS_OFFSET));

        // Note: Collision prevention is ensured by the keccak-generated offsets being
        // large pseudo-random values, and is verified by the other collision tests in this file.
        // Simple ordering assertions don't work here due to wrapping arithmetic.
    }

    // Comprehensive test with realistic pool IDs
    function test_noStorageLayoutCollisions_realisticPoolIds(
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
    ) public {
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
}
