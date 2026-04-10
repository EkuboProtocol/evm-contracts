// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseOrdersTest} from "./Orders.t.sol";
import {TWAMMRecoverableLiquidations} from "../src/TWAMMRecoverableLiquidations.sol";
import {ITWAMMRecoverableLiquidations} from "../src/interfaces/ITWAMMRecoverableLiquidations.sol";
import {IERC7726} from "../src/lens/ERC7726.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";

contract MockQuoter is IERC7726 {
    uint256 public quotePerBaseX18 = 1e18;

    function setQuotePerBaseX18(uint256 value) external {
        quotePerBaseX18 = value;
    }

    function getQuote(uint256 baseAmount, address, address) external view returns (uint256 quoteAmount) {
        quoteAmount = (baseAmount * quotePerBaseX18) / 1e18;
    }
}

contract TWAMMRecoverableLiquidationsTest is BaseOrdersTest {
    address internal borrower = makeAddr("borrower");
    address internal recipient = makeAddr("recipient");

    MockQuoter internal quoter;
    TWAMMRecoverableLiquidations internal liquidations;
    uint64 internal poolFee;

    function setUp() public override {
        BaseOrdersTest.setUp();

        poolFee = uint64((uint256(1) << 64) / 100); // 1%

        PoolKey memory poolKey = createTwammPool(poolFee, 0);
        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e24, 1e24);

        quoter = new MockQuoter();
        liquidations = new TWAMMRecoverableLiquidations({
            owner: address(this),
            orders: orders,
            quoter: quoter,
            collateralToken: address(token0),
            debtToken: address(token1),
            poolFee: poolFee,
            liquidationDuration: 3600,
            collateralFactorBps: 9000,
            triggerHealthFactorX18: 1.2e18,
            cancelHealthFactorX18: 1.5e18
        });

        liquidations.approveMaxCollateral();

        token0.transfer(address(liquidations), 5e18);
        liquidations.updateBorrowerState(borrower, 5e18, 4e18);
        quoter.setQuotePerBaseX18(1e18);
    }

    function test_triggerLiquidation_whenBelowTriggerThreshold() public {
        (uint256 nftId, uint64 endTime, uint112 saleRate) =
            liquidations.triggerLiquidation(borrower, 2e18, type(uint112).max);

        ITWAMMRecoverableLiquidations.BorrowerState memory state = liquidations.getBorrowerState(borrower);

        assertTrue(state.active);
        assertEq(state.nftId, nftId);
        assertEq(state.activeOrderEndTime, endTime);
        assertGt(endTime, block.timestamp);
        assertGt(saleRate, 0);
    }

    function test_triggerLiquidation_revertsWhenHealthy() public {
        quoter.setQuotePerBaseX18(2e18);
        uint256 healthFactor = liquidations.healthFactorX18(borrower);

        vm.expectRevert(abi.encodeWithSelector(ITWAMMRecoverableLiquidations.AccountHealthy.selector, healthFactor));
        liquidations.triggerLiquidation(borrower, 2e18, type(uint112).max);
    }

    function test_cancelLiquidationIfRecovered() public {
        liquidations.triggerLiquidation(borrower, 2e18, type(uint112).max);

        advanceTime(1800);
        quoter.setQuotePerBaseX18(2e18);

        uint256 token0Before = token0.balanceOf(recipient);
        uint256 token1Before = token1.balanceOf(recipient);

        (uint128 refund, uint128 proceeds) = liquidations.cancelLiquidationIfRecovered(borrower, recipient, recipient);

        ITWAMMRecoverableLiquidations.BorrowerState memory state = liquidations.getBorrowerState(borrower);

        assertFalse(state.active);
        assertEq(state.activeOrderEndTime, 0);
        assertGt(refund, 0);
        assertGt(proceeds, 0);
        assertEq(token0.balanceOf(recipient), token0Before + refund);
        assertEq(token1.balanceOf(recipient), token1Before + proceeds);
    }
}
