// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {PoolKey, InvalidTokens, InvalidTickSpacing} from "../../src/types/keys.sol";

contract KeysTest is Test {
    function test_poolKey_validateTokens_zero() public {
        vm.expectRevert(InvalidTokens.selector);
        PoolKey({token0: address(0), token1: address(1), fee: 0, tickSpacing: 0, extension: address(0)}).validatePoolKey(
        );
    }

    function test_poolKey_validateTokens_order() public {
        vm.expectRevert(InvalidTokens.selector);
        PoolKey({token0: address(2), token1: address(1), fee: 0, tickSpacing: 0, extension: address(0)}).validatePoolKey(
        );
    }

    function test_poolKey_validateTokens_equal() public {
        vm.expectRevert(InvalidTokens.selector);
        PoolKey({token0: address(2), token1: address(2), fee: 0, tickSpacing: 0, extension: address(0)}).validatePoolKey(
        );
    }

    function test_poolKey_validateTickSpacing() public {
        vm.expectRevert(InvalidTickSpacing.selector);
        PoolKey({token0: address(1), token1: address(2), fee: 0, tickSpacing: 0, extension: address(0)}).validatePoolKey(
        );
    }
}
