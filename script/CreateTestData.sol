// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Positions} from "../src/Positions.sol";
import {Oracle} from "../src/extensions/Oracle.sol";
import {TestToken} from "../test/TestToken.sol";
import {MAX_TICK_SPACING, NATIVE_TOKEN_ADDRESS, FULL_RANGE_ONLY_TICK_SPACING} from "../src/math/constants.sol";
import {SlippageChecker} from "../src/base/SlippageChecker.sol";
import {Router, RouteNode, TokenAmount} from "../src/Router.sol";
import {Bounds} from "../src/types/positionKey.sol";
import {maxBounds} from "../test/SolvencyInvariantTest.t.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";

contract CreateTestDataScript is Script {
    function generateTestData(Positions positions, Router router, Oracle oracle) private {
        TestToken token = new TestToken(vm.getWallets()[0]);

        token.approve(address(router), type(uint256).max);
        token.approve(address(positions), type(uint256).max);

        uint256 baseSalt = uint256(keccak256(abi.encode(token)));

        // 30 basis points fee, 0.6% tick spacing, starting price of 5k, 0.01 ETH
        PoolKey memory poolKey = createPool(
            baseSalt++,
            positions,
            NATIVE_TOKEN_ADDRESS,
            address(token),
            uint128((uint256(30) << 128) / 10_000),
            5982,
            maxBounds(5982),
            address(0),
            8517197,
            10000000000000000,
            50000000000000000000
        );

        // 2 example swaps, back and forth, twice, to demonstrate gas usage
        for (uint256 i = 0; i < 2; i++) {
            router.swap{value: 100000}(poolKey, false, 100000, SqrtRatio.wrap(0), 0);

            router.swap(poolKey, true, 100000 * 5000, SqrtRatio.wrap(0), 0);
        }

        // 2 example swaps, back and forth, twice, to demonstrate gas usage
        for (uint256 i = 0; i < 2; i++) {
            router.swap{value: 100000}(poolKey, false, 100000, SqrtRatio.wrap(0), 0);

            router.swap(poolKey, true, 100000 * 5000, SqrtRatio.wrap(0), 0);
        }

        // 100 basis points fee, 2% tick spacing, starting price of 10k, 0.03 ETH
        createPool(
            baseSalt++,
            positions,
            NATIVE_TOKEN_ADDRESS,
            address(token),
            uint128((uint256(100) << 128) / 10_000),
            19802,
            maxBounds(19802),
            address(0),
            8517197,
            30000000000000000,
            300000000000000000000
        );

        poolKey = createPool(
            baseSalt++,
            positions,
            NATIVE_TOKEN_ADDRESS,
            address(token),
            0,
            FULL_RANGE_ONLY_TICK_SPACING,
            maxBounds(MAX_TICK_SPACING),
            address(oracle),
            4605172,
            1e18,
            100e18
        );

        // 2 example swaps, back and forth, twice, to demonstrate gas usage
        for (uint256 i = 0; i < 2; i++) {
            router.swap{value: 100000}(poolKey, false, 100000, SqrtRatio.wrap(0), 0);

            router.swap(poolKey, true, 100000 * 5000, SqrtRatio.wrap(0), 0);
        }
    }

    function createPool(
        uint256 salt,
        Positions positions,
        address tokenA,
        address tokenB,
        uint128 fee,
        uint32 tickSpacing,
        Bounds memory bounds,
        address extension,
        int32 startingTick,
        uint128 maxAmount0,
        uint128 maxAmount1
    ) private returns (PoolKey memory poolKey) {
        (tokenA, tokenB, startingTick, maxAmount0, maxAmount1) = tokenA < tokenB
            ? (tokenA, tokenB, startingTick, maxAmount0, maxAmount1)
            : (tokenB, tokenA, -startingTick, maxAmount1, maxAmount0);
        poolKey = PoolKey({token0: tokenA, token1: tokenB, fee: fee, tickSpacing: tickSpacing, extension: extension});

        bool isETH = tokenA == NATIVE_TOKEN_ADDRESS;
        bytes[] memory calls = isETH ? new bytes[](3) : new bytes[](2);

        calls[0] = abi.encodeWithSelector(Positions.maybeInitializePool.selector, poolKey, startingTick);
        calls[1] = abi.encodeWithSelector(
            Positions.mintAndDepositWithSalt.selector, salt, poolKey, bounds, maxAmount0, maxAmount1, 0
        );
        if (isETH) {
            calls[2] = abi.encodeWithSelector(SlippageChecker.refundNativeToken.selector);
        }

        positions.multicall{value: isETH ? maxAmount0 : 0}(calls);
    }

    function run() public {
        vm.startBroadcast();

        address payable positions = payable(vm.envAddress("POSITIONS_ADDRESS"));
        address payable router = payable(vm.envAddress("ROUTER_ADDRESS"));
        address oracle = vm.envAddress("ORACLE_ADDRESS");

        generateTestData(Positions(positions), Router(router), Oracle(oracle));

        vm.stopBroadcast();
    }
}
