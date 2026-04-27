// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseOrdersTest} from "./Orders.t.sol";
import {TWAMMJITCancel} from "../src/TWAMMJITCancel.sol";
import {OrderKey} from "../src/types/orderKey.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {createOrderConfig} from "../src/types/orderConfig.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {computeFee} from "../src/math/fee.sol";
import {computeAmountFromSaleRate} from "../src/math/twamm.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";

contract TWAMMJITCancelTest is BaseOrdersTest {
    using CoreLib for *;

    TWAMMJITCancel internal helper;

    function setUp() public override {
        BaseOrdersTest.setUp();
        helper = new TWAMMJITCancel(core, orders, twamm);
    }

    function test_jit_liquidity_captures_cancellation_fee() public {
        uint64 fee = uint64((uint256(5) << 64) / 100);
        PoolKey memory poolKey = createTwammPool({fee: fee, tick: 0});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e30, 1e30);
        uint128 liquidityBefore = core.poolState(poolKey.toPoolId()).liquidity();

        token0.approve(address(orders), type(uint256).max);

        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(startTime + 256);
        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: startTime, _endTime: endTime})
        });

        (uint256 id, uint112 saleRate) = orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);
        orders.setApprovalForAll(address(helper), true);

        advanceTime(128);

        (uint128 amount0, uint128 amount1) = helper.collectProceedsAndDecreaseSaleRate({id: id, orderKey: key});

        uint128 remainingSellAmount = uint128(computeAmountFromSaleRate(saleRate, 128, false));
        uint128 cancellationFee = computeFee(remainingSellAmount, fee);
        (uint112 saleRateAfter,,,) = orders.executeVirtualOrdersAndGetCurrentOrderInfo(id, key);

        assertEq(saleRateAfter, 0, "order fully canceled");
        assertGt(amount1, 0, "proceeds collected before stopping");
        assertLe(remainingSellAmount - amount0, 1 gwei, "temporary position captured nearly all cancellation fee");
        assertGt(amount0, remainingSellAmount - cancellationFee, "sell token includes captured cancellation fee");
        assertEq(core.poolState(poolKey.toPoolId()).liquidity(), liquidityBefore, "temporary liquidity removed");
    }

    function test_only_order_owner_can_cancel() public {
        uint64 fee = uint64((uint256(5) << 64) / 100);
        PoolKey memory poolKey = createTwammPool({fee: fee, tick: 0});
        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e30, 1e30);

        token0.approve(address(orders), type(uint256).max);

        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(startTime + 256);
        OrderKey memory key = OrderKey({
            token0: poolKey.token0,
            token1: poolKey.token1,
            config: createOrderConfig({_fee: fee, _isToken1: false, _startTime: startTime, _endTime: endTime})
        });

        (uint256 id,) = orders.mintAndIncreaseSellAmount(key, 1e18, type(uint112).max);
        orders.setApprovalForAll(address(helper), true);

        address caller = address(0x1234);
        vm.expectRevert(abi.encodeWithSelector(TWAMMJITCancel.NotOrderOwner.selector, caller, address(this), id));
        vm.prank(caller);
        helper.collectProceedsAndDecreaseSaleRate({id: id, orderKey: key});
    }
}
