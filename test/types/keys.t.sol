// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    PoolKey,
    PositionKey,
    TokensMustBeSorted,
    InvalidTickSpacing,
    Bounds,
    BoundsOrder,
    MinMaxBounds,
    BoundsTickSpacing
} from "../../src/types/keys.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING} from "../../src/math/ticks.sol";

contract KeysTest is Test {
    function test_poolKey_validateTokens_zero_token0() public {
        PoolKey({token0: address(0), token1: address(1), fee: 0, tickSpacing: 1, extension: address(0)}).validatePoolKey(
        );
    }

    function test_poolKey_validateTokens_order() public {
        vm.expectRevert(TokensMustBeSorted.selector);
        PoolKey({token0: address(2), token1: address(1), fee: 0, tickSpacing: 1, extension: address(0)}).validatePoolKey(
        );
    }

    function test_poolKey_validateTokens_equal() public {
        vm.expectRevert(TokensMustBeSorted.selector);
        PoolKey({token0: address(2), token1: address(2), fee: 0, tickSpacing: 1, extension: address(0)}).validatePoolKey(
        );
    }

    function test_poolKey_validateTickSpacing_zero() public {
        vm.expectRevert(InvalidTickSpacing.selector);
        PoolKey({token0: address(1), token1: address(2), fee: 0, tickSpacing: 0, extension: address(0)}).validatePoolKey(
        );
    }

    function test_poolKey_validateTickSpacing_max() public {
        vm.expectRevert(InvalidTickSpacing.selector);
        PoolKey({
            token0: address(1),
            token1: address(2),
            fee: 0,
            tickSpacing: MAX_TICK_SPACING + 1,
            extension: address(0)
        }).validatePoolKey();
    }

    function test_validateBounds() public {
        Bounds({lower: -1, upper: 1}).validateBounds(1);
        Bounds({lower: -2, upper: 2}).validateBounds(2);

        vm.expectRevert(BoundsOrder.selector);
        Bounds({lower: -1, upper: -1}).validateBounds(1);

        vm.expectRevert(BoundsOrder.selector);
        Bounds({lower: 1, upper: -1}).validateBounds(1);

        vm.expectRevert(MinMaxBounds.selector);
        Bounds({lower: MIN_TICK - 1, upper: MAX_TICK}).validateBounds(1);

        vm.expectRevert(MinMaxBounds.selector);
        Bounds({lower: MIN_TICK, upper: MAX_TICK + 1}).validateBounds(1);

        vm.expectRevert(BoundsTickSpacing.selector);
        Bounds({lower: 1, upper: 0}).validateBounds(2);

        vm.expectRevert(BoundsTickSpacing.selector);
        Bounds({lower: 0, upper: 1}).validateBounds(2);
    }

    function test_toPoolId_changesWithToken0(PoolKey memory poolKey) public pure {
        bytes32 id = poolKey.toPoolId();
        unchecked {
            poolKey.token0 = address(uint160(poolKey.token0) + 1);
        }
        assertNotEq(poolKey.toPoolId(), id);
    }

    function test_toPoolId_changesWithToken1(PoolKey memory poolKey) public pure {
        bytes32 id = poolKey.toPoolId();
        unchecked {
            poolKey.token1 = address(uint160(poolKey.token1) + 1);
        }
        assertNotEq(poolKey.toPoolId(), id);
    }

    function test_toPoolId_changesWithExtension(PoolKey memory poolKey) public pure {
        bytes32 id = poolKey.toPoolId();
        unchecked {
            poolKey.extension = address(uint160(poolKey.extension) + 1);
        }
        assertNotEq(poolKey.toPoolId(), id);
    }

    function test_toPoolId_changesWithFee(PoolKey memory poolKey) public pure {
        bytes32 id = poolKey.toPoolId();
        unchecked {
            poolKey.fee += 1;
        }
        assertNotEq(poolKey.toPoolId(), id);
    }

    function test_toPoolId_changesWithTickSpacing(PoolKey memory poolKey) public pure {
        bytes32 id = poolKey.toPoolId();
        unchecked {
            poolKey.tickSpacing += 1;
        }
        assertNotEq(poolKey.toPoolId(), id);
    }

    function test_toPositionId_changesWithSalt(PositionKey memory positionKey) public pure {
        bytes32 id = positionKey.toPositionId();
        unchecked {
            positionKey.salt = bytes32(uint256(positionKey.salt) + 1);
        }
        assertNotEq(positionKey.toPositionId(), id);
    }

    function test_toPositionId_changesWithOwner(PositionKey memory positionKey) public pure {
        bytes32 id = positionKey.toPositionId();
        unchecked {
            positionKey.owner = address(uint160(positionKey.owner) + 1);
        }
        assertNotEq(positionKey.toPositionId(), id);
    }

    function test_toPositionId_doesNotChangeWithBoundsValue(PositionKey memory positionKey) public pure {
        bytes32 id = positionKey.toPositionId();
        positionKey.bounds = Bounds(positionKey.bounds.lower, positionKey.bounds.upper);
        assertEq(positionKey.toPositionId(), id);
    }

    function test_toPositionId_changesWithDifferentLowerBounds(PositionKey memory positionKey) public pure {
        bytes32 id = positionKey.toPositionId();
        unchecked {
            positionKey.bounds.lower += 1;
        }
        assertNotEq(positionKey.toPositionId(), id);
    }

    function test_toPositionId_changesWithDifferentUpperBounds(PositionKey memory positionKey) public pure {
        bytes32 id = positionKey.toPositionId();
        unchecked {
            positionKey.bounds.upper += 1;
        }
        assertNotEq(positionKey.toPositionId(), id);
    }

    function check_toPoolId_aligns_with_eq(PoolKey memory pk0, PoolKey memory pk1) public pure {
        bytes32 pk0Id = pk0.toPoolId();
        bytes32 pk1Id = pk1.toPoolId();

        assertEq(
            pk0.token0 == pk1.token0 && pk0.token1 == pk1.token1 && pk0.fee == pk1.fee
                && pk0.tickSpacing == pk1.tickSpacing && pk0.extension == pk1.extension,
            pk0Id == pk1Id
        );
    }

    function test_toPoolId_hash_matches_abi_encode(PoolKey memory pk) public pure {
        bytes32 id = pk.toPoolId();
        assertEq(id, keccak256(abi.encode(pk)));
    }

    function check_toPositionId_aligns_with_eq(PositionKey memory p0, PositionKey memory p1) public pure {
        bytes32 p0Id = p0.toPositionId();
        bytes32 p1Id = p1.toPositionId();

        assertEq(
            p0.salt == p1.salt && p0.owner == p1.owner && p0.bounds.lower == p1.bounds.lower
                && p0.bounds.upper == p1.bounds.upper,
            p0Id == p1Id
        );
    }

    function test_toPoolId_hash_matches_abi_encode(PositionKey memory pk) public pure {
        bytes32 id = pk.toPositionId();
        assertEq(
            id,
            keccak256(
                abi.encode(
                    keccak256(abi.encode(pk.salt, pk.owner)), keccak256(abi.encode(pk.bounds.lower, pk.bounds.upper))
                )
            )
        );
    }
}
