// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseOrdersTest} from "./Orders.t.sol";
import {TWAMMRecoverableLiquidations} from "../src/TWAMMRecoverableLiquidations.sol";
import {ITWAMMRecoverableLiquidations} from "../src/interfaces/ITWAMMRecoverableLiquidations.sol";
import {IOracle} from "../src/interfaces/extensions/IOracle.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";

contract MockOracle {
    int32 public tick;

    function setTick(int32 value) external {
        tick = value;
    }

    function extrapolateSnapshot(address, uint256 atTime) external view returns (uint160, int64 tickCumulative) {
        tickCumulative = int64(tick) * int64(uint64(atTime));
    }
}

contract TWAMMRecoverableLiquidationsTest is BaseOrdersTest {
    address internal borrower = makeAddr("borrower");
    address internal recipient = makeAddr("recipient");

    MockOracle internal oracle;
    TWAMMRecoverableLiquidations internal lending;
    uint64 internal poolFee;

    function setUp() public override {
        BaseOrdersTest.setUp();

        poolFee = uint64((uint256(1) << 64) / 100); // 1%

        PoolKey memory poolKey = createTwammPool(poolFee, 0);
        createPosition(poolKey, MIN_TICK, MAX_TICK, 1e24, 1e24);

        oracle = new MockOracle();
        oracle.setTick(0); // 1:1 pricing

        lending = new TWAMMRecoverableLiquidations({
            owner: address(this),
            orders: orders,
            oracle: IOracle(address(oracle)),
            collateralToken: address(token0),
            debtToken: address(token1),
            poolFee: poolFee,
            liquidationDuration: 3600,
            twapDuration: 300,
            collateralFactorBps: 9000,
            triggerHealthFactorX18: 1.2e18,
            cancelHealthFactorX18: 1.5e18
        });

        lending.approveMaxCollateral();
        token1.transfer(address(lending), 20e18);
    }

    function _depositAndBorrow(uint128 collateral, uint128 debt) internal {
        token0.approve(address(lending), collateral);
        lending.depositCollateral(collateral);
        lending.borrow(debt, borrower);
    }

    function test_userCanDepositCollateralAndBorrowDebt() public {
        _depositAndBorrow(5e18, 2e18);

        ITWAMMRecoverableLiquidations.BorrowerState memory state = lending.getBorrowerState(address(this));
        assertEq(state.collateralAmount, 5e18);
        assertEq(state.debtAmount, 2e18);
        assertEq(token1.balanceOf(borrower), 2e18);
        assertGt(lending.healthFactorX18(address(this)), 1.5e18);
    }

    function test_borrow_revertsWhenLtvExceeded() public {
        token0.approve(address(lending), 5e18);
        lending.depositCollateral(5e18);

        vm.expectRevert(ITWAMMRecoverableLiquidations.AccountStillUnhealthy.selector);
        lending.borrow(3.5e18, borrower);
    }

    function test_repayAndWithdrawCollateral() public {
        _depositAndBorrow(5e18, 2e18);

        token1.approve(address(lending), 1e18);
        lending.repay(1e18);

        lending.withdrawCollateral(1e18, recipient);

        ITWAMMRecoverableLiquidations.BorrowerState memory state = lending.getBorrowerState(address(this));
        assertEq(state.collateralAmount, 4e18);
        assertEq(state.debtAmount, 1e18);
        assertEq(token0.balanceOf(recipient), 1e18);
    }

    function test_triggerLiquidation_whenBelowTriggerThreshold() public {
        _depositAndBorrow(5e18, 4e18);
        oracle.setTick(-2232); // roughly 20% lower collateral value at 1.0001^tick

        (uint256 nftId, uint64 endTime, uint112 saleRate) =
            lending.triggerLiquidation(address(this), 2e18, type(uint112).max);

        ITWAMMRecoverableLiquidations.BorrowerState memory state = lending.getBorrowerState(address(this));

        assertTrue(state.active);
        assertEq(state.nftId, nftId);
        assertEq(state.activeOrderEndTime, endTime);
        assertGt(endTime, block.timestamp);
        assertGt(saleRate, 0);
    }

    function test_cancelLiquidationIfRecovered() public {
        _depositAndBorrow(5e18, 4e18);
        oracle.setTick(-2232);
        lending.triggerLiquidation(address(this), 2e18, type(uint112).max);

        advanceTime(1800);
        oracle.setTick(0);

        (uint128 refund, uint128 proceeds) = lending.cancelLiquidationIfRecovered(address(this));

        ITWAMMRecoverableLiquidations.BorrowerState memory state = lending.getBorrowerState(address(this));
        assertFalse(state.active);
        assertEq(state.activeOrderEndTime, 0);
        assertGt(refund, 0);
        assertGt(proceeds, 0);
    }
}
