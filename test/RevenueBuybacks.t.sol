// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {BaseOrdersTest} from "./Orders.t.sol";
import {RevenueBuybacks, BuybacksState, IOrders} from "../src/RevenueBuybacks.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {PoolKey, toConfig} from "../src/types/poolKey.sol";
import {Bounds} from "../src/types/positionKey.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract RevenueBuybacksTest is BaseOrdersTest {
    using CoreLib for *;

    RevenueBuybacks rb;

    function setUp() public override {
        BaseOrdersTest.setUp();
        // it always buys back ETH
        rb = new RevenueBuybacks(core, address(this), IOrders(address(orders)), address(0));

        vm.prank(core.owner());
        core.transferOwnership(address(rb));
    }

    function test_reclaim_transfers_ownership() public {
        assertEq(core.owner(), address(rb));
        rb.reclaim();
        assertEq(core.owner(), address(this));
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
        assertEq(orders.ownerOf(rb.nftId()), address(rb));
    }

    function test_configure() public {
        (uint32 targetOrderDuration, uint32 minOrderDuration, uint64 fee, uint64 lastEndTime, uint64 lastFee) =
            rb.states(address(token0));
        assertEq(targetOrderDuration, 0);
        assertEq(minOrderDuration, 0);
        assertEq(fee, 0);
        assertEq(lastEndTime, 0);
        assertEq(lastFee, 0);

        uint64 nextFee = uint64((uint256(1) << 64) / 100);
        rb.configure({token: address(token0), targetOrderDuration: 3600, minOrderDuration: 1800, fee: nextFee});

        (targetOrderDuration, minOrderDuration, fee, lastEndTime, lastFee) = rb.states(address(token0));
        assertEq(targetOrderDuration, 3600);
        assertEq(minOrderDuration, 1800);
        assertEq(fee, nextFee);
        assertEq(lastEndTime, 0);
        assertEq(lastFee, 0);
    }

    function generateProtocolFees() private {
        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: toConfig({_extension: address(0), _fee: type(uint64).max, _tickSpacing: 0})
        });

        positions.maybeInitializePool(poolKey, 0);

        Bounds memory bounds = Bounds(MIN_TICK, MAX_TICK);

        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);

        uint256 positionId = positions.mint();
        (uint128 liquidity,,) = positions.deposit(positionId, poolKey, bounds, type(uint64).max, type(uint64).max, 0);
        positions.withdraw(positionId, poolKey, bounds, liquidity, address(this), false);
    }

    function test_generateProtocolFees() public {
        generateProtocolFees();
        assertEq(core.protocolFeesCollected(address(token0)), type(uint64).max - 1);
        assertEq(core.protocolFeesCollected(address(token1)), type(uint64).max - 1);
    }

    function test_roll() public {
        rb.configure({
            token: address(token0),
            targetOrderDuration: 3600,
            minOrderDuration: 1800,
            fee: uint64((uint256(1) << 64) / 100)
        });

        PoolKey memory poolKey = PoolKey({
            token1: address(0),
            token0: address(token0),
            config: toConfig({_extension: address(twamm), _fee: type(uint64).max, _tickSpacing: 0})
        });
    }
}
