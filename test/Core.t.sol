// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Core, IExtension} from "../src/Core.sol";
import {PoolKey, PositionKey} from "../src/types/keys.sol";
import {CallPoints, byteToCallPoints} from "../src/types/callPoints.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, tickToSqrtRatio} from "../src/math/ticks.sol";

contract MockExtension is IExtension {
    function register(Core core, CallPoints calldata expectedCallPoints) external {
        core.registerExtension(expectedCallPoints);
    }

    function beforeInitializePool(PoolKey calldata key, int32 tick) external {}
    function afterInitializePool(PoolKey calldata key, int32 tick, uint256 sqrtRatio) external {}
}

contract CoreTest is Test {
    address public owner = address(0xdeadbeef);
    Core public core;

    function setUp() public {
        core = new Core(owner);
    }

    function test_owner() public view {
        assertEq(core.owner(), owner);
    }

    function test_registerExtension(uint8 b) public {
        vm.assume(b != 0);

        address impl = address(new MockExtension());
        address actual = address((uint160(b) << 152) + 0xdeadbeef);
        vm.etch(actual, impl.code);

        vm.expectEmit(address(core));
        emit Core.ExtensionRegistered(actual);

        MockExtension(actual).register(core, byteToCallPoints(b));
    }

    function test_initializePool(address tokenA, address tokenB, uint128 fee, int32 tick, uint32 tickSpacing) public {
        tickSpacing = uint32(bound(tickSpacing, uint256(1), uint256(MAX_TICK_SPACING)));
        tick = int32(bound(tick, MIN_TICK, MAX_TICK - 1));

        PoolKey memory key = PoolKey({
            token0: tokenA < tokenB ? tokenA : tokenB,
            token1: tokenA < tokenB ? tokenB : tokenA,
            fee: fee,
            tickSpacing: tickSpacing,
            extension: address(0)
        });

        vm.expectEmit(address(core));
        emit Core.PoolInitialized(key, tick, tickToSqrtRatio(tick));

        // call under test
        core.initializePool(key, tick);

        (uint192 _sqrtRatio, int32 _tick) = core.poolPrice(key.toPoolId());
        assertEq(_sqrtRatio, tickToSqrtRatio(tick));
        assertEq(_tick, tick);
    }
}
