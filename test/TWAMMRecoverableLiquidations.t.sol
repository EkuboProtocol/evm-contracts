// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseOrdersTest} from "./Orders.t.sol";
import {TWAMMRecoverableLiquidations} from "../src/TWAMMRecoverableLiquidations.sol";
import {ITWAMMRecoverableLiquidations} from "../src/interfaces/ITWAMMRecoverableLiquidations.sol";
import {IOracle} from "../src/interfaces/extensions/IOracle.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";

contract MockOracle {
    mapping(address token => int32 tick) public ticks;

    function setTick(address token, int32 value) external {
        ticks[token] = value;
    }

    function extrapolateSnapshot(address token, uint256 atTime) external view returns (uint160, int64 tickCumulative) {
        tickCumulative = int64(ticks[token]) * int64(uint64(atTime));
    }
}

contract TWAMMRecoverableLiquidationsTest is BaseOrdersTest {
    address internal borrower = makeAddr("borrower");
    address internal recipient = makeAddr("recipient");

    MockOracle internal oracle;
    TWAMMRecoverableLiquidations internal lending;

    uint64 internal feeA;
    uint64 internal feeB;

    function setUp() public override {
        BaseOrdersTest.setUp();

        feeA = uint64((uint256(1) << 64) / 100); // 1%
        feeB = uint64((uint256(2) << 64) / 100); // 2%

        PoolKey memory poolA = createTwammPool(feeA, 0);
        PoolKey memory poolB = createTwammPool(feeB, 0);
        createPosition(poolA, MIN_TICK, MAX_TICK, 1e24, 1e24);
        createPosition(poolB, MIN_TICK, MAX_TICK, 1e24, 1e24);

        oracle = new MockOracle();
        oracle.setTick(address(token0), 0);
        oracle.setTick(address(token1), 0);

        lending = new TWAMMRecoverableLiquidations({
            owner: address(this),
            core: core,
            twamm: twamm,
            oracle: IOracle(address(oracle)),
            liquidationDuration: 3600,
            twapDuration: 300
        });

        lending.configurePair(address(token0), address(token1), feeA, 9000, 1.1e18, 1.12e18);
        lending.configurePair(address(token0), address(token1), feeB, 8000, 1.1e18, 1.4e18);

        token1.transfer(address(lending), 20e18);
    }

    function _depositAndBorrow(uint64 fee, uint128 collateral, uint128 debt) internal {
        token0.approve(address(lending), collateral);
        lending.depositCollateral(address(token0), address(token1), fee, collateral);
        lending.borrow(address(token0), address(token1), fee, debt, borrower);
    }

    function test_singletonSupportsMultiplePairs() public {
        _depositAndBorrow(feeA, 5e18, 2e18);
        _depositAndBorrow(feeB, 5e18, 2e18);

        ITWAMMRecoverableLiquidations.BorrowerState memory stateA =
            lending.getBorrowerState(address(this), address(token0), address(token1), feeA);
        ITWAMMRecoverableLiquidations.BorrowerState memory stateB =
            lending.getBorrowerState(address(this), address(token0), address(token1), feeB);

        assertEq(stateA.collateralAmount, 5e18);
        assertEq(stateA.debtAmount, 2e18);
        assertEq(stateB.collateralAmount, 5e18);
        assertEq(stateB.debtAmount, 2e18);
    }

    function test_triggerLiquidation_whenBelowTriggerThreshold() public {
        _depositAndBorrow(feeA, 5e18, 4e18);
        oracle.setTick(address(token0), 25_000); // widen relative tick to push health below trigger
        oracle.setTick(address(token1), 0);

        (bytes32 orderSalt, uint64 endTime, uint112 saleRate) =
            lending.triggerLiquidation(address(this), address(token0), address(token1), feeA, 2e18, type(uint112).max);

        ITWAMMRecoverableLiquidations.BorrowerState memory state =
            lending.getBorrowerState(address(this), address(token0), address(token1), feeA);

        assertTrue(state.active);
        assertGt(uint256(orderSalt), 0);
        assertEq(state.activeOrderEndTime, endTime);
        assertGt(endTime, block.timestamp);
        assertGt(saleRate, 0);
    }

    function test_cancelLiquidationIfRecovered() public {
        _depositAndBorrow(feeA, 5e18, 4e18);
        oracle.setTick(address(token0), 25_000);
        oracle.setTick(address(token1), 0);
        lending.triggerLiquidation(address(this), address(token0), address(token1), feeA, 2e18, type(uint112).max);

        advanceTime(1800);
        oracle.setTick(address(token0), 0);
        oracle.setTick(address(token1), 0);

        (uint128 refund, uint128 proceeds) =
            lending.cancelLiquidationIfRecovered(address(this), address(token0), address(token1), feeA);

        ITWAMMRecoverableLiquidations.BorrowerState memory state =
            lending.getBorrowerState(address(this), address(token0), address(token1), feeA);
        assertFalse(state.active);
        assertEq(state.activeOrderEndTime, 0);
        assertGt(refund, 0);
        // Proceeds from a cancellable liquidation cannot exceed the configured sell amount (2e18).
        assertLe(proceeds, 2e18);
    }
}
