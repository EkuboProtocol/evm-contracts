// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolKey, toConfig, Config, TokensMustBeSorted, InvalidTickSpacing} from "../../src/types/poolKey.sol";
import {MAX_TICK_SPACING, FULL_RANGE_ONLY_TICK_SPACING} from "../../src/math/constants.sol";

contract PoolKeyTest is Test {
    function test_toConfig_fee_tickSpacing_extension(uint64 fee, uint32 tickSpacing, address extension) public pure {
        Config c = toConfig(fee, tickSpacing, extension);
        PoolKey memory pk = PoolKey(address(0), address(0), c);
        assertEq(pk.fee(), fee);
        assertEq(pk.tickSpacing(), tickSpacing);
        assertEq(pk.extension(), extension);
    }

    function check_mustLoadFees(PoolKey memory poolKey) public pure {
        assertEq(poolKey.mustLoadFees(), poolKey.tickSpacing() != 0 || poolKey.fee() != 0);
    }

    function test_mustLoadFees(PoolKey memory poolKey) public pure {
        assertEq(poolKey.mustLoadFees(), poolKey.tickSpacing() != 0 || poolKey.fee() != 0);
    }

    function test_poolKey_validateTokens_zero_token0() public pure {
        PoolKey({token0: address(0), token1: address(1), config: toConfig(0, 1, address(0))}).validatePoolKey();
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_poolKey_validateTokens_order() public {
        vm.expectRevert(TokensMustBeSorted.selector);
        PoolKey({token0: address(2), token1: address(1), config: toConfig(0, 1, address(0))}).validatePoolKey();
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_poolKey_validateTokens_equal() public {
        vm.expectRevert(TokensMustBeSorted.selector);
        PoolKey({token0: address(2), token1: address(2), config: toConfig(0, 1, address(0))}).validatePoolKey();
    }

    function test_poolKey_validateTickSpacing_zero_is_valid() public pure {
        PoolKey({token0: address(1), token1: address(2), config: toConfig(0, 0, address(0))}).validatePoolKey();
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_poolKey_validateTickSpacing_max() public {
        vm.expectRevert(InvalidTickSpacing.selector);
        PoolKey({token0: address(1), token1: address(2), config: toConfig(0, MAX_TICK_SPACING + 1, address(0))})
            .validatePoolKey();
    }

    function test_poolKey_validateTickSpacing_full_range() public pure {
        PoolKey({token0: address(1), token1: address(2), config: toConfig(0, FULL_RANGE_ONLY_TICK_SPACING, address(0))})
            .validatePoolKey();
    }

    function test_toPoolId_changesWithToken0(PoolKey memory poolKey) public pure {
        bytes16 id = poolKey.toPoolId();
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
            poolKey.config = toConfig(poolKey.fee(), poolKey.tickSpacing(), address(uint160(poolKey.extension()) + 1));
        }
        assertNotEq(poolKey.toPoolId(), id);
    }

    function test_toPoolId_changesWithFee(PoolKey memory poolKey) public pure {
        bytes32 id = poolKey.toPoolId();
        unchecked {
            poolKey.config = toConfig(poolKey.fee() + 1, poolKey.tickSpacing(), poolKey.extension());
        }
        assertNotEq(poolKey.toPoolId(), id);
    }

    function test_toPoolId_changesWithTickSpacing(PoolKey memory poolKey) public pure {
        bytes32 id = poolKey.toPoolId();
        unchecked {
            poolKey.config = toConfig(poolKey.fee(), poolKey.tickSpacing() + 1, poolKey.extension());
        }
        assertNotEq(poolKey.toPoolId(), id);
    }

    function check_toPoolId_aligns_with_eq(PoolKey memory pk0, PoolKey memory pk1) public pure {
        bytes32 pk0Id = pk0.toPoolId();
        bytes32 pk1Id = pk1.toPoolId();

        assertEq(
            pk0.token0 == pk1.token0 && pk0.token1 == pk1.token1
                && Config.unwrap(pk0.config) == Config.unwrap(pk1.config),
            pk0Id == pk1Id
        );
    }

    function test_toPoolId_hash_matches_abi_encode(PoolKey memory pk) public pure {
        bytes16 id = pk.toPoolId();
        assertEq(id, bytes16(bytes32(uint256(keccak256(abi.encode(pk))) << 128)));
    }
}
