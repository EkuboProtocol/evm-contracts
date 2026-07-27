// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {TestToken} from "./TestToken.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Router} from "../src/Router.sol";
import {VeToken} from "../src/VeToken.sol";
import {VeTokenBribe} from "../src/VeTokenBribe.sol";
import {VeTokenMetadata} from "../src/VeTokenMetadata.sol";
import {Ve33, ve33CallPoints} from "../src/extensions/Ve33.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {nextValidTime} from "../src/math/time.sol";
import {createConcentratedPoolConfig} from "../src/types/poolConfig.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {createSwapParameters} from "../src/types/swapParameters.sol";

interface ITokenTransferCallback {
    function onTokenTransfer() external;
}

contract CallbackTestToken is TestToken {
    address private _callback;
    bool private _armed;

    constructor(address recipient) TestToken(recipient) {}

    function arm(address callback) external {
        _callback = callback;
        _armed = true;
    }

    function _afterTokenTransfer(address, address to, uint256) internal override {
        if (!_armed || to != _callback) return;
        _armed = false;
        ITokenTransferCallback(to).onTokenTransfer();
    }
}

contract ReenteringBribeDepositor is ITokenTransferCallback {
    VeTokenBribe private _bribe;
    uint256 private _veId;
    address private _callbackToken;

    bool public reentered;

    function stake(VeTokenBribe bribe, VeToken veToken, uint256 veId) external {
        veToken.approve(address(bribe), veId);
        bribe.stake(veId);
    }

    function refreshWithCallback(VeTokenBribe bribe, uint256 veId, CallbackTestToken callbackToken) external {
        _bribe = bribe;
        _veId = veId;
        _callbackToken = address(callbackToken);
        callbackToken.arm(address(this));
        bribe.refreshVote(veId);
    }

    function onTokenTransfer() external {
        require(msg.sender == _callbackToken);
        reentered = true;
        _bribe.refreshVote(_veId);
    }
}

contract ReenteringFundingToken is TestToken {
    VeTokenBribe private _bribe;
    uint64 private _endTime;
    uint160 private _nestedRate;
    bool private _armed;

    constructor() TestToken(address(this)) {}

    function fundWithReentry(VeTokenBribe bribe, uint64 endTime, uint160 rate, uint160 nestedRate) external {
        _bribe = bribe;
        _endTime = endTime;
        _nestedRate = nestedRate;
        _armed = true;
        _approve(address(this), address(bribe), type(uint256).max);
        bribe.scheduleRewards(0, endTime, rate);
    }

    function _afterTokenTransfer(address from, address to, uint256) internal override {
        if (!_armed || from != address(this) || to != address(_bribe)) return;
        _armed = false;
        _bribe.scheduleRewards(0, _endTime, _nestedRate);
    }
}

contract BlockingTransferToken is TestToken {
    bool public transfersBlocked;

    error TransfersBlocked();

    constructor(address recipient) TestToken(recipient) {}

    function setTransfersBlocked(bool blocked) external {
        transfersBlocked = blocked;
    }

    function _beforeTokenTransfer(address from, address, uint256) internal view override {
        if (transfersBlocked && from != address(0)) revert TransfersBlocked();
    }
}

contract OverriddenFeeVeTokenBribe is VeTokenBribe {
    uint64 private immutable _OVERRIDDEN_FEE;

    constructor(
        VeToken veToken,
        PoolKey memory poolKey,
        address rewardToken,
        address rewardDistributor,
        uint64 overriddenFee
    ) VeTokenBribe(veToken, poolKey, 0, rewardToken, rewardDistributor) {
        _OVERRIDDEN_FEE = overriddenFee;
    }

    function votingFee() public view override returns (uint64) {
        return _OVERRIDDEN_FEE;
    }
}

