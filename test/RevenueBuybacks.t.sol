// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

import {BaseOrdersTest} from "./Orders.t.sol";
import {RevenueBuybacks} from "../src/RevenueBuybacks.sol";
import {IRevenueBuybacks} from "../src/interfaces/IRevenueBuybacks.sol";
import {BuybacksState} from "../src/types/buybacksState.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {createFullRangePoolConfig} from "../src/types/poolConfig.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";
import {TestToken} from "./TestToken.sol";
import {RevenueBuybacksLib} from "../src/libraries/RevenueBuybacksLib.sol";

contract RevenueBuybacksTest is BaseOrdersTest {
    using RevenueBuybacksLib for *;

    IRevenueBuybacks rb;
    TestToken buybacksToken;

    function setUp() public override {
        BaseOrdersTest.setUp();
        buybacksToken = new TestToken(address(this));

        // make it so buybacksToken is always greatest
        if (address(buybacksToken) < address(token1)) {
            (token1, buybacksToken) = (buybacksToken, token1);
        }

        if (address(token1) < address(token0)) {
            (token0, token1) = (token1, token0);
        }

        // it always buys back the buybacksToken
        rb = new RevenueBuybacks(address(this), orders, address(buybacksToken));
    }

    // transfers tokens directly to the buybacks contract for testing
    function donate(address token, uint128 amount) internal {
        if (token == address(0)) {
            vm.deal(address(rb), amount);
        } else {
            TestToken(token).transfer(address(rb), amount);
        }
    }

    function test_setUp_token_order() public view {
        assertGt(uint160(address(token1)), uint160(address(token0)));
        assertGt(uint160(address(buybacksToken)), uint160(address(token1)));
    }

    function test_approve_max() public {
        assertEq(token0.allowance(address(rb), address(orders)), 0);
        rb.approveMax(address(token0));
        assertEq(token0.allowance(address(rb), address(orders)), type(uint256).max);
        // second time no op
        rb.approveMax(address(token0));
        assertEq(token0.allowance(address(rb), address(orders)), type(uint256).max);
    }

    function test_take_by_owner() public {
        token0.transfer(address(rb), 100);
        assertEq(token0.balanceOf(address(rb)), 100);
        rb.take(address(token0), 100);
        assertEq(token0.balanceOf(address(rb)), 0);
    }

    function test_mint_on_create() public view {
        assertEq(orders.ownerOf(rb.NFT_ID()), address(rb));
    }

    function test_configure() public {
        BuybacksState state = rb.state(address(token0));
        assertEq(state.targetOrderDuration(), 0);
        assertEq(state.minOrderDuration(), 0);
        assertEq(state.fee(), 0);
        assertEq(state.lastEndTime(), 0);
        assertEq(state.lastOrderDuration(), 0);
        assertEq(state.lastFee(), 0);

        uint64 nextFee = uint64((uint256(1) << 64) / 100);
        rb.configure({token: address(token0), targetOrderDuration: 3600, minOrderDuration: 1800, fee: nextFee});

        state = rb.state(address(token0));
        assertEq(state.targetOrderDuration(), 3600);
        assertEq(state.minOrderDuration(), 1800);
        assertEq(state.fee(), nextFee);
        assertEq(state.lastEndTime(), 0);
        assertEq(state.lastOrderDuration(), 0);
        assertEq(state.lastFee(), 0);
    }

    function test_configure_invalid() public {
        vm.expectRevert(IRevenueBuybacks.MinOrderDurationGreaterThanTargetOrderDuration.selector);
        rb.configure({token: address(token0), targetOrderDuration: 3600, minOrderDuration: 3601, fee: 0});

        vm.expectRevert(IRevenueBuybacks.MinOrderDurationMustBeGreaterThanZero.selector);
        rb.configure({token: address(token0), targetOrderDuration: 10, minOrderDuration: 0, fee: 0});
    }

    function test_deconfigure() public {
        rb.configure({
            token: address(token0),
            targetOrderDuration: 3600,
            minOrderDuration: 1800,
            fee: uint64((uint256(1) << 64) / 100)
        });

        rb.configure({token: address(token0), targetOrderDuration: 0, minOrderDuration: 0, fee: 0});

        BuybacksState state = rb.state(address(token0));
        assertEq(state.targetOrderDuration(), 0);
        assertEq(state.minOrderDuration(), 0);
        assertEq(state.fee(), 0);
    }

    function test_roll_token_not_configured() public {
        rb.configure({
            token: address(token0),
            targetOrderDuration: 3600,
            minOrderDuration: 1800,
            fee: uint64((uint256(1) << 64) / 100)
        });

        rb.configure({token: address(token0), targetOrderDuration: 0, minOrderDuration: 0, fee: 0});

        vm.expectRevert(abi.encodeWithSelector(IRevenueBuybacks.TokenNotConfigured.selector, token0));
        rb.roll(address(token0));
    }

    function test_roll_token() public {
        uint64 poolFee = uint64((uint256(1) << 64) / 100); // 1%

        rb.configure({token: address(token0), targetOrderDuration: 3600, minOrderDuration: 1800, fee: poolFee});

        donate(address(token0), 1e18);

        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(buybacksToken),
            config: createFullRangePoolConfig({_extension: address(twamm), _fee: poolFee})
        });

        positions.maybeInitializePool(poolKey, 0);
        token0.approve(address(positions), 1e18);
        buybacksToken.approve(address(positions), 1e18);
        positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);

        rb.approveMax(address(token0));

        (uint64 endTime, uint112 saleRate) = rb.roll(address(token0));
        assertEq(endTime, 3840);
        assertEq(saleRate, 1118772413649387861422245);

        advanceTime(1800);
        assertEq(rb.collect(address(token0), poolFee, endTime), 317025440313111544);

        (endTime, saleRate) = rb.roll(address(token0));
        assertEq(endTime, 3840);
        assertEq(saleRate, 0);

        donate(address(token0), 1e17);
        (endTime, saleRate) = rb.roll(address(token0));
        assertEq(endTime, 3840);
        assertEq(saleRate, 210640867876410004904364);
    }

    function test_roll_eth() public {
        uint64 poolFee = uint64((uint256(1) << 64) / 100); // 1%

        rb.configure({token: address(0), targetOrderDuration: 3600, minOrderDuration: 1800, fee: poolFee});

        donate(address(0), 1e18);

        PoolKey memory poolKey = PoolKey({
            token0: address(0),
            token1: address(buybacksToken),
            config: createFullRangePoolConfig({_extension: address(twamm), _fee: poolFee})
        });

        positions.maybeInitializePool(poolKey, 0);
        buybacksToken.approve(address(positions), 1e18);
        positions.mintAndDeposit{value: 1e18}(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);

        (uint64 endTime, uint112 saleRate) = rb.roll(address(0));
        assertEq(endTime, 3840);
        assertEq(saleRate, 1118772413649387861422245);

        advanceTime(1800);
        assertEq(rb.collect(address(0), poolFee, endTime), 317025440313111544);

        (endTime, saleRate) = rb.roll(address(0));
        assertEq(endTime, 3840);
        assertEq(saleRate, 0);

        (endTime, saleRate) = rb.roll(address(0));
        assertEq(endTime, 3840);
        assertEq(saleRate, 0);

        donate(address(0), 1e17);
        (endTime, saleRate) = rb.roll(address(0));
        assertEq(endTime, 3840);
        assertEq(saleRate, 210640867876410004904364);
    }

    function test_roll_timing_fail_example() public {
        test_roll_timing(false, 2127478271, 0, 891784465, 12670);
    }

    function test_roll_timing(
        bool isEth,
        uint64 startTime,
        uint32 targetOrderDuration,
        uint32 minOrderDuration,
        uint64 poolFee
    ) public {
        startTime = uint64(bound(startTime, 0, type(uint64).max / 2));
        targetOrderDuration = uint32(bound(targetOrderDuration, 1, type(uint16).max));
        minOrderDuration = uint32(bound(minOrderDuration, 1, targetOrderDuration));

        vm.warp(startTime);

        address token = isEth ? address(0) : address(token0);
        rb.configure({
            token: token, targetOrderDuration: targetOrderDuration, minOrderDuration: minOrderDuration, fee: poolFee
        });

        if (!isEth) {
            rb.approveMax(token);
        }

        donate(token, 1e18);

        PoolKey memory poolKey = PoolKey({
            token0: token,
            token1: address(buybacksToken),
            config: createFullRangePoolConfig({_extension: address(twamm), _fee: poolFee})
        });

        positions.maybeInitializePool(poolKey, 0);
        token0.approve(address(positions), 1e18);
        buybacksToken.approve(address(positions), 1e18);
        positions.mintAndDeposit{value: isEth ? 1e18 : 0}(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);

        (uint64 endTime,) = rb.roll(token);
        assertGt(endTime, startTime, "end time gt");
        assertGe(endTime - startTime, minOrderDuration, "min order duration 2");
        assertGe(endTime - startTime, targetOrderDuration, "target order duration 2");

        uint64 timeSameRoll = endTime - minOrderDuration;
        assertGe(timeSameRoll, startTime, "time for same roll is g.t.e than start time");

        vm.warp(timeSameRoll);
        donate(token, 1e18);

        (uint64 endTime2,) = rb.roll(token);
        assertEq(endTime2, endTime, "end time eq");

        uint64 timeNext = timeSameRoll + 1;
        assertGt(timeNext, startTime, "time next is greater than start");

        vm.warp(timeNext);
        donate(token, 1e18);

        (uint64 endTime3,) = rb.roll(token);
        assertGt(endTime3, endTime, "end time gt 3");
        assertGe(endTime3 - timeNext, minOrderDuration, "min order duration 3");
        assertGe(endTime3 - timeNext, targetOrderDuration, "target order duration 3");

        timeNext = endTime3 + 1;
        vm.warp(timeNext);
        donate(token, 1e18);
        (uint64 endTime4,) = rb.roll(token);
        assertGt(endTime4, endTime3);
        assertGe(endTime4 - timeNext, minOrderDuration, "min order duration 4");
        assertGe(endTime4 - timeNext, targetOrderDuration, "target order duration 4");

        timeNext = endTime4 + type(uint32).max + 1;
        vm.warp(timeNext);
        donate(token, 1e18);
        (uint64 endTime5,) = rb.roll(token);
        assertGt(endTime5, endTime4);
        assertGe(endTime5 - timeNext, minOrderDuration, "min order duration 4");
        assertGe(endTime5 - timeNext, targetOrderDuration, "target order duration 4");
    }
}
