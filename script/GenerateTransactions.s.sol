// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script} from "forge-std/Script.sol";
import {Positions} from "../src/Positions.sol";
import {CoreLocker} from "../src/base/CoreLocker.sol";
import {Router, RouteNode, TokenAmount} from "../src/Router.sol";
import {CallPoints} from "../src/types/callPoints.sol";
import {TestToken} from "../test/TestToken.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/interfaces/ICore.sol";
import {PoolKey, PositionKey, Bounds, maxBounds} from "../src/types/keys.sol";

contract GenerateTransactions is Script {
    error UnrecognizedChainId(uint256 chainId);

    TestToken public token0 = TestToken(vm.envAddress("TOKEN0"));
    TestToken public token1 = TestToken(vm.envAddress("TOKEN1"));
    Positions public positions = Positions(vm.envAddress("POSITIONS"));
    Router public router = Router(vm.envAddress("ROUTER"));

    function approveIfNecessary(TestToken t, address a) private {
        address spender = vm.getWallets()[0];
        if (t.allowance(spender, a) == 0) {
            t.approve(a, type(uint256).max);
        }
    }

    function run() public {
        vm.startBroadcast();
        approveIfNecessary(token0, address(positions));
        approveIfNecessary(token1, address(positions));
        approveIfNecessary(token0, address(router));
        approveIfNecessary(token1, address(router));

        PoolKey memory poolKey = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: address(token1),
            fee: uint128((uint256(3000) << 128) / 1000000),
            tickSpacing: 5982,
            extension: address(0)
        });

        Bounds memory bounds = Bounds(4606140 - 5982 * 33, 4606140 + 5982 * 33);

        // ~100 token1/token0
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(Positions.maybeInitializePool.selector, poolKey, int32(4606140));
        calls[1] = abi.encodeWithSelector(
            Positions.mintAndDeposit.selector, poolKey, bounds, uint128(10000000), uint128(10000000 * 100), 0
        );
        calls[2] = abi.encodeWithSelector(CoreLocker.refundNativeToken.selector);

        positions.multicall{value: 10000000}(calls);

        router.swap{value: 1000}(RouteNode(poolKey, 0, 0), TokenAmount(NATIVE_TOKEN_ADDRESS, 1000));
        router.swap(RouteNode(poolKey, 0, 0), TokenAmount(address(token1), 100000));

        calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(
            Router.swap.selector, RouteNode(poolKey, 0, 0), TokenAmount(NATIVE_TOKEN_ADDRESS, 1000)
        );
        calls[1] =
            abi.encodeWithSelector(Router.swap.selector, RouteNode(poolKey, 0, 0), TokenAmount(address(token1), 100000));
        calls[2] = abi.encodeWithSelector(CoreLocker.refundNativeToken.selector);
        router.multicall{value: 1000}(calls);

        vm.stopBroadcast();
    }

    receive() external payable {}
}
