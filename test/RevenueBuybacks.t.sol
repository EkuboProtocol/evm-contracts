// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {BaseOrdersTest} from "./Orders.t.sol";
import {EkuboRevenueBuybacks, BuybacksState} from "../src/RevenueBuybacks.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {PoolKey, toConfig} from "../src/types/poolKey.sol";
import {Bounds} from "../src/types/positionKey.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {TestToken} from "./TestToken.sol";

contract RevenueBuybacksTest is BaseOrdersTest {
    using CoreLib for *;

    EkuboRevenueBuybacks rb;
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
        rb = new EkuboRevenueBuybacks(positions, address(this), orders, address(buybacksToken));

        vm.prank(positions.owner());
        positions.transferOwnership(address(rb));
    }

    // increases the saved balance of the core contract
    function donateViaCore(address token0, address token1, uint128 amount0, uint128 amount1) internal {
        (uint128 amount0Old, uint128 amount1Old) = positions.getProtocolFees(token0, token1);

        vm.store(
            address(core),
            CoreLib.savedBalancesSlot(address(positions), token0, token1, bytes32(0)),
            bytes32(((uint256(amount0Old + amount0) << 128)) | uint256(amount1Old + amount1))
        );

        if (token0 == address(0)) {
            vm.deal(address(core), amount0);
        } else {
            TestToken(token0).transfer(address(core), amount0);
        }
        TestToken(token1).transfer(address(core), amount1);
    }

    function test_donateViaCore(bool useEth, uint128 amount0, uint128 amount1) public {
        address token0 = useEth ? address(0) : address(token0);
        donateViaCore(token0, address(token1), amount0, amount1);

        (uint128 amount0Next, uint128 amount1Next) = positions.getProtocolFees(token0, address(token1));
        assertEq(amount0Next, amount0);
        assertEq(amount1Next, amount1);
    }

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

    function test_reclaim_transfers_ownership() public {
        assertEq(positions.owner(), address(rb));
        rb.reclaim();
        assertEq(positions.owner(), address(this));
    }

    function test_reclaim_fails_if_not_owner() public {
        vm.prank(address(uint160(0xdeadbeef)));
        vm.expectRevert(Ownable.Unauthorized.selector);
        rb.reclaim();
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
        (
            uint32 targetOrderDuration,
            uint32 minOrderDuration,
            uint64 fee,
            uint32 lastEndTime,
            uint32 lastOrderDuration,
            uint64 lastFee
        ) = rb.states(address(token0));
        assertEq(targetOrderDuration, 0);
        assertEq(minOrderDuration, 0);
        assertEq(fee, 0);
        assertEq(lastEndTime, 0);
        assertEq(lastOrderDuration, 0);
        assertEq(lastFee, 0);

        uint64 nextFee = uint64((uint256(1) << 64) / 100);
        rb.configure({token: address(token0), targetOrderDuration: 3600, minOrderDuration: 1800, fee: nextFee});

        (targetOrderDuration, minOrderDuration, fee, lastEndTime, lastOrderDuration, lastFee) =
            rb.states(address(token0));
        assertEq(targetOrderDuration, 3600);
        assertEq(minOrderDuration, 1800);
        assertEq(fee, nextFee);
        assertEq(lastEndTime, 0);
        assertEq(lastOrderDuration, 0);
        assertEq(lastFee, 0);
    }

    function test_roll_token() public {
        uint64 poolFee = uint64((uint256(1) << 64) / 100); // 1%

        rb.configure({token: address(token0), targetOrderDuration: 3600, minOrderDuration: 1800, fee: poolFee});

        donate(address(token0), 1e18);

        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(buybacksToken),
            config: toConfig({_extension: address(twamm), _fee: poolFee, _tickSpacing: 0})
        });

        positions.maybeInitializePool(poolKey, 0);
        token0.approve(address(positions), 1e18);
        buybacksToken.approve(address(positions), 1e18);
        positions.mintAndDeposit(poolKey, Bounds(MIN_TICK, MAX_TICK), 1e18, 1e18, 0);

        rb.approveMax(address(token0));

        (uint256 endTime, uint112 saleRate) = rb.roll(address(token0));
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
            config: toConfig({_extension: address(twamm), _fee: poolFee, _tickSpacing: 0})
        });

        positions.maybeInitializePool(poolKey, 0);
        buybacksToken.approve(address(positions), 1e18);
        positions.mintAndDeposit{value: 1e18}(poolKey, Bounds(MIN_TICK, MAX_TICK), 1e18, 1e18, 0);

        (uint256 endTime, uint112 saleRate) = rb.roll(address(0));
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
        bool isETH,
        uint256 startTime,
        uint32 targetOrderDuration,
        uint32 minOrderDuration,
        uint64 poolFee
    ) public {
        startTime = bound(startTime, 0, type(uint256).max - type(uint64).max);
        targetOrderDuration = uint32(bound(targetOrderDuration, 1, type(uint16).max));
        minOrderDuration = uint32(bound(minOrderDuration, 1, targetOrderDuration));

        vm.warp(startTime);

        address token = isETH ? address(0) : address(token0);
        rb.configure({
            token: token,
            targetOrderDuration: targetOrderDuration,
            minOrderDuration: minOrderDuration,
            fee: poolFee
        });

        if (!isETH) {
            rb.approveMax(token);
        }

        donate(token, 1e18);

        PoolKey memory poolKey = PoolKey({
            token0: token,
            token1: address(buybacksToken),
            config: toConfig({_extension: address(twamm), _fee: poolFee, _tickSpacing: 0})
        });

        positions.maybeInitializePool(poolKey, 0);
        token0.approve(address(positions), 1e18);
        buybacksToken.approve(address(positions), 1e18);
        positions.mintAndDeposit{value: isETH ? 1e18 : 0}(poolKey, Bounds(MIN_TICK, MAX_TICK), 1e18, 1e18, 0);

        (uint256 endTime,) = rb.roll(token);
        assertGt(endTime, startTime, "end time gt");
        assertGe(endTime - startTime, minOrderDuration, "min order duration 2");
        assertGe(endTime - startTime, targetOrderDuration, "target order duration 2");

        uint256 timeSameRoll = endTime - minOrderDuration;
        assertGe(timeSameRoll, startTime, "time for same roll is g.t.e than start time");

        vm.warp(timeSameRoll);
        donate(token, 1e18);

        (uint256 endTime2,) = rb.roll(token);
        assertEq(endTime2, endTime, "end time eq");

        uint256 timeNext = timeSameRoll + 1;
        assertGt(timeNext, startTime, "time next is greater than start");

        vm.warp(timeNext);
        donate(token, 1e18);

        (uint256 endTime3,) = rb.roll(token);
        assertGt(endTime3, endTime, "end time gt 3");
        assertGe(endTime3 - timeNext, minOrderDuration, "min order duration 3");
        assertGe(endTime3 - timeNext, targetOrderDuration, "target order duration 3");

        timeNext = endTime3 + 1;
        vm.warp(timeNext);
        donate(token, 1e18);
        (uint256 endTime4,) = rb.roll(token);
        assertGt(endTime4, endTime3);
        assertGe(endTime4 - timeNext, minOrderDuration, "min order duration 4");
        assertGe(endTime4 - timeNext, targetOrderDuration, "target order duration 4");

        timeNext = endTime4 + type(uint32).max + 1;
        vm.warp(timeNext);
        donate(token, 1e18);
        (uint256 endTime5,) = rb.roll(token);
        assertGt(endTime5, endTime4);
        assertGe(endTime5 - timeNext, minOrderDuration, "min order duration 4");
        assertGe(endTime5 - timeNext, targetOrderDuration, "target order duration 4");
    }
}
