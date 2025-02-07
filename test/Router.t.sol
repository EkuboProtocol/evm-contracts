// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {Bounds} from "../src/types/positionKey.sol";
import {
    MIN_SQRT_RATIO,
    MAX_SQRT_RATIO,
    FULL_RANGE_ONLY_TICK_SPACING,
    MIN_TICK,
    MAX_TICK,
    NATIVE_TOKEN_ADDRESS
} from "../src/math/constants.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {FullTest} from "./FullTest.sol";
import {Router, Delta, RouteNode, TokenAmount, Swap} from "../src/Router.sol";
import {Vm} from "forge-std/Test.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";

contract RouterTest is FullTest {
    using CoreLib for *;

    function test_basicSwap_token0_in(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), 100);

        (int128 delta0, int128 delta1) =
            quoter.quote({poolKey: poolKey, sqrtRatioLimit: MIN_SQRT_RATIO, isToken1: false, amount: 100, skipAhead: 0});
        assertEq(delta0, 100);
        assertEq(delta1, -49);

        (delta0, delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );
        assertEq(delta0, 100);
        assertEq(delta1, -49);
    }

    function test_basicSwap_token0_out(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token1.approve(address(router), 202);

        (int128 delta0, int128 delta1) = quoter.quote({
            poolKey: poolKey,
            sqrtRatioLimit: MAX_SQRT_RATIO,
            isToken1: false,
            amount: -100,
            skipAhead: 0
        });
        assertEq(delta0, -100);
        assertEq(delta1, 202);

        (delta0, delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: -100}),
            type(int256).min
        );
        assertEq(delta0, -100);
        assertEq(delta1, 202);
    }

    function test_basicSwap_token1_in(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token1.approve(address(router), 100);

        (int128 delta0, int128 delta1) =
            quoter.quote({poolKey: poolKey, sqrtRatioLimit: MAX_SQRT_RATIO, isToken1: true, amount: 100, skipAhead: 0});
        assertEq(delta0, -49);
        assertEq(delta1, 100);

        (delta0, delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 100}),
            type(int256).min
        );
        assertEq(delta0, -49);
        assertEq(delta1, 100);
    }

    function test_basicSwap_token1_out(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), 202);

        (int128 delta0, int128 delta1) =
            quoter.quote({poolKey: poolKey, sqrtRatioLimit: MIN_SQRT_RATIO, isToken1: true, amount: -100, skipAhead: 0});
        assertEq(delta0, 202);
        assertEq(delta1, -100);

        (delta0, delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token1), amount: -100}),
            type(int256).min
        );
        assertEq(delta0, 202);
        assertEq(delta1, -100);
    }

    function test_basicSwap_token0_in_slippage_check_failed(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, int256(50), int256(49)));
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            50
        );
    }

    function test_basicSwap_token0_out_slippage_check_failed(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, int256(-200), int256(-202)));
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: -100}),
            -200
        );
    }

    function test_basicSwap_token1_in_slippage_check_failed(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, int256(50), int256(49)));
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 100}),
            50
        );
    }

    function test_basicSwap_token1_out_slippage_check_failed(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, int256(-200), int256(-202)));
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token1), amount: -100}),
            -200
        );
    }

    function test_basicSwap_exactOut(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token1.approve(address(router), 202);

        (int128 delta0, int128 delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: -100}),
            type(int256).min
        );
        assertEq(delta0, -100);
        assertEq(delta1, 202);
    }

    function test_multihopSwap(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), 100);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, 0, 0);
        route[1] = RouteNode(poolKey, 0, 0);

        Delta[] memory d =
            router.multihopSwap(Swap(route, TokenAmount({token: address(token0), amount: 100})), type(int256).min);
        assertEq(d[0].amount0, 100);
        assertEq(d[0].amount1, -49);
        assertEq(d[1].amount0, -24);
        assertEq(d[1].amount1, 49);
    }

    function test_multihopSwap_exactOut(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, 0, 0);
        route[1] = RouteNode(poolKey, 0, 0);

        Delta[] memory d =
            router.multihopSwap(Swap(route, TokenAmount({token: address(token0), amount: -100})), type(int256).min);
        assertEq(d[0].amount0, -100);
        assertEq(d[0].amount1, 202);
        assertEq(d[1].amount0, 406);
        assertEq(d[1].amount1, -202);
    }

    function test_multiMultihopSwap(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route0 = new RouteNode[](2);
        route0[0] = RouteNode(poolKey, 0, 0);
        route0[1] = RouteNode(poolKey, 0, 0);

        RouteNode[] memory route1 = new RouteNode[](2);
        route1[0] = RouteNode(poolKey, 0, 0);
        route1[1] = RouteNode(poolKey, 0, 0);

        swaps[0] = Swap(route0, TokenAmount({token: address(token0), amount: 100}));
        swaps[1] = Swap(route1, TokenAmount({token: address(token0), amount: -100}));

        Delta[][] memory d = router.multiMultihopSwap(swaps, type(int256).min);
        assertEq(d[0][0].amount0, 100);
        assertEq(d[0][0].amount1, -49);
        assertEq(d[0][1].amount0, -24);
        assertEq(d[0][1].amount1, 49);

        assertEq(d[1][0].amount0, -100);
        assertEq(d[1][0].amount1, 202);
        assertEq(d[1][1].amount0, 406);
        assertEq(d[1][1].amount1, -202);
    }

    function test_multiMultihopSwap_slippage_input(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, 0, 0);
        route[1] = RouteNode(poolKey, 0, 0);

        swaps[0] = Swap(route, TokenAmount({token: address(token0), amount: 100}));
        swaps[1] = Swap(route, TokenAmount({token: address(token0), amount: 100}));

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, 49, 48));
        router.multiMultihopSwap(swaps, 49);
        // 48 works
        router.multiMultihopSwap(swaps, 48);
    }

    function test_multiMultihopSwap_slippage_output(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, 0, 0);
        route[1] = RouteNode(poolKey, 0, 0);

        swaps[0] = Swap(route, TokenAmount({token: address(token0), amount: -100}));
        swaps[1] = Swap(route, TokenAmount({token: address(token0), amount: -100}));

        vm.expectRevert(abi.encodeWithSelector(Router.SlippageCheckFailed.selector, -807, -808));
        router.multiMultihopSwap(swaps, -807);
        // -808 works
        router.multiMultihopSwap(swaps, -808);
    }

    function test_validation_Swaps() public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100);
        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route = new RouteNode[](1);
        route[0] = RouteNode(poolKey, 0, 0);

        swaps[0] = Swap(route, TokenAmount({token: address(token0), amount: 100}));
        swaps[1] = Swap(route, TokenAmount({token: address(token1), amount: 100}));

        vm.expectRevert();
        router.multiMultihopSwap(swaps, type(int256).min);
    }

    function test_coreEmitsSwapLogs() public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100);
        (, uint128 liquidity) = createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), type(uint256).max);

        Swap[] memory swaps = new Swap[](2);

        RouteNode[] memory route = new RouteNode[](2);
        route[0] = RouteNode(poolKey, 0, 0);
        route[1] = RouteNode(poolKey, 0, 0);

        swaps[0] = Swap(route, TokenAmount({token: address(token0), amount: -100}));
        swaps[1] = Swap(route, TokenAmount({token: address(token0), amount: -100}));

        vm.recordLogs();
        Delta[][] memory deltas = router.multiMultihopSwap(swaps, -808);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 6);
        // swap events emit have 0 topics and come from core
        for (uint256 i = 0; i < 4; i++) {
            assertEq(logs[i].emitter, address(core));
            assertEq(logs[i].topics.length, 0);
            assertEq(logs[i].data.length, 128);
            address locker = address(bytes20(LibBytes.load(logs[i].data, 0)));
            assertEq(locker, address(router));
            bytes32 poolId = LibBytes.load(logs[i].data, 20);
            assertEq(poolId, poolKey.toPoolId());

            assertEq(uint256(LibBytes.load(logs[i].data, 84)) >> 128, liquidity);
        }

        assertEq(int128(uint128(bytes16(LibBytes.load(logs[0].data, 52)))), deltas[0][0].amount0);
        assertEq(int128(uint128(bytes16(LibBytes.load(logs[0].data, 68)))), deltas[0][0].amount1);
        assertEq(uint256(LibBytes.load(logs[0].data, 100)) >> 64, 340284068297894840549961649270447677369);
        assertEq(int32(uint32(bytes4(LibBytes.load(logs[0].data, 124)))), 9);

        assertEq(int128(uint128(bytes16(LibBytes.load(logs[1].data, 52)))), deltas[0][1].amount0);
        assertEq(int128(uint128(bytes16(LibBytes.load(logs[1].data, 68)))), deltas[0][1].amount1);
        assertEq(uint256(LibBytes.load(logs[1].data, 100)) >> 64, 340280631533626427916002835136673027763);
        assertEq(int32(uint32(bytes4(LibBytes.load(logs[1].data, 124)))), -11);

        assertEq(int128(uint128(bytes16(LibBytes.load(logs[2].data, 52)))), deltas[1][0].amount0);
        assertEq(int128(uint128(bytes16(LibBytes.load(logs[2].data, 68)))), deltas[1][0].amount1);
        assertEq(uint256(LibBytes.load(logs[2].data, 100)) >> 64, 340282332893229288497002972529139644052);
        assertEq(int32(uint32(bytes4(LibBytes.load(logs[2].data, 124)))), -1);

        assertEq(int128(uint128(bytes16(LibBytes.load(logs[3].data, 52)))), deltas[1][1].amount0);
        assertEq(int128(uint128(bytes16(LibBytes.load(logs[3].data, 68)))), deltas[1][1].amount1);
        assertEq(uint256(LibBytes.load(logs[3].data, 100)) >> 64, 340278930156329870047538800119461773155);
        assertEq(int32(uint32(bytes4(LibBytes.load(logs[3].data, 124)))), -21);
    }

    function test_basicSwap_price_2x(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(693147, 1 << 127, 100, callPoints);
        createPosition(poolKey, Bounds(693100, 693200), 1000, 1000);

        token0.approve(address(router), 100);

        (int128 delta0, int128 delta1) = router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );
        assertEq(delta0, 100);
        // approximately 1x after fee
        assertEq(delta1, -99);
    }

    function test_swap_gas() public {
        PoolKey memory poolKey = createPool(0, 1 << 127, 100);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token0.approve(address(router), 100);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );
        vm.snapshotGasLastCall("swap 100 token0 for token1");
    }

    function test_swap_token_for_eth_gas() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 127, 100);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token1.approve(address(router), 100);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 100}),
            type(int256).min
        );
        vm.snapshotGasLastCall("swap 100 token0 for eth");
    }

    function test_swap_eth_for_token_gas() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 127, 100);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        router.swap{value: 100}(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: NATIVE_TOKEN_ADDRESS, amount: 100}),
            type(int256).min
        );
        vm.snapshotGasLastCall("swap 100 wei of eth for token");
    }

    function test_swap_token_for_eth_gas_simple() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 127, 100);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        token1.approve(address(swapper), 100);

        swapper.swap(poolKey, true, 100, MAX_SQRT_RATIO, 0);
        vm.snapshotGasLastCall("simple swap 100 token0 for eth");
    }

    function test_swap_eth_for_token_gas_simple() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 127, 100);
        createPosition(poolKey, Bounds(-100, 100), 1000, 1000);

        swapper.swap{value: 100}(poolKey, false, 100, MIN_SQRT_RATIO, 0);
        vm.snapshotGasLastCall("simple swap 100 wei of eth for token");
    }

    function test_swap_eth_for_token_full_range_pool_gas() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 127, FULL_RANGE_ONLY_TICK_SPACING);
        createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 1000, 1000);

        router.swap{value: 100}(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: NATIVE_TOKEN_ADDRESS, amount: 100}),
            type(int256).min
        );
        vm.snapshotGasLastCall("swap 100 wei of eth for token full range");
    }

    function test_swap_token_for_eth_full_range_pool_gas() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 127, FULL_RANGE_ONLY_TICK_SPACING);
        createPosition(poolKey, Bounds(MIN_TICK, MAX_TICK), 1000, 1000);

        token1.approve(address(router), 100);
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: 0, skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 100}),
            type(int256).min
        );
        vm.snapshotGasLastCall("swap 100 wei of token for eth full range");
    }

    receive() external payable {}
}
