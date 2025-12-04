// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {Test} from "forge-std/Test.sol";
import {PoolKey, TokensMustBeSorted} from "../../src/types/poolKey.sol";
import {
    PoolConfig,
    InvalidTickSpacing,
    createConcentratedPoolConfig,
    createFullRangePoolConfig
} from "../../src/types/poolConfig.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {MAX_TICK_SPACING} from "../../src/math/constants.sol";

contract PoolKeyTest is Test {
    function test_poolKey_validateTokens_zero_token0() public pure {
        PoolKey({token0: address(0), token1: address(1), config: createConcentratedPoolConfig(0, 1, address(0))})
            .validate();
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_poolKey_validateTokens_order() public {
        vm.expectRevert(TokensMustBeSorted.selector);
        PoolKey({token0: address(2), token1: address(1), config: createConcentratedPoolConfig(0, 1, address(0))})
            .validate();
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_poolKey_validateTokens_equal() public {
        vm.expectRevert(TokensMustBeSorted.selector);
        PoolKey({token0: address(2), token1: address(2), config: createConcentratedPoolConfig(0, 1, address(0))})
            .validate();
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_poolKey_validateTickSpacing_zero_is_invalid() public {
        vm.expectRevert(InvalidTickSpacing.selector);
        PoolKey({token0: address(1), token1: address(2), config: createConcentratedPoolConfig(0, 0, address(0))})
            .validate();
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_poolKey_validateTickSpacing_max() public {
        vm.expectRevert(InvalidTickSpacing.selector);
        PoolKey({
                token0: address(1),
                token1: address(2),
                config: createConcentratedPoolConfig(0, MAX_TICK_SPACING + 1, address(0))
            }).validate();
    }

    function test_poolKey_validateTickSpacing_full_range() public pure {
        PoolKey({token0: address(1), token1: address(2), config: createFullRangePoolConfig(0, address(0))}).validate();
    }

    function test_toPoolId_changesWithToken0(PoolKey memory poolKey) public pure {
        PoolId id = poolKey.toPoolId();
        unchecked {
            poolKey.token0 = address(uint160(poolKey.token0) + 1);
        }
        assertNotEq(PoolId.unwrap(poolKey.toPoolId()), PoolId.unwrap(id));
    }

    function test_toPoolId_changesWithToken1(PoolKey memory poolKey) public pure {
        PoolId id = poolKey.toPoolId();
        unchecked {
            poolKey.token1 = address(uint160(poolKey.token1) + 1);
        }
        assertNotEq(PoolId.unwrap(poolKey.toPoolId()), PoolId.unwrap(id));
    }

    function test_toPoolId_changesWithExtension(PoolKey memory poolKey) public pure {
        PoolId id = poolKey.toPoolId();
        unchecked {
            poolKey.config = createConcentratedPoolConfig(
                poolKey.config.fee(),
                poolKey.config.concentratedTickSpacing(),
                address(uint160(poolKey.config.extension()) + 1)
            );
        }
        assertNotEq(PoolId.unwrap(poolKey.toPoolId()), PoolId.unwrap(id));
    }

    function test_toPoolId_changesWithFee(PoolKey memory poolKey) public pure {
        PoolId id = poolKey.toPoolId();
        unchecked {
            poolKey.config = createConcentratedPoolConfig(
                poolKey.config.fee() + 1, poolKey.config.concentratedTickSpacing(), poolKey.config.extension()
            );
        }
        assertNotEq(PoolId.unwrap(poolKey.toPoolId()), PoolId.unwrap(id));
    }

    function test_toPoolId_changesWithTickSpacing(PoolKey memory poolKey) public pure {
        PoolId id = poolKey.toPoolId();
        unchecked {
            poolKey.config = createConcentratedPoolConfig(
                poolKey.config.fee(), poolKey.config.concentratedTickSpacing() + 1, poolKey.config.extension()
            );
        }
        assertNotEq(PoolId.unwrap(poolKey.toPoolId()), PoolId.unwrap(id));
    }

    function check_toPoolId_aligns_with_eq(PoolKey memory pk0, PoolKey memory pk1) public pure {
        PoolId pk0Id = pk0.toPoolId();
        PoolId pk1Id = pk1.toPoolId();

        assertEq(
            pk0.token0 == pk1.token0 && pk0.token1 == pk1.token1
                && PoolConfig.unwrap(pk0.config) == PoolConfig.unwrap(pk1.config),
            PoolId.unwrap(pk0Id) == PoolId.unwrap(pk1Id)
        );
    }

    function test_toPoolId_hash_matches_abi_encode(PoolKey memory pk) public pure {
        PoolId id = pk.toPoolId();
        assertEq(PoolId.unwrap(id), keccak256(abi.encode(pk)));
    }
}
