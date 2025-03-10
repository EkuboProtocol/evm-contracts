// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {Positions} from "../src/Positions.sol";
import {TestToken} from "../test/TestToken.sol";
import {MAX_TICK_SPACING, NATIVE_TOKEN_ADDRESS, FULL_RANGE_ONLY_TICK_SPACING} from "../src/math/constants.sol";
import {SlippageChecker} from "../src/base/SlippageChecker.sol";
import {Router, RouteNode, TokenAmount} from "../src/Router.sol";
import {Orders} from "../src/Orders.sol";
import {OrderKey} from "../src/extensions/TWAMM.sol";
import {Bounds} from "../src/types/positionKey.sol";
import {maxBounds} from "../test/SolvencyInvariantTest.t.sol";
import {PoolKey, toConfig} from "../src/types/poolKey.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";

contract CreateTWAMMTestDataScript is Script {
    function generateTestData(Positions positions, Router router, Orders orders) private {
        TestToken token = new TestToken(vm.getWallets()[0]);

        token.approve(address(router), type(uint256).max);
        token.approve(address(positions), type(uint256).max);

        uint256 baseSalt = uint256(keccak256(abi.encode(token)));

        // 100 basis points fee, 2% tick spacing, starting price of 10k, 0.03 ETH, twamm pool
        createPool(
            baseSalt++,
            positions,
            NATIVE_TOKEN_ADDRESS,
            address(token),
            uint64((uint256(100) << 64) / 10_000),
            0,
            maxBounds(0),
            address(orders.twamm()),
            8517197,
            0.03e18,
            300e18
        );

        token.approve(address(orders), type(uint256).max);
        orders.mintAndIncreaseSellAmount(
            OrderKey({
                sellToken: address(token),
                buyToken: NATIVE_TOKEN_ADDRESS,
                fee: uint64((uint256(100) << 64) / 10_000),
                startTime: 0,
                endTime: (block.timestamp / 16) * 16 + 240
            }),
            100e18,
            type(uint112).max
        );
        orders.mintAndIncreaseSellAmount{value: 0.005e18}(
            OrderKey({
                sellToken: NATIVE_TOKEN_ADDRESS,
                buyToken: address(token),
                fee: uint64((uint256(100) << 64) / 10_000),
                startTime: 0,
                endTime: ((block.timestamp / 8_192) + 2) * 8_192
            }),
            0.005e18,
            type(uint112).max
        );
    }

    function createPool(
        uint256 salt,
        Positions positions,
        address tokenA,
        address tokenB,
        uint64 fee,
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
        poolKey = PoolKey({token0: tokenA, token1: tokenB, config: toConfig(fee, tickSpacing, extension)});

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
        address payable orders = payable(vm.envAddress("ORDERS_ADDRESS"));

        generateTestData(Positions(positions), Router(router), Orders(orders));

        vm.stopBroadcast();
    }
}
