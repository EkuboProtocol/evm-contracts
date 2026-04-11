// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseOrdersTest} from "./Orders.t.sol";
import {MoneyMarket} from "../src/MoneyMarket.sol";
import {IMoneyMarket} from "../src/interfaces/IMoneyMarket.sol";
import {IOracle} from "../src/interfaces/extensions/IOracle.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";

contract MockOracle {
    mapping(address token => int32 tick) public ticks;

    function setTick(address token, int32 value) external {
        ticks[token] = value;
    }

    function extrapolateSnapshot(address token, uint256 atTime)
        external
        view
        returns (uint160 secondsPerLiquidityCumulative, int64 tickCumulative)
    {
        secondsPerLiquidityCumulative = uint160(atTime << 64);
        tickCumulative = int64(ticks[token]) * int64(uint64(atTime));
    }
}

contract MoneyMarketTest is BaseOrdersTest {
    address internal borrower = makeAddr("borrower");

    MockOracle internal oracle;
    MoneyMarket internal lending;

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

        lending = new MoneyMarket({owner: address(this), core: core, twamm: twamm, oracle: IOracle(address(oracle))});

        lending.configureMarket({
            tokenA: address(token0),
            tokenB: address(token1),
            poolFee: feeA,
            ltvX32: uint32((uint256(type(uint32).max) * 9) / 10),
            twapDuration: 300,
            liquidationDuration: 3600,
            minLiquidityMagnitude: 0
        });
        lending.configureMarket({
            tokenA: address(token0),
            tokenB: address(token1),
            poolFee: feeB,
            ltvX32: uint32((uint256(type(uint32).max) * 8) / 10),
            twapDuration: 300,
            liquidationDuration: 3600,
            minLiquidityMagnitude: 0
        });

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

        IMoneyMarket.BorrowerState memory stateA =
            lending.getBorrowerState(address(this), address(token0), address(token1), feeA);
        IMoneyMarket.BorrowerState memory stateB =
            lending.getBorrowerState(address(this), address(token0), address(token1), feeB);

        assertEq(stateA.collateralAmount, 5e18);
        assertEq(stateA.debtAmount, 2e18);
        assertEq(stateA.activeOrderEndTime, 0);
        assertEq(stateA.liquidationAmount, 0);
        assertEq(stateB.collateralAmount, 5e18);
        assertEq(stateB.debtAmount, 2e18);
    }

    function test_triggerLiquidation_whenBelowHealthThreshold() public {
        _depositAndBorrow(feeA, 5e18, 44e17);
        oracle.setTick(address(token0), 50_000);
        oracle.setTick(address(token1), 0);
        advanceTime(300);

        (bytes32 orderSalt, uint64 endTime, uint112 saleRate) =
            lending.triggerLiquidation(address(this), address(token0), address(token1), feeA, 2e18, type(uint112).max);

        IMoneyMarket.BorrowerState memory state =
            lending.getBorrowerState(address(this), address(token0), address(token1), feeA);

        assertGt(uint256(orderSalt), 0);
        assertEq(state.activeOrderEndTime, endTime);
        assertEq(state.liquidationAmount, 2e18);
        assertGt(endTime, block.timestamp);
        assertGt(saleRate, 0);
    }

    function test_cancelLiquidationIfRecovered() public {
        _depositAndBorrow(feeA, 5e18, 44e17);
        oracle.setTick(address(token0), 50_000);
        oracle.setTick(address(token1), 0);
        advanceTime(300);
        lending.triggerLiquidation(address(this), address(token0), address(token1), feeA, 2e18, type(uint112).max);

        advanceTime(1800);
        oracle.setTick(address(token0), 0);
        oracle.setTick(address(token1), 0);

        (uint128 refund, uint128 proceeds) =
            lending.cancelLiquidationIfRecovered(address(this), address(token0), address(token1), feeA);

        IMoneyMarket.BorrowerState memory state =
            lending.getBorrowerState(address(this), address(token0), address(token1), feeA);
        assertEq(state.activeOrderEndTime, 0);
        assertEq(state.liquidationAmount, 0);
        assertGt(refund, 0);
        assertLe(proceeds, 2e18);
    }

    function test_marketConfigAccessibleFromEitherTokenOrder() public view {
        IMoneyMarket.MarketConfig memory a = lending.getMarketConfig(address(token0), address(token1), feeA);
        IMoneyMarket.MarketConfig memory b = lending.getMarketConfig(address(token1), address(token0), feeA);

        assertEq(a.ltvX32, b.ltvX32);
        assertEq(a.twapDuration, b.twapDuration);
        assertEq(a.liquidationDuration, b.liquidationDuration);
        assertEq(a.minLiquidityMagnitude, b.minLiquidityMagnitude);
    }
}
