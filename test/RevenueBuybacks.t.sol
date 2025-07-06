// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {BaseOrdersTest} from "./Orders.t.sol";
import {RevenueBuybacks, BuybacksState, IOrders} from "../src/RevenueBuybacks.sol";

contract RevenueBuybacksTest is BaseOrdersTest {
    RevenueBuybacks rb;

    function setUp() public override {
        BaseOrdersTest.setUp();
        // it always buys back ETH
        rb = new RevenueBuybacks(core, address(this), IOrders(address(orders)), address(0));
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

        rb.configure(address(token0), 3600, 1800, uint64((uint256(1) << 64) / 100));
    }
}
