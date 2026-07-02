// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";

import {FullTest} from "./FullTest.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {Ve33EmissionRateScheduler} from "../src/Ve33EmissionRateScheduler.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {Ve33, VE33_STAKE_TOKEN_SAVED_BALANCE_ID, ve33CallPoints} from "../src/extensions/Ve33.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {Ve33Lib} from "../src/libraries/Ve33Lib.sol";
import {nextValidTime} from "../src/math/time.sol";
import {Ve33EmissionRateConfig} from "../src/types/ve33EmissionRateConfig.sol";

contract Ve33EmissionRateSchedulerTest is FullTest {
    using CoreLib for *;
    using Ve33Lib for Ve33;

    uint32 private constant SCHEDULE_DURATION = 1 weeks;
    uint160 private constant TARGET_RATE = uint160(uint256(1e12) << 32);

    MintableERC20 internal stakeToken;
    Ve33 internal ve;
    Ve33EmissionRateScheduler internal scheduler;

    function setUp() public override {
        super.setUp();

        stakeToken = new MintableERC20(address(this), "Mintable TestToken", "mTT", 18);
        address deployAddress = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("Ve33.sol:Ve33", abi.encode(core, address(stakeToken)), deployAddress);
        ve = Ve33(payable(deployAddress));

        scheduler = new Ve33EmissionRateScheduler(owner, core, ve);
        stakeToken.transferOwnership(address(scheduler));
    }

    function test_mintableERC20_ownerCanMintToRecipient() public {
        MintableERC20 token = new MintableERC20(address(this), "Mintable TestToken", "mTT", 18);
        token.mint(owner, 123);

        assertEq(token.balanceOf(owner), 123);
    }

    function test_mintableERC20_metadata() public {
        MintableERC20 token = new MintableERC20(address(this), "Mintable TestToken", "mTT", 18);

        assertEq(token.name(), "Mintable TestToken");
        assertEq(token.symbol(), "mTT");
        assertEq(token.decimals(), 18);
    }

    function test_mintableERC20_constructorFailsIfMetadataIsTooLong() public {
        vm.expectRevert(MintableERC20.PackedStringTooLong.selector);
        new MintableERC20(address(this), "This token name is too long to pack", "mTT", 18);

        vm.expectRevert(MintableERC20.PackedStringTooLong.selector);
        new MintableERC20(address(this), "Mintable TestToken", "This token symbol is too long to pack", 18);
    }

    function test_mintableERC20_mintFailsIfNotOwner() public {
        vm.prank(owner);
        vm.expectRevert(Ownable.Unauthorized.selector);
        stakeToken.mint(owner, 123);
    }

    function test_constructorReadsTokenFromVe33() public view {
        assertEq(address(scheduler.token()), address(stakeToken));
    }

    function test_setConfigFailsIfNotOwner() public {
        vm.prank(address(0xbeef));
        vm.expectRevert(Ownable.Unauthorized.selector);
        scheduler.setConfig(TARGET_RATE, SCHEDULE_DURATION);
    }

    function test_setConfigFailsWithNonzeroTargetAndZeroDuration() public {
        vm.prank(owner);
        vm.expectRevert(Ve33EmissionRateScheduler.InvalidScheduleDuration.selector);
        scheduler.setConfig(TARGET_RATE, 0);
    }

    function test_setConfigPacksTargetRateAndScheduleDuration() public {
        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, SCHEDULE_DURATION);

        Ve33EmissionRateConfig config = scheduler.config();
        assertEq(config.targetRate(), TARGET_RATE);
        assertEq(config.scheduleDuration(), SCHEDULE_DURATION);
    }

    function test_mintAndScheduleReturnsZeroWhenTargetRateIsZero() public {
        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(stakeToken.totalSupply(), 0);
        assertEq(ve.emissionRate(), 0);
    }

    function test_lockCallbackFailsIfNotCore() public {
        vm.expectRevert(BaseLocker.BaseLockerAccountantOnly.selector);
        scheduler.locked_6416899205(0);
    }

    function test_mintAndScheduleMintsAndSchedulesShortfall() public {
        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, SCHEDULE_DURATION);

        uint64 expectedEndTime = _expectedEndTime(SCHEDULE_DURATION);
        uint128 expectedAmount = _scheduleAmount(TARGET_RATE, expectedEndTime);

        uint128 amount = scheduler.mintAndSchedule();

        assertEq(amount, expectedAmount);
        assertEq(stakeToken.totalSupply(), expectedAmount);
        assertEq(stakeToken.balanceOf(address(core)), expectedAmount);
        assertEq(_rewardSavedBalance(), expectedAmount);
        assertEq(ve.emissionRate(), TARGET_RATE);
        assertEq(ve.emissionRateDeltaAtTime(expectedEndTime), -int256(uint256(TARGET_RATE)));
    }

    function test_mintAndScheduleReturnsZeroWhenCurrentRateAlreadyAtTarget() public {
        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, SCHEDULE_DURATION);

        uint128 firstAmount = scheduler.mintAndSchedule();
        assertGt(firstAmount, 0);

        uint128 secondAmount = scheduler.mintAndSchedule();

        assertEq(secondAmount, 0);
        assertEq(stakeToken.totalSupply(), firstAmount);
        assertEq(ve.emissionRate(), TARGET_RATE);
    }

    function test_mintAndScheduleTopsUpOnlyRateShortfall() public {
        uint160 initialTarget = TARGET_RATE / 4;

        vm.startPrank(owner);
        scheduler.setConfig(initialTarget, SCHEDULE_DURATION);
        vm.stopPrank();
        uint128 firstAmount = scheduler.mintAndSchedule();

        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, SCHEDULE_DURATION);

        uint64 expectedEndTime = _expectedEndTime(SCHEDULE_DURATION);
        uint160 shortfall;
        unchecked {
            shortfall = TARGET_RATE - initialTarget;
        }
        uint128 expectedTopUp = _scheduleAmount(shortfall, expectedEndTime);

        uint128 topUp = scheduler.mintAndSchedule();

        assertEq(topUp, expectedTopUp);
        assertEq(stakeToken.totalSupply(), uint256(firstAmount) + topUp);
        assertEq(ve.emissionRate(), TARGET_RATE);
    }

    function test_mintAndScheduleAccruesExpiredScheduleBeforeCheckingTarget() public {
        vm.prank(owner);
        scheduler.setConfig(TARGET_RATE, SCHEDULE_DURATION);

        uint64 endTime = _expectedEndTime(SCHEDULE_DURATION);
        uint128 firstAmount = scheduler.mintAndSchedule();

        vm.warp(endTime);

        uint64 nextEndTime = _expectedEndTime(SCHEDULE_DURATION);
        uint128 expectedAmount = _scheduleAmount(TARGET_RATE, nextEndTime);
        uint128 secondAmount = scheduler.mintAndSchedule();

        assertEq(secondAmount, expectedAmount);
        assertEq(stakeToken.totalSupply(), uint256(firstAmount) + secondAmount);
        assertEq(ve.emissionRate(), TARGET_RATE);
    }

    function _expectedEndTime(uint32 scheduleDuration) internal view returns (uint64) {
        return uint64(nextValidTime(vm.getBlockTimestamp(), vm.getBlockTimestamp() + uint256(scheduleDuration) - 1));
    }

    function _scheduleAmount(uint160 rewardRate, uint64 endTime) internal view returns (uint128) {
        return uint128((((endTime - vm.getBlockTimestamp()) * uint256(rewardRate)) + type(uint32).max) >> 32);
    }

    function _rewardSavedBalance() internal view returns (uint128 saved) {
        (saved,) = core.savedBalances(
            address(ve), address(stakeToken), address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID
        );
    }
}
