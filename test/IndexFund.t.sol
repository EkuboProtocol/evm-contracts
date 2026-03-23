// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseOracleTest} from "./extensions/Oracle.t.sol";
import {IndexFund} from "../src/IndexFund.sol";
import {PriceFetcher} from "../src/lens/PriceFetcher.sol";
import {TWAMM, twammCallPoints} from "../src/extensions/TWAMM.sol";
import {createFullRangePoolConfig} from "../src/types/poolConfig.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract IndexFundTest is BaseOracleTest {
    address internal keeper = makeAddr("keeper");
    address internal subscriber = makeAddr("subscriber");

    TWAMM internal twamm;
    PriceFetcher internal priceFetcher;
    IndexFund internal fund;

    function setUp() public override {
        BaseOracleTest.setUp();

        address twammAddress = address(uint160(twammCallPoints().toUint8()) << 152);
        deployCodeTo("TWAMM.sol", abi.encode(core), twammAddress);
        twamm = TWAMM(twammAddress);

        priceFetcher = new PriceFetcher(oracle);

        createPool(address(token0), address(token1), 0, createFullRangePoolConfig(0, address(twamm)));
        createPosition(
            PoolKey({
                token0: address(token0), token1: address(token1), config: createFullRangePoolConfig(0, address(twamm))
            }),
            MIN_TICK,
            MAX_TICK,
            1_000_000e18,
            1_000_000e18
        );

        createOraclePool(address(token0), 0);
        oracle.expandCapacity(address(token0), 8);
        updateOraclePoolLiquidity(address(token0), 100_000e18);

        createOraclePool(address(token1), 0);
        oracle.expandCapacity(address(token1), 8);
        updateOraclePoolLiquidity(address(token1), 100_000e18);

        IndexFund.ComponentConfig[] memory components = new IndexFund.ComponentConfig[](1);
        components[0] = IndexFund.ComponentConfig({
            token: address(token0), weightX18: 1e18, twammFee: 0, minOracleLiquidity: 1_000
        });

        fund = new IndexFund({
            core: core,
            twamm: twamm,
            priceFetcher: priceFetcher,
            quoteToken: IERC20(address(token1)),
            tokenName_: "Index Fund",
            tokenSymbol_: "INDEX",
            owner_: owner,
            initialSharePrice_: 1e18,
            collectionPeriod_: 300,
            sellOrderDuration_: 256,
            buyOrderDuration_: 256,
            initialComponents: components
        });

        vm.prank(owner);
        fund.setKeeper(keeper, true);

        token1.transfer(subscriber, 2_000e18);
    }

    function test_initialEpoch_opensBuyOrderDirectlyOnTwamm() public {
        vm.startPrank(subscriber);
        token1.approve(address(fund), type(uint256).max);
        fund.queueSubscription(1_000e18, subscriber);
        vm.stopPrank();

        advanceTime(301);

        vm.prank(keeper);
        fund.closeEpoch();

        IndexFund.EpochState memory epoch = fund.getEpochState(fund.currentEpochId());
        assertEq(epoch.totalSubscriptionsQuote, 1_000e18);
        assertEq(epoch.totalMintedShares, 1_000e18);
        assertEq(epoch.sharePriceQuote, 1e18);

        vm.prank(keeper);
        fund.startRebalance();

        epoch = fund.getEpochState(fund.currentEpochId());
        IndexFund.EpochComponentState memory componentState =
            fund.getEpochComponentState(fund.currentEpochId(), address(token0));
        assertEq(uint8(componentState.buyOrderStatus), uint8(IndexFund.OrderStatus.Open));
        assertGt(componentState.openedBuyQuoteAmount, 0);
        assertTrue(componentState.buyOrderSalt != bytes32(0));
        assertGt(epoch.buyStart, 0);
        assertGt(epoch.buyEnd, epoch.buyStart);

        vm.warp(epoch.buyEnd + 1);

        vm.prank(keeper);
        fund.continueRebalance();

        epoch = fund.getEpochState(fund.currentEpochId());
        assertEq(uint8(epoch.rebalanceStage), uint8(IndexFund.RebalanceStage.Ready));

        vm.prank(keeper);
        fund.settleEpoch();

        assertEq(fund.totalSupply(), 1_000e18);
        assertEq(fund.currentEpochId(), 2);

        vm.prank(subscriber);
        fund.claimShares(1, subscriber);

        assertEq(fund.balanceOf(subscriber), 1_000e18);
        assertGt(token0.balanceOf(address(fund)), 0);
    }

    function test_secondEpoch_redemptionOpensSellOrderDirectlyOnTwamm() public {
        test_initialEpoch_opensBuyOrderDirectlyOnTwamm();

        vm.startPrank(subscriber);
        fund.approve(address(fund), type(uint256).max);
        fund.queueRedemption(500e18, subscriber);
        vm.stopPrank();

        advanceTime(301);

        vm.prank(keeper);
        fund.closeEpoch();

        IndexFund.EpochState memory epoch = fund.getEpochState(fund.currentEpochId());
        assertEq(epoch.totalRedemptionShares, 500e18);
        assertGt(epoch.totalRedemptionQuote, 0);

        vm.prank(keeper);
        fund.startRebalance();

        epoch = fund.getEpochState(fund.currentEpochId());
        IndexFund.EpochComponentState memory componentState =
            fund.getEpochComponentState(fund.currentEpochId(), address(token0));
        assertEq(uint8(componentState.sellOrderStatus), uint8(IndexFund.OrderStatus.Open));
        assertGt(componentState.openedSellAmount, 0);
        assertTrue(componentState.sellOrderSalt != bytes32(0));
        assertGt(epoch.sellStart, 0);
        assertGt(epoch.sellEnd, epoch.sellStart);

        vm.warp(epoch.sellEnd + 1);

        vm.prank(keeper);
        fund.continueRebalance();

        epoch = fund.getEpochState(fund.currentEpochId());
        assertEq(uint8(epoch.rebalanceStage), uint8(IndexFund.RebalanceStage.Ready));

        vm.prank(keeper);
        fund.settleEpoch();

        assertEq(fund.totalSupply(), 500e18);

        uint256 quoteBefore = token1.balanceOf(subscriber);
        vm.prank(subscriber);
        fund.claimQuote(2, subscriber);
        uint256 quoteAfter = token1.balanceOf(subscriber);

        assertEq(quoteAfter - quoteBefore, epoch.totalRedemptionQuote);
        assertEq(fund.balanceOf(subscriber), 500e18);
        assertEq(fund.reservedRedemptionQuote(), 0);
    }
}
