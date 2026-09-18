// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseOrdersTest} from "../Orders.t.sol";
import {TestToken} from "../TestToken.sol";
import {RunrRevenueBuybacks} from "../../src/launchpad/RunrRevenueBuybacks.sol";
import {TreasuryVault} from "../../src/launchpad/TreasuryVault.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {createFullRangePoolConfig} from "../../src/types/poolConfig.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";

contract RunrRevenueBuybacksTest is BaseOrdersTest {
    RunrRevenueBuybacks rb;
    TreasuryVault treasury;
    TestToken runr;
    uint64 constant POOL_FEE = uint64((uint256(1) << 64) / 100);

    function setUp() public override {
        BaseOrdersTest.setUp();
        runr = new TestToken(address(this));
        // Keep RUNR the greatest address so it is always token1 of the buyback pool.
        if (address(runr) < address(token1)) {
            (token1, runr) = (runr, token1);
        }
        if (address(token1) < address(token0)) {
            (token0, token1) = (token1, token0);
        }
        treasury = new TreasuryVault(address(this));
        rb = new RunrRevenueBuybacks(address(this), orders, address(runr), treasury);
        treasury.setDepositor(address(rb), true);
    }

    function _seedCanonicalPool() internal returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            token0: address(token0),
            token1: address(runr),
            config: createFullRangePoolConfig({_extension: address(twamm), _fee: POOL_FEE})
        });
        positions.maybeInitializePool(poolKey, 0);
        token0.approve(address(positions), 1e18);
        runr.approve(address(positions), 1e18);
        positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);
    }

    function test_wiring() public view {
        assertEq(rb.BUY_TOKEN(), address(runr));
        assertEq(address(rb.TREASURY()), address(treasury));
        assertEq(address(rb.ORDERS()), address(orders));
        assertEq(orders.ownerOf(rb.NFT_ID()), address(rb));
        assertEq(rb.owner(), address(this));
    }

    function test_settleDepositsProceedsIntoTreasury() public {
        rb.configure(address(token0), 3600, 1800, POOL_FEE);
        _seedCanonicalPool();
        token0.transfer(address(rb), 1e18);
        (uint64 endTime, uint112 saleRate) = rb.roll(address(token0));
        assertGt(saleRate, 0);
        advanceTime(1800);
        uint128 proceeds = rb.settle(address(token0), POOL_FEE, endTime);
        assertGt(proceeds, 0);
        assertEq(runr.balanceOf(address(treasury)), proceeds);
        assertEq(runr.balanceOf(address(rb)), 0);
        assertEq(runr.balanceOf(address(this)), type(uint256).max - 1e18);
        assertEq(treasury.ledger(address(runr), TreasuryVault.Category.RUNR_BUYBACK), proceeds);
        assertEq(runr.allowance(address(rb), address(treasury)), 0);
        // Remaining order keeps executing; a later settle books more.
        advanceTime(1800);
        uint128 more = rb.settle(address(token0), POOL_FEE, endTime);
        assertGt(more, 0);
        assertEq(treasury.ledger(address(runr), TreasuryVault.Category.RUNR_BUYBACK), proceeds + more);
    }

    function test_settleWithoutProceedsBooksNothing() public {
        rb.configure(address(token0), 3600, 1800, POOL_FEE);
        _seedCanonicalPool();
        token0.transfer(address(rb), 1e18);
        (uint64 endTime,) = rb.roll(address(token0));
        vm.expectEmit(true, false, false, true, address(rb));
        emit RunrRevenueBuybacks.Settled(address(token0), POOL_FEE, endTime, 0);
        assertEq(rb.settle(address(token0), POOL_FEE, endTime), 0);
        assertEq(treasury.ledger(address(runr), TreasuryVault.Category.RUNR_BUYBACK), 0);
    }

    function test_settleRequiresDepositorRole() public {
        rb.configure(address(token0), 3600, 1800, POOL_FEE);
        _seedCanonicalPool();
        token0.transfer(address(rb), 1e18);
        (uint64 endTime,) = rb.roll(address(token0));
        advanceTime(1800);
        treasury.setDepositor(address(rb), false);
        vm.expectRevert(TreasuryVault.DepositorOnly.selector);
        rb.settle(address(token0), POOL_FEE, endTime);
    }
}