contract VeTokenBribeTest is FullTest {
    using CoreLib for *;

    uint64 private constant VOTING_FEE = 1 << 62;
    uint64 private constant REWARD_DURATION = 7 days;

    TestToken internal stakeToken;
    TestToken internal rewardToken;
    Ve33 internal ve33;
    VeToken internal veToken;
    VeTokenBribe internal bribe;
    PoolKey internal poolKey;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal distributor = makeAddr("distributor");

    function setUp() public override {
        super.setUp();
        vm.warp(1);

        stakeToken = new TestToken(address(this));
        rewardToken = new TestToken(distributor);

        address deployAddress = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("Ve33.sol:Ve33", abi.encode(core, address(stakeToken)), deployAddress);
        ve33 = Ve33(payable(deployAddress));
        router = new Router(core, address(0), address(ve33));

        VeTokenMetadata metadata = new VeTokenMetadata("Stake Token", "STK", 18, address(stakeToken));
        veToken = new VeToken(core, ve33, metadata, "Vote Escrow Stake Token", "veSTK");

        poolKey = createPool(address(token0), address(token1), 0, createConcentratedPoolConfig(0, 64, address(ve33)));
        bribe = new VeTokenBribe(veToken, poolKey, VOTING_FEE, address(rewardToken), distributor);

        SafeTransferLib.safeTransfer(address(stakeToken), alice, 100e18);
        SafeTransferLib.safeTransfer(address(stakeToken), bob, 100e18);
        vm.prank(alice);
        stakeToken.approve(address(veToken), type(uint256).max);
        vm.prank(bob);
        stakeToken.approve(address(veToken), type(uint256).max);
        vm.prank(distributor);
        rewardToken.approve(address(bribe), type(uint256).max);
    }

    function _createVeToken(address account, uint128 amount) internal returns (uint256 veId) {
        uint64 end = uint64(block.timestamp + veToken.MAX_STAKE_DURATION());
        vm.prank(account);
        veId = veToken.stake(amount, end);
        vm.prank(account);
        veToken.approve(address(bribe), veId);
    }

    function _stakeInBribe(address account, uint128 amount) internal returns (uint256 veId) {
        veId = _createVeToken(account, amount);
        vm.prank(account);
        bribe.stake(veId);
    }

    function _defaultRewardEnd() internal view returns (uint64) {
        return uint64(nextValidTime(vm.getBlockTimestamp(), vm.getBlockTimestamp() + REWARD_DURATION - 1));
    }

    function _rewardRateForAmount(uint128 amount, uint64 endTime) internal view returns (uint160) {
        return uint160((uint256(amount) << 32) / (endTime - vm.getBlockTimestamp()));
    }

    function _fund(uint128 amount) internal returns (uint64 endTime, uint160 rate, uint128 scheduledAmount) {
        endTime = _defaultRewardEnd();
        rate = _rewardRateForAmount(amount, endTime);
        vm.prank(distributor);
        scheduledAmount = bribe.scheduleRewards(0, endTime, rate);
    }

    function _emitted(uint160 rate, uint256 elapsed) internal pure returns (uint256) {
        return (uint256(rate) * elapsed) >> 32;
    }

    function test_stakeTakesCustodyReadsWeightAndVotesForSinglePool() public {
        uint256 veId = _stakeInBribe(alice, 2e18);

        (address depositor, uint128 weight,,) = bribe.deposits(veId);
        (PoolId votedPool, uint128 appliedWeight, uint64 swapFee,,) = veToken.voteState(veId);

        assertEq(depositor, alice);
        assertEq(weight, 2e18);
        assertEq(weight, appliedWeight);
        assertEq(bribe.totalWeight(), weight);
        assertEq(veToken.ownerOf(veId), address(bribe));
        assertEq(PoolId.unwrap(votedPool), PoolId.unwrap(poolKey.toPoolId()));
        assertEq(swapFee, VOTING_FEE);
    }

    function test_rewardsAreDistributedByWeightAndTime() public {
        uint256 aliceVeId = _stakeInBribe(alice, 1e18);
        uint256 bobVeId = _stakeInBribe(bob, 3e18);
        (, uint160 rate,) = _fund(700e18);

        vm.warp(block.timestamp + 1 days);
        uint256 streamed = _emitted(rate, 1 days);

        assertApproxEqAbs(bribe.earned(aliceVeId), streamed / 4, 2);
        assertApproxEqAbs(bribe.earned(bobVeId), (streamed * 3) / 4, 2);

        uint256 aliceBalanceBefore = rewardToken.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = bribe.claimReward(aliceVeId);
        assertApproxEqAbs(claimed, streamed / 4, 2);
        assertEq(rewardToken.balanceOf(alice), aliceBalanceBefore + claimed);
    }

    function testFuzz_totalEarnedNeverExceedsStreamedRewards(
        uint128 aliceAmount,
        uint128 bobAmount,
        uint96 rewardAmount,
        uint32 elapsed
    ) public {
        aliceAmount = uint128(bound(aliceAmount, 1, 100e18));
        bobAmount = uint128(bound(bobAmount, 1, 100e18));
        rewardAmount = uint96(bound(rewardAmount, 1, type(uint96).max));
        elapsed = uint32(bound(elapsed, 0, REWARD_DURATION));

        uint256 aliceVeId = _stakeInBribe(alice, aliceAmount);
        uint256 bobVeId = _stakeInBribe(bob, bobAmount);
        (, uint160 rate, uint128 scheduledAmount) = _fund(rewardAmount);
        vm.warp(vm.getBlockTimestamp() + elapsed);

        uint256 totalEarned = bribe.earned(aliceVeId) + bribe.earned(bobVeId);
        uint256 streamed = _emitted(rate, elapsed);
        assertLe(totalEarned, streamed);
        assertLe(streamed, scheduledAmount);
    }

    function test_laterStakeOnlyEarnsForTimeInBribe() public {
        uint256 aliceVeId = _stakeInBribe(alice, 1e18);
        (, uint160 rate,) = _fund(700e18);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 bobVeId = _stakeInBribe(bob, 1e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 streamedPerDay = _emitted(rate, 1 days);

        assertApproxEqAbs(bribe.earned(aliceVeId), streamedPerDay + streamedPerDay / 2, 2);
        assertApproxEqAbs(bribe.earned(bobVeId), streamedPerDay / 2, 2);
    }

    function test_unstakeClaimsRewardsClearsVoteAndReturnsNft() public {
        uint256 veId = _stakeInBribe(alice, 1e18);
        (, uint160 rate,) = _fund(700e18);
        vm.warp(block.timestamp + 1 days);

        uint256 rewardBalanceBefore = rewardToken.balanceOf(alice);
        vm.prank(alice);
        (uint256 reward,,) = bribe.unstake(veId);

        assertApproxEqAbs(reward, _emitted(rate, 1 days), 1);
        assertEq(rewardToken.balanceOf(alice), rewardBalanceBefore + reward);
        assertEq(veToken.ownerOf(veId), alice);
        assertEq(bribe.totalWeight(), 0);
        (PoolId votedPool, uint128 weight,,,) = veToken.voteState(veId);
        assertEq(PoolId.unwrap(votedPool), bytes32(0));
        assertEq(weight, 0);
    }

    function test_unstakeClaimsUnderlyingVotingFees() public {
        createPosition(poolKey, -64, 64, 1e18, 1e18);
        uint256 veId = _stakeInBribe(alice, 1e18);

        token0.approve(address(router), type(uint256).max);
        router.swapAllowPartialFill(
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: int128(100_000), _isToken1: false, _skipAhead: 0
            }),
            address(this)
        );

        uint256 balance0Before = token0.balanceOf(alice);
        uint256 balance1Before = token1.balanceOf(alice);
        vm.prank(alice);
        (, uint128 fees0, uint128 fees1) = bribe.unstake(veId);

        assertGt(uint256(fees0) + fees1, 0);
        assertEq(token0.balanceOf(alice), balance0Before + fees0);
        assertEq(token1.balanceOf(alice), balance1Before + fees1);
    }

    function test_unstakeWithoutClaimingForfeitsRewardsAndReturnsNft() public {
        uint256 veId = _stakeInBribe(alice, 1e18);
        _fund(700e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertGt(bribe.earned(veId), 0);

        uint256 rewardBalanceBefore = rewardToken.balanceOf(alice);
        vm.prank(alice);
        bribe.unstakeWithoutClaiming(veId);

        assertEq(veToken.ownerOf(veId), alice);
        assertEq(rewardToken.balanceOf(alice), rewardBalanceBefore);
        assertEq(bribe.totalWeight(), 0);
        (address depositor,,,) = bribe.deposits(veId);
        assertEq(depositor, address(0));
    }

    function test_unstakeWithoutClaimingEscapesBlockedRewardToken() public {
        BlockingTransferToken blockingToken = new BlockingTransferToken(address(this));
        VeTokenBribe blockingBribe =
            new VeTokenBribe(veToken, poolKey, VOTING_FEE, address(blockingToken), address(this));
        blockingToken.approve(address(blockingBribe), type(uint256).max);

        uint256 veId = _createVeToken(alice, 1e18);
        vm.prank(alice);
        veToken.approve(address(blockingBribe), veId);
        vm.prank(alice);
        blockingBribe.stake(veId);
        uint64 endTime = _defaultRewardEnd();
        blockingBribe.scheduleRewards(0, endTime, _rewardRateForAmount(700e18, endTime));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        blockingToken.setTransfersBlocked(true);

        vm.prank(alice);
        vm.expectRevert(SafeTransferLib.TransferFailed.selector);
        blockingBribe.unstake(veId);
        assertEq(veToken.ownerOf(veId), address(blockingBribe));

        vm.prank(alice);
        blockingBribe.unstakeWithoutClaiming(veId);
        assertEq(veToken.ownerOf(veId), alice);
    }

    function test_stakeSettlesCompatibleVoteFeesAndAppliesCurrentWeight() public {
        createPosition(poolKey, -64, 64, 1e18, 1e18);
        uint256 veId = _createVeToken(alice, 1e18);
        vm.prank(alice);
        veToken.vote(veId, poolKey, VOTING_FEE);

        token0.approve(address(router), type(uint256).max);
        router.swapAllowPartialFill(
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: int128(100_000), _isToken1: false, _skipAhead: 0
            }),
            address(this)
        );
        (,,, uint128 claimable0Before, uint128 claimable1Before) = veToken.voteState(veId);
        assertGt(uint256(claimable0Before) + claimable1Before, 0);
        vm.warp(vm.getBlockTimestamp() + 365 days);

        uint256 balance0Before = token0.balanceOf(alice);
        uint256 balance1Before = token1.balanceOf(alice);

        vm.prank(alice);
        bribe.stake(veId);
        (, uint128 appliedWeight,, uint128 claimable0After, uint128 claimable1After) = veToken.voteState(veId);

        assertEq(token0.balanceOf(alice), balance0Before + claimable0Before);
        assertEq(token1.balanceOf(alice), balance1Before + claimable1Before);
        assertEq(claimable0After, 0);
        assertEq(claimable1After, 0);
        assertEq(appliedWeight, veToken.votingPower(veId));
        assertLt(appliedWeight, 1e18);
    }

    function test_stakeReplacesExistingFeeForTargetPool() public {
        uint64 previousFee = 1 << 61;
        uint256 veId = _createVeToken(alice, 1e18);
        vm.prank(alice);
        veToken.vote(veId, poolKey, previousFee);

        vm.prank(alice);
        bribe.stake(veId);

        (,, uint64 appliedFee,,) = veToken.voteState(veId);
        assertEq(appliedFee, VOTING_FEE);
    }

    function test_stakeRejectsIncompatibleExistingVoteWithoutTakingCustody() public {
        PoolKey memory otherPool =
            createPool(address(token0), address(stakeToken), 0, createConcentratedPoolConfig(0, 64, address(ve33)));
        uint256 veId = _createVeToken(alice, 1e18);
        vm.prank(alice);
        veToken.vote(veId, otherPool, VOTING_FEE);

        vm.prank(alice);
        vm.expectRevert(VeTokenBribe.IncompatibleExistingVote.selector);
        bribe.stake(veId);

        assertEq(veToken.ownerOf(veId), alice);
    }

    function test_stakeRejectsExpiredVeTokenWithoutTakingCustody() public {
        uint64 end = uint64(vm.getBlockTimestamp() + 1);
        vm.prank(alice);
        uint256 veId = veToken.stake(1e18, end);
        vm.prank(alice);
        veToken.approve(address(bribe), veId);
        vm.warp(vm.getBlockTimestamp() + 1);

        vm.prank(alice);
        vm.expectRevert(VeTokenBribe.NoVotingPower.selector);
        bribe.stake(veId);

        assertEq(veToken.ownerOf(veId), alice);
    }

    function test_refreshVoteUsesCurrentWeightWithoutDiscardingVotingFees() public {
        createPosition(poolKey, -64, 64, 1e18, 1e18);
        uint256 veId = _stakeInBribe(alice, 1e18);
        uint128 initialWeight = uint128(bribe.totalWeight());

        token0.approve(address(router), type(uint256).max);
        router.swapAllowPartialFill(
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: int128(100_000), _isToken1: false, _skipAhead: 0
            }),
            address(this)
        );
        vm.warp(block.timestamp + 365 days);

        uint256 balanceBefore = token1.balanceOf(alice);
        vm.prank(alice);
        bribe.refreshVote(veId);

        (, uint128 refreshedWeight,,,) = veToken.voteState(veId);
        assertLt(refreshedWeight, initialWeight);
        assertEq(bribe.totalWeight(), refreshedWeight);
        assertGt(token1.balanceOf(alice), balanceBefore);
    }

    function test_reentrantFeeRecipientCannotDoubleApplyRefreshWeightDelta() public {
        CallbackTestToken callbackToken = new CallbackTestToken(address(this));
        TestToken pairedToken = new TestToken(address(this));
        (address poolToken0, address poolToken1) = address(callbackToken) < address(pairedToken)
            ? (address(callbackToken), address(pairedToken))
            : (address(pairedToken), address(callbackToken));
        PoolKey memory callbackPool =
            createPool(poolToken0, poolToken1, 0, createConcentratedPoolConfig(0, 64, address(ve33)));
        VeTokenBribe callbackBribe =
            new VeTokenBribe(veToken, callbackPool, VOTING_FEE, address(rewardToken), distributor);
        createPosition(callbackPool, -64, 64, 1e18, 1e18);

        uint256 veId = _createVeToken(alice, 1e18);
        ReenteringBribeDepositor depositor = new ReenteringBribeDepositor();
        vm.prank(alice);
        veToken.transferFrom(alice, address(depositor), veId);
        depositor.stake(callbackBribe, veToken, veId);

        TestToken(poolToken0).approve(address(router), type(uint256).max);
        TestToken(poolToken1).approve(address(router), type(uint256).max);
        bool callbackIsToken1 = address(callbackToken) == poolToken1;
        router.swapAllowPartialFill(
            callbackPool,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0),
                _amount: int128(100_000),
                _isToken1: !callbackIsToken1,
                _skipAhead: 0
            }),
            address(this)
        );
        vm.warp(vm.getBlockTimestamp() + 365 days);

        depositor.refreshWithCallback(callbackBribe, veId, callbackToken);

        (, uint128 depositWeight,,) = callbackBribe.deposits(veId);
        (, uint128 appliedWeight,,,) = veToken.voteState(veId);
        assertTrue(depositor.reentered());
        assertEq(callbackBribe.totalWeight(), depositWeight);
        assertEq(depositWeight, appliedWeight);
    }

    function test_expiredRefreshedVoteCanStillBeUnstaked() public {
        uint256 veId = _stakeInBribe(alice, 1e18);
        (, uint64 end) = veToken.stakes(veId);
        vm.warp(end);

        vm.prank(alice);
        bribe.refreshVote(veId);
        assertEq(bribe.totalWeight(), 0);

        vm.prank(alice);
        bribe.unstake(veId);
        assertEq(veToken.ownerOf(veId), alice);
    }

    function test_onlyDistributorCanScheduleRewards() public {
        uint64 endTime = _defaultRewardEnd();

        vm.expectRevert(VeTokenBribe.RewardDistributorOnly.selector);
        bribe.scheduleRewards(0, endTime, uint160(1 << 32));
    }

    function test_reentrantFundingCannotCommitAnInconsistentSchedule() public {
        ReenteringFundingToken fundingToken = new ReenteringFundingToken();
        VeTokenBribe reentrantBribe =
            new VeTokenBribe(veToken, poolKey, VOTING_FEE, address(fundingToken), address(fundingToken));
        uint64 endTime = _defaultRewardEnd();
        uint160 rate = uint160(1 << 32);
        uint128 expectedAmount = uint128(endTime - vm.getBlockTimestamp());

        vm.expectRevert(
            abi.encodeWithSelector(
                VeTokenBribe.UnexpectedRewardAmount.selector, expectedAmount, uint256(expectedAmount) * 2
            )
        );
        fundingToken.fundWithReentry(reentrantBribe, endTime, rate, rate);

        assertEq(reentrantBribe.rewardRate(), 0);
        assertEq(fundingToken.balanceOf(address(reentrantBribe)), 0);
        assertEq(reentrantBribe.rewardRateDeltaAtTime(endTime), 0);
    }

    function test_overlappingSchedulesAddTheirRates() public {
        uint256 veId = _stakeInBribe(alice, 1e18);
        (, uint160 firstRate,) = _fund(700e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 expected = _emitted(firstRate, 1 days);

        uint64 secondEnd = _defaultRewardEnd();
        uint160 secondRate = _rewardRateForAmount(600e18, secondEnd);
        vm.prank(distributor);
        bribe.scheduleRewards(0, secondEnd, secondRate);
        assertEq(bribe.rewardRate(), firstRate + secondRate);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        expected += _emitted(firstRate + secondRate, 1 days);

        assertApproxEqAbs(bribe.earned(veId), expected, 2);
    }

    function test_schedulesStopIndependentlyAtTheirEndTimes() public {
        uint64 firstEnd = _defaultRewardEnd();
        uint64 secondEnd = uint64(nextValidTime(vm.getBlockTimestamp(), uint256(firstEnd) + REWARD_DURATION - 1));
        uint160 firstRate = uint160(1 << 32);
        uint160 secondRate = uint160(2 << 32);

        vm.prank(distributor);
        bribe.scheduleRewards(0, firstEnd, firstRate);
        vm.prank(distributor);
        bribe.scheduleRewards(0, secondEnd, secondRate);

        assertEq(bribe.rewardRate(), firstRate + secondRate);
        assertEq(bribe.rewardRateDeltaAtTime(firstEnd), -int256(uint256(firstRate)));
        assertEq(bribe.rewardRateDeltaAtTime(secondEnd), -int256(uint256(secondRate)));

        vm.warp(firstEnd);
        bribe.accrueRewards();
        assertEq(bribe.rewardRate(), secondRate);
        assertEq(bribe.rewardRateDeltaAtTime(firstEnd), 0);

        vm.warp(secondEnd);
        bribe.accrueRewards();
        assertEq(bribe.rewardRate(), 0);
        assertEq(bribe.rewardRateDeltaAtTime(secondEnd), 0);
    }

    function test_futureScheduleStartsAtItsConfiguredTime() public {
        uint256 veId = _stakeInBribe(alice, 1e18);
        uint64 startTime = uint64(nextValidTime(vm.getBlockTimestamp(), vm.getBlockTimestamp() + 1 days - 1));
        uint64 endTime = uint64(nextValidTime(vm.getBlockTimestamp(), uint256(startTime) + REWARD_DURATION - 1));
        uint160 rate = uint160(1e18 << 32);

        vm.prank(distributor);
        bribe.scheduleRewards(startTime, endTime, rate);
        assertEq(bribe.rewardRate(), 0);
        assertEq(bribe.rewardRateDeltaAtTime(startTime), int256(uint256(rate)));

        vm.warp(startTime);
        assertEq(bribe.rewardRate(), rate);
        assertEq(bribe.earned(veId), 0);

        vm.warp(uint256(startTime) + 1 days);
        assertApproxEqAbs(bribe.earned(veId), _emitted(rate, 1 days), 1);
    }

    function test_scheduleRewardsRejectsInvalidEndTime() public {
        vm.prank(distributor);
        vm.expectRevert(VeTokenBribe.InvalidTimestamps.selector);
        bribe.scheduleRewards(0, uint64(vm.getBlockTimestamp()), uint160(1 << 32));
    }

    function test_scheduleRewardsRejectsFundingAboveUint128() public {
        uint256 alignedTime = (vm.getBlockTimestamp() + 255) & ~uint256(255);
        vm.warp(alignedTime);
        uint64 endTime = uint64(alignedTime + 256);

        vm.prank(distributor);
        vm.expectRevert(VeTokenBribe.RewardFundingOverflow.selector);
        bribe.scheduleRewards(0, endTime, uint160(1) << 152);

        assertEq(bribe.rewardRate(), 0);
        assertEq(bribe.rewardRateDeltaAtTime(endTime), 0);
    }

    function test_scheduleRewardsAllowsUint128MaxFunding() public {
        uint256 alignedTime = (vm.getBlockTimestamp() + 255) & ~uint256(255);
        vm.warp(alignedTime);
        uint64 endTime = uint64(alignedTime + 256);
        uint160 rate = uint160(uint256(type(uint128).max) << 24);

        vm.prank(distributor);
        uint128 amount = bribe.scheduleRewards(0, endTime, rate);

        assertEq(amount, type(uint128).max);
        assertEq(rewardToken.balanceOf(address(bribe)), type(uint128).max);
        assertEq(bribe.rewardRate(), rate);
        assertEq(bribe.rewardRateDeltaAtTime(endTime), -int256(uint256(rate)));
    }

    function test_rewardScheduleAccruesAcrossUint32Wrap() public {
        vm.warp(uint256(type(uint32).max) - 1 days);
        uint256 veId = _stakeInBribe(alice, 1e18);
        uint64 endTime = _defaultRewardEnd();
        (, uint160 rate,) = _fund(700e18);

        assertGt(endTime, type(uint32).max);
        assertLt(uint32(endTime), uint32(vm.getBlockTimestamp()));
        assertLt(bribe.rewardRateDeltaAtTime(endTime), int256(0));
        assertEq(bribe.rewardRateDeltaAtTime(uint32(endTime)), 0);

        vm.warp(endTime);
        bribe.accrueRewards();

        assertEq(bribe.rewardsLastAccrued(), uint32(endTime));
        assertEq(bribe.rewardRate(), 0);
        assertEq(bribe.rewardRateDeltaAtTime(endTime), 0);
        assertApproxEqAbs(bribe.earned(veId), _emitted(rate, endTime - (uint256(type(uint32).max) - 1 days)), 1);
    }

    function test_rewardsEmittedWithoutVotingWeightAreNotRetroactive() public {
        (, uint160 rate,) = _fund(700e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);

        uint256 veId = _stakeInBribe(alice, 1e18);
        assertEq(bribe.earned(veId), 0);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertApproxEqAbs(bribe.earned(veId), _emitted(rate, 1 days), 1);
    }

    function test_virtualVotingFeeCanBeOverridden() public {
        uint64 overriddenFee = 1 << 61;
        OverriddenFeeVeTokenBribe overriddenBribe =
            new OverriddenFeeVeTokenBribe(veToken, poolKey, address(rewardToken), distributor, overriddenFee);

        uint256 veId = _createVeToken(alice, 1e18);
        vm.prank(alice);
        veToken.approve(address(overriddenBribe), veId);
        vm.prank(alice);
        overriddenBribe.stake(veId);

        (,, uint64 appliedFee,,) = veToken.voteState(veId);
        assertEq(overriddenBribe.votingFee(), overriddenFee);
        assertEq(appliedFee, overriddenFee);
    }

    function test_constructorRejectsPoolFromAnotherExtension() public {
        PoolKey memory invalidPool = PoolKey({
            token0: poolKey.token0, token1: poolKey.token1, config: createConcentratedPoolConfig(0, 64, address(0))
        });

        vm.expectRevert(VeTokenBribe.InvalidPool.selector);
        new VeTokenBribe(veToken, invalidPool, VOTING_FEE, address(rewardToken), distributor);
    }

    function test_onlyDepositorCanManageStake() public {
        uint256 veId = _stakeInBribe(alice, 1e18);

        vm.prank(bob);
        vm.expectRevert(VeTokenBribe.DepositOwnerOnly.selector);
        bribe.claimReward(veId);

        vm.prank(bob);
        vm.expectRevert(VeTokenBribe.DepositOwnerOnly.selector);
        bribe.unstake(veId);
    }
}
