// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {Positions} from "../src/Positions.sol";
import {Router, RouteNode, TokenAmount} from "../src/Router.sol";
import {CallPoints} from "../src/types/callPoints.sol";
import {TestToken} from "../test/TestToken.sol";
import {PoolKey, PositionKey, Bounds, maxBounds} from "../src/types/keys.sol";

contract GenerateTransactions is Script {
    error UnrecognizedChainId(uint256 chainId);

    TestToken public token0 = TestToken(vm.envAddress("TOKEN0"));
    TestToken public token1 = TestToken(vm.envAddress("TOKEN1"));
    Positions public positions = Positions(vm.envAddress("POSITIONS"));
    Router public router = Router(vm.envAddress("ROUTER"));

    function run() public {
        vm.startBroadcast();
        // token0.approve(address(positions), type(uint256).max);
        // token1.approve(address(positions), type(uint256).max);
        // token0.approve(address(router), type(uint256).max);
        // token1.approve(address(router), type(uint256).max);

        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            fee: uint128((uint256(3000) << 128) / 1000000),
            tickSpacing: 5982,
            extension: address(0)
        });

        // Bounds memory bounds = Bounds(4606140 - 5982 * 33, 4606140 + 5982 * 33);

        // ~100 token1/token0
        // positions.maybeInitializePool(poolKey, 4606140);
        // +/- 10%
        // positions.mintAndDeposit(poolKey, bounds, 10000000, 10000000 * 100, 0);

        router.swap(RouteNode(poolKey, 0, 0), TokenAmount(address(token0), 1000));
        router.swap(RouteNode(poolKey, 0, 0), TokenAmount(address(token1), 100000));

        vm.stopBroadcast();
    }
}
