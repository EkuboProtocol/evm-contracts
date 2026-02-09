// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseOrdersTest} from "./Orders.t.sol";
import {Auctions} from "../src/Auctions.sol";
import {AuctionConfig, createAuctionConfig} from "../src/types/auctionConfig.sol";
import {AuctionKey} from "../src/types/auctionKey.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING} from "../src/math/constants.sol";
import {nextValidTime, MAX_ABS_VALUE_SALE_RATE_DELTA} from "../src/math/time.sol";
import {computeSaleRate} from "../src/math/twamm.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {BaseNonfungibleToken} from "../src/base/BaseNonfungibleToken.sol";
import {boostedFeesCallPoints} from "../src/extensions/BoostedFees.sol";
import {Vm} from "forge-std/Vm.sol";

contract AuctionsTest is BaseOrdersTest {
    using CoreLib for *;

    Auctions auctions;

    function setUp() public virtual override {
        BaseOrdersTest.setUp();
        address boostedFees = address((uint160(boostedFeesCallPoints(true).toUint8()) << 152) + 1);
        deployCodeTo("BoostedFees.sol", abi.encode(core, true), boostedFees);
        auctions = new Auctions(address(this), core, twamm, boostedFees);
    }

    function test_create_auction_gas() public {
        uint64 startTime = uint64(nextValidTime(vm.getBlockTimestamp(), vm.getBlockTimestamp()));
        uint64 endTime = uint64(nextValidTime(vm.getBlockTimestamp(), startTime + 3600 - 1));
        uint32 duration = uint32(endTime - startTime);
        uint128 totalAmountSold = 69_420e18;
        AuctionConfig config = createAuctionConfig({
            _creatorFee: 0,
            _isSellingToken1: true,
            _minBoostDuration: 1 days,
            _graduationPoolFee: uint64((uint256(1) << 64) / 100),
            _graduationPoolTickSpacing: 1000,
            _startTime: startTime,
            _auctionDuration: duration
        });
        AuctionKey memory auctionKey = AuctionKey({token0: address(token0), token1: address(token1), config: config});

        uint256 tokenId = auctions.mint();

        token1.approve(address(auctions), totalAmountSold);
        auctions.sellByAuction(tokenId, auctionKey, totalAmountSold);
        vm.snapshotGasLastCall("Auctions#sellByAuction");
    }

    function test_collectCreatorProceeds_authorized_withAmount_andCollectAll() public {
        (uint256 tokenId, AuctionKey memory auctionKey, uint128 creatorAmount) =
            _createAuctionAndComplete({isSellingToken1_: true, amount: 1e18});

        address recipientA = makeAddr("recipientA");
        address approvedCollector = makeAddr("approvedCollector");
        uint128 partialAmount = creatorAmount / 2;

        uint256 recipientABefore = token0.balanceOf(recipientA);
        auctions.collectCreatorProceeds(tokenId, auctionKey, recipientA, partialAmount);
        assertEq(token0.balanceOf(recipientA), recipientABefore + partialAmount, "recipient A received partial");

        auctions.approve(approvedCollector, tokenId);
        uint128 approvedAmount = (creatorAmount - partialAmount) / 2;

        uint256 approvedBefore = token0.balanceOf(approvedCollector);
        vm.prank(approvedCollector);
        auctions.collectCreatorProceeds(tokenId, auctionKey, approvedAmount);
        assertEq(token0.balanceOf(approvedCollector), approvedBefore + approvedAmount, "approved recipient received");

        uint256 thisBefore = token0.balanceOf(address(this));
        auctions.collectCreatorProceeds(tokenId, auctionKey);
        uint128 collectedRest = creatorAmount - partialAmount - approvedAmount;
        assertEq(token0.balanceOf(address(this)), thisBefore + collectedRest, "owner received remaining");

        (uint128 saved0, uint128 saved1) =
            core.savedBalances(address(auctions), auctionKey.token0, auctionKey.token1, bytes32(tokenId));
        assertEq(saved0, 0, "saved0 cleared");
        assertEq(saved1, 0, "saved1 cleared");
    }

    function test_collectCreatorProceeds_reverts_ifCallerIsNotAuthorized() public {
        (uint256 tokenId, AuctionKey memory auctionKey,) =
            _createAuctionAndComplete({isSellingToken1_: true, amount: 1e18});

        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(BaseNonfungibleToken.NotUnauthorizedForToken.selector, attacker, tokenId)
        );
        auctions.collectCreatorProceeds(tokenId, auctionKey, 1);
    }

    function test_sellByAuction_reverts_ifCallerIsNotAuthorized() public {
        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(nextValidTime(vm.getBlockTimestamp(), startTime + 3600 - 1));
        uint32 duration = uint32(endTime - startTime);
        AuctionKey memory auctionKey = _buildAuctionKey({
            isSellingToken1_: true, startTime: startTime, duration: duration, creatorFee: type(uint32).max
        });

        uint256 tokenId = auctions.mint();
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(BaseNonfungibleToken.NotUnauthorizedForToken.selector, attacker, tokenId)
        );
        auctions.sellByAuction(tokenId, auctionKey, 1e18);
    }

    function test_sellByAuction_reverts_ifAuctionAlreadyStarted() public {
        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(nextValidTime(vm.getBlockTimestamp(), startTime + 3600 - 1));
        uint32 duration = uint32(endTime - startTime);
        AuctionKey memory auctionKey = _buildAuctionKey({
            isSellingToken1_: true, startTime: startTime, duration: duration, creatorFee: type(uint32).max
        });

        uint256 tokenId = auctions.mint();
        token1.approve(address(auctions), 1e18);

        vm.warp(startTime + 1);
        vm.expectRevert(Auctions.AuctionAlreadyStarted.selector);
        auctions.sellByAuction(tokenId, auctionKey, 1e18);
    }

    function test_sellByAuction_reverts_ifSaleRateDeltaIsZero() public {
        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(nextValidTime(vm.getBlockTimestamp(), startTime + 3600 - 1));
        uint32 duration = uint32(endTime - startTime);
        AuctionKey memory auctionKey = _buildAuctionKey({
            isSellingToken1_: true, startTime: startTime, duration: duration, creatorFee: type(uint32).max
        });

        uint256 tokenId = auctions.mint();
        vm.expectRevert(Auctions.ZeroSaleRateDelta.selector);
        auctions.sellByAuction(tokenId, auctionKey, 0);
    }

    function test_sellByAuction_reverts_ifGraduationPoolTickSpacingIsZero() public {
        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(nextValidTime(vm.getBlockTimestamp(), startTime + 3600 - 1));
        uint32 duration = uint32(endTime - startTime);
        AuctionConfig config = createAuctionConfig({
            _creatorFee: type(uint32).max,
            _isSellingToken1: true,
            _minBoostDuration: 1 days,
            _graduationPoolFee: uint64((uint256(1) << 64) / 100),
            _graduationPoolTickSpacing: 0,
            _startTime: startTime,
            _auctionDuration: duration
        });
        AuctionKey memory auctionKey = AuctionKey({token0: address(token0), token1: address(token1), config: config});

        uint256 tokenId = auctions.mint();
        token1.approve(address(auctions), 1e18);
        vm.expectRevert(Auctions.InvalidGraduationPoolTickSpacing.selector);
        auctions.sellByAuction(tokenId, auctionKey, 1e18);
    }

    function test_sellByAuction_reverts_ifGraduationPoolTickSpacingTooLarge() public {
        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(nextValidTime(vm.getBlockTimestamp(), startTime + 3600 - 1));
        uint32 duration = uint32(endTime - startTime);
        AuctionConfig config = createAuctionConfig({
            _creatorFee: type(uint32).max,
            _isSellingToken1: true,
            _minBoostDuration: 1 days,
            _graduationPoolFee: uint64((uint256(1) << 64) / 100),
            _graduationPoolTickSpacing: MAX_TICK_SPACING + 1,
            _startTime: startTime,
            _auctionDuration: duration
        });
        AuctionKey memory auctionKey = AuctionKey({token0: address(token0), token1: address(token1), config: config});

        uint256 tokenId = auctions.mint();
        token1.approve(address(auctions), 1e18);
        vm.expectRevert(Auctions.InvalidGraduationPoolTickSpacing.selector);
        auctions.sellByAuction(tokenId, auctionKey, 1e18);
    }

    function test_sellByAuction_reverts_ifMinBoostDurationTooLarge() public {
        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(nextValidTime(vm.getBlockTimestamp(), startTime + 3600 - 1));
        uint32 duration = uint32(endTime - startTime);
        AuctionConfig config = createAuctionConfig({
            _creatorFee: type(uint32).max,
            _isSellingToken1: true,
            _minBoostDuration: uint24(180 days) + 1,
            _graduationPoolFee: uint64((uint256(1) << 64) / 100),
            _graduationPoolTickSpacing: 1000,
            _startTime: startTime,
            _auctionDuration: duration
        });
        AuctionKey memory auctionKey = AuctionKey({token0: address(token0), token1: address(token1), config: config});

        uint256 tokenId = auctions.mint();
        token1.approve(address(auctions), 1e18);
        vm.expectRevert(Auctions.MinBoostDurationTooLarge.selector);
        auctions.sellByAuction(tokenId, auctionKey, 1e18);
    }

    function test_completeAuction_reverts_ifAuctionNotEnded() public {
        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(nextValidTime(vm.getBlockTimestamp(), startTime + 3600 - 1));
        uint32 duration = uint32(endTime - startTime);
        AuctionKey memory auctionKey = _buildAuctionKey({
            isSellingToken1_: true, startTime: startTime, duration: duration, creatorFee: type(uint32).max
        });
        PoolKey memory launchPool = auctionKey.toLaunchPoolKey(address(twamm));
        core.initializePool(launchPool, 0);
        core.initializePool(auctionKey.toGraduationPoolKey(auctions.BOOSTED_FEES()), 0);
        createPosition(launchPool, MIN_TICK, MAX_TICK, 10_000e18, 10_000e18);

        uint256 tokenId = auctions.mint();
        token1.approve(address(auctions), 1e18);
        auctions.sellByAuction(tokenId, auctionKey, 1e18);

        vm.expectRevert(Auctions.CannotCompleteAuctionBeforeEndOfAuction.selector);
        auctions.completeAuction(tokenId, auctionKey);
    }

    function test_completeAuction_reverts_ifNoProceeds() public {
        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(nextValidTime(vm.getBlockTimestamp(), startTime + 3600 - 1));
        uint32 duration = uint32(endTime - startTime);
        AuctionKey memory auctionKey = _buildAuctionKey({
            isSellingToken1_: true, startTime: startTime, duration: duration, creatorFee: type(uint32).max
        });

        uint256 tokenId = auctions.mint();
        token1.approve(address(auctions), 1e18);
        auctions.sellByAuction(tokenId, auctionKey, 1e18);

        advanceTime(duration);
        vm.expectRevert(Auctions.NoProceedsToCompleteAuction.selector);
        auctions.completeAuction(tokenId, auctionKey);
    }

    function test_completeAuction_isPermissionless() public {
        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(nextValidTime(vm.getBlockTimestamp(), startTime + 3600 - 1));
        uint32 duration = uint32(endTime - startTime);
        AuctionKey memory auctionKey = _buildAuctionKey({
            isSellingToken1_: true, startTime: startTime, duration: duration, creatorFee: type(uint32).max
        });
        PoolKey memory launchPool = auctionKey.toLaunchPoolKey(address(twamm));
        core.initializePool(launchPool, 0);
        core.initializePool(auctionKey.toGraduationPoolKey(auctions.BOOSTED_FEES()), 0);
        createPosition(launchPool, MIN_TICK, MAX_TICK, 10_000e18, 10_000e18);

        uint256 tokenId = auctions.mint();
        token1.approve(address(auctions), 1e18);
        auctions.sellByAuction(tokenId, auctionKey, 1e18);

        advanceTime(duration);

        address completer = makeAddr("completer");
        vm.prank(completer);
        (uint128 creatorAmount, uint112 boostRate, uint64 boostEndTime) = auctions.completeAuction(tokenId, auctionKey);
        assertGt(creatorAmount, 0, "creatorAmount");
        assertGt(boostRate, 0, "boostRate");
        assertGt(boostEndTime, 0, "boostEndTime");
    }

    function test_completeAuction_capsBoostRate_andRedirectsOverflowToCreator_whenMinBoostDurationIsZero() public {
        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(nextValidTime(vm.getBlockTimestamp(), startTime + 3600 - 1));
        uint32 duration = uint32(endTime - startTime);

        AuctionConfig config = createAuctionConfig({
            _creatorFee: 0,
            _isSellingToken1: true,
            _minBoostDuration: 0,
            _graduationPoolFee: uint64((uint256(1) << 64) / 100),
            _graduationPoolTickSpacing: 1000,
            _startTime: startTime,
            _auctionDuration: duration
        });
        AuctionKey memory auctionKey = AuctionKey({token0: address(token0), token1: address(token1), config: config});
        PoolKey memory launchPool = auctionKey.toLaunchPoolKey(address(twamm));
        core.initializePool(launchPool, 0);
        core.initializePool(auctionKey.toGraduationPoolKey(auctions.BOOSTED_FEES()), 0);
        createPosition(
            launchPool,
            MIN_TICK,
            MAX_TICK,
            1_000_000_000_000_000_000_000_000_000_000,
            1_000_000_000_000_000_000_000_000_000_000
        );

        uint128 totalAmountSold = 20_000_000_000_000_000_000_000_000;
        uint256 tokenId = auctions.mint();
        token1.approve(address(auctions), totalAmountSold);
        auctions.sellByAuction(tokenId, auctionKey, totalAmountSold);

        advanceTime(duration);
        (uint128 creatorAmount, uint112 boostRate, uint64 boostEndTime) = auctions.completeAuction(tokenId, auctionKey);

        assertEq(boostRate, MAX_ABS_VALUE_SALE_RATE_DELTA, "boost rate capped");
        assertGt(boostEndTime, 0, "boost end time set");
        assertGt(creatorAmount, 0, "creator gets overflow");

        (uint128 saved0, uint128 saved1) =
            core.savedBalances(address(auctions), auctionKey.token0, auctionKey.token1, bytes32(tokenId));
        assertEq(saved0, creatorAmount, "creator overflow saved");
        assertEq(saved1, 0, "saved1 empty");
    }

    function test_collectCreatorProceeds_recipientOverload_collectsAll() public {
        (uint256 tokenId, AuctionKey memory auctionKey, uint128 creatorAmount) =
            _createAuctionAndComplete({isSellingToken1_: true, amount: 1e18});

        address recipient = makeAddr("recipient");
        uint256 recipientBefore = token0.balanceOf(recipient);
        auctions.collectCreatorProceeds(tokenId, auctionKey, recipient);
        assertEq(token0.balanceOf(recipient), recipientBefore + creatorAmount, "recipient received all");

        (uint128 saved0, uint128 saved1) =
            core.savedBalances(address(auctions), auctionKey.token0, auctionKey.token1, bytes32(tokenId));
        assertEq(saved0, 0, "saved0 cleared");
        assertEq(saved1, 0, "saved1 cleared");
    }

    function test_collectCreatorProceeds_zeroAmount_isNoop() public {
        (uint256 tokenId, AuctionKey memory auctionKey,) =
            _createAuctionAndComplete({isSellingToken1_: true, amount: 1e18});

        (uint128 saved0Before, uint128 saved1Before) =
            core.savedBalances(address(auctions), auctionKey.token0, auctionKey.token1, bytes32(tokenId));
        uint256 recipientBefore = token0.balanceOf(address(this));

        auctions.collectCreatorProceeds(tokenId, auctionKey, address(this), 0);

        (uint128 saved0After, uint128 saved1After) =
            core.savedBalances(address(auctions), auctionKey.token0, auctionKey.token1, bytes32(tokenId));
        assertEq(saved0After, saved0Before, "saved0 unchanged");
        assertEq(saved1After, saved1Before, "saved1 unchanged");
        assertEq(token0.balanceOf(address(this)), recipientBefore, "recipient unchanged");
    }

    function test_collectCreatorProceeds_zeroAmount_emitsNoAuctionEvent() public {
        (uint256 tokenId, AuctionKey memory auctionKey,) =
            _createAuctionAndComplete({isSellingToken1_: true, amount: 1e18});

        vm.recordLogs();
        auctions.collectCreatorProceeds(tokenId, auctionKey, address(this), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 auctionsLogs;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(auctions)) auctionsLogs++;
        }
        assertEq(auctionsLogs, 0, "no auctions events for zero-amount collect");
    }

    function testFuzz_completeAuction_succeedsWhenProceedsExist(
        bool isSellingToken1_,
        uint32 durationSeed,
        uint128 amountSeed,
        uint32 creatorFeeSeed
    ) public {
        uint64 startTime = alignToNextValidTime();
        uint32 requestedDuration = uint32(bound(uint256(durationSeed), 60, 2 days));
        uint64 endTime = uint64(nextValidTime(vm.getBlockTimestamp(), startTime + requestedDuration - 1));
        uint32 duration = uint32(endTime - startTime);

        AuctionKey memory auctionKey = _buildAuctionKey({
            isSellingToken1_: isSellingToken1_, startTime: startTime, duration: duration, creatorFee: creatorFeeSeed
        });
        PoolKey memory launchPool = auctionKey.toLaunchPoolKey(address(twamm));
        core.initializePool(launchPool, 0);
        core.initializePool(auctionKey.toGraduationPoolKey(auctions.BOOSTED_FEES()), 0);
        createPosition(launchPool, MIN_TICK, MAX_TICK, 1_000_000e18, 1_000_000e18);

        uint128 amount = uint128(bound(uint256(amountSeed), uint256(duration), 1_000_000e18));
        uint256 tokenId = auctions.mint();
        if (isSellingToken1_) {
            token1.approve(address(auctions), amount);
        } else {
            token0.approve(address(auctions), amount);
        }
        auctions.sellByAuction(tokenId, auctionKey, amount);

        advanceTime(duration);
        (,,, uint128 purchasedAmount) = auctions.executeVirtualOrdersAndGetSaleStatus(tokenId, auctionKey);
        vm.assume(purchasedAmount > 0);

        (uint128 creatorAmount, uint112 boostRate, uint64 boostEndTime) = auctions.completeAuction(tokenId, auctionKey);
        assertLe(creatorAmount, purchasedAmount, "creator amount bounded by proceeds");
        assertLe(boostRate, MAX_ABS_VALUE_SALE_RATE_DELTA, "boost rate capped");
        if (boostRate > 0) {
            assertGt(boostEndTime, uint64(block.timestamp), "boostEndTime set when boost exists");
        } else {
            assertEq(boostEndTime, 0, "boostEndTime is zero when boost is zero");
        }

        (uint128 saved0, uint128 saved1) =
            core.savedBalances(address(auctions), auctionKey.token0, auctionKey.token1, bytes32(tokenId));
        if (isSellingToken1_) {
            assertEq(saved0, creatorAmount, "saved0 creator balance");
            assertEq(saved1, 0, "saved1 empty");
        } else {
            assertEq(saved0, 0, "saved0 empty");
            assertEq(saved1, creatorAmount, "saved1 creator balance");
        }
    }

    function testFuzz_collectCreatorProceeds_partialThenAll(bool isSellingToken1_, uint128 amountSeed, uint96 splitSeed)
        public
    {
        uint128 amount = uint128(bound(uint256(amountSeed), 1e18, 100_000e18));
        (uint256 tokenId, AuctionKey memory auctionKey, uint128 creatorAmount) =
            _createAuctionAndComplete({isSellingToken1_: isSellingToken1_, amount: amount});

        uint256 splitBps = bound(uint256(splitSeed), 0, 1_000_000);
        uint128 partialAmount = uint128((uint256(creatorAmount) * splitBps) / 1_000_000);

        address recipientA = makeAddr("recipientA_fuzz");
        address recipientB = makeAddr("recipientB_fuzz");
        address buyToken = auctionKey.buyToken();
        uint256 recipientABefore = _balanceOf(buyToken, recipientA);
        uint256 recipientBBefore = _balanceOf(buyToken, recipientB);

        auctions.collectCreatorProceeds(tokenId, auctionKey, recipientA, partialAmount);
        auctions.collectCreatorProceeds(tokenId, auctionKey, recipientB);

        assertEq(_balanceOf(buyToken, recipientA), recipientABefore + partialAmount, "recipientA received partial");
        assertEq(
            _balanceOf(buyToken, recipientB),
            recipientBBefore + (creatorAmount - partialAmount),
            "recipientB received remainder"
        );

        (uint128 saved0, uint128 saved1) =
            core.savedBalances(address(auctions), auctionKey.token0, auctionKey.token1, bytes32(tokenId));
        assertEq(saved0, 0, "saved0 cleared");
        assertEq(saved1, 0, "saved1 cleared");
    }

    function test_emitsEvents_create_complete_collect() public {
        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(nextValidTime(vm.getBlockTimestamp(), startTime + 3600 - 1));
        uint32 duration = uint32(endTime - startTime);
        uint128 totalAmountSold = 1e18;
        AuctionConfig config = createAuctionConfig({
            _creatorFee: type(uint32).max,
            _isSellingToken1: true,
            _minBoostDuration: 1 days,
            _graduationPoolFee: uint64((uint256(1) << 64) / 100),
            _graduationPoolTickSpacing: 1000,
            _startTime: startTime,
            _auctionDuration: duration
        });
        AuctionKey memory auctionKey = AuctionKey({token0: address(token0), token1: address(token1), config: config});
        PoolKey memory launchPool = auctionKey.toLaunchPoolKey(address(twamm));
        core.initializePool(launchPool, 0);
        core.initializePool(auctionKey.toGraduationPoolKey(auctions.BOOSTED_FEES()), 0);
        createPosition(launchPool, MIN_TICK, MAX_TICK, 10_000e18, 10_000e18);

        uint256 tokenId = auctions.mint();
        token1.approve(address(auctions), totalAmountSold);

        uint112 saleRate = uint112(computeSaleRate(totalAmountSold, duration));
        vm.expectEmit(false, false, false, true, address(auctions));
        emit Auctions.AuctionFundsAdded(tokenId, auctionKey, saleRate);
        auctions.sellByAuction(tokenId, auctionKey, totalAmountSold);

        advanceTime(duration);

        vm.expectEmit(false, false, false, false, address(auctions));
        emit Auctions.AuctionCompleted(tokenId, auctionKey, 0, 0, 0);
        auctions.completeAuction(tokenId, auctionKey);

        (uint128 saved0,) =
            core.savedBalances(address(auctions), auctionKey.token0, auctionKey.token1, bytes32(tokenId));

        vm.expectEmit(false, false, false, true, address(auctions));
        emit Auctions.CreatorProceedsCollected(tokenId, auctionKey, address(this), saved0);
        auctions.collectCreatorProceeds(tokenId, auctionKey);
    }

    function _buildAuctionKey(bool isSellingToken1_, uint64 startTime, uint32 duration, uint32 creatorFee)
        internal
        view
        returns (AuctionKey memory auctionKey)
    {
        AuctionConfig config = createAuctionConfig({
            _creatorFee: creatorFee,
            _isSellingToken1: isSellingToken1_,
            _minBoostDuration: 1 days,
            _graduationPoolFee: uint64((uint256(1) << 64) / 100),
            _graduationPoolTickSpacing: 1000,
            _startTime: startTime,
            _auctionDuration: duration
        });
        auctionKey = AuctionKey({token0: address(token0), token1: address(token1), config: config});
    }

    function _createAuctionAndComplete(bool isSellingToken1_, uint128 amount)
        internal
        returns (uint256 tokenId, AuctionKey memory auctionKey, uint128 creatorAmount)
    {
        uint64 startTime = alignToNextValidTime();
        uint64 endTime = uint64(nextValidTime(vm.getBlockTimestamp(), startTime + 3600 - 1));
        uint32 duration = uint32(endTime - startTime);
        AuctionConfig config = createAuctionConfig({
            _creatorFee: type(uint32).max,
            _isSellingToken1: isSellingToken1_,
            _minBoostDuration: 1 days,
            _graduationPoolFee: uint64((uint256(1) << 64) / 100),
            _graduationPoolTickSpacing: 1000,
            _startTime: startTime,
            _auctionDuration: duration
        });
        auctionKey = AuctionKey({token0: address(token0), token1: address(token1), config: config});
        PoolKey memory launchPool = auctionKey.toLaunchPoolKey(address(twamm));
        core.initializePool(launchPool, 0);
        core.initializePool(auctionKey.toGraduationPoolKey(auctions.BOOSTED_FEES()), 0);
        createPosition(launchPool, MIN_TICK, MAX_TICK, 10_000e18, 10_000e18);

        tokenId = auctions.mint();
        if (isSellingToken1_) {
            token1.approve(address(auctions), amount);
        } else {
            token0.approve(address(auctions), amount);
        }
        auctions.sellByAuction(tokenId, auctionKey, amount);

        advanceTime(duration);
        uint112 boostRate;
        uint64 boostEndTime;
        (creatorAmount, boostRate, boostEndTime) = auctions.completeAuction(tokenId, auctionKey);

        assertGt(creatorAmount, 0, "creatorAmount");
        assertGt(boostRate, 0, "boostRate");
        assertGt(boostEndTime, 0, "boostEndTime");
    }

    function _balanceOf(address token, address account) internal view returns (uint256 balance) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", account));
        require(success && data.length >= 32, "balanceOf call failed");
        balance = abi.decode(data, (uint256));
    }
}
