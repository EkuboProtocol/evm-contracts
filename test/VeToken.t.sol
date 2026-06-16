// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";

import {TestToken} from "./TestToken.sol";
import {IVeTokenObserver, Lock, VeToken, lockAmount, lockEnd} from "../src/VeToken.sol";

using {lockAmount, lockEnd} for Lock;

contract TestVeTokenObserver is IVeTokenObserver {
    uint256 public calls;
    uint256 public lastVeId;
    Lock public lastLock;

    function beforeLockUpdate(uint256 veId, Lock currentLock) external {
        calls++;
        lastVeId = veId;
        lastLock = currentLock;
    }
}

contract VeTokenTest is Test {
    TestToken internal stakeToken;
    TestVeTokenObserver internal observer;
    VeToken internal veToken;

    function setUp() public {
        stakeToken = new TestToken(address(this));
        observer = new TestVeTokenObserver();
        veToken = new VeToken(address(stakeToken), observer);
        stakeToken.approve(address(veToken), type(uint256).max);
    }

    function test_gas_createLock() public {
        vm.cool(address(veToken));
        vm.cool(address(stakeToken));
        veToken.createLock(1e18, uint64(block.timestamp + veToken.MAX_LOCK_DURATION()));
        vm.snapshotGasLastCall("VeToken#createLock");
    }

    function test_constructorAndMetadata() public view {
        assertEq(veToken.name(), "Vote Escrow");
        assertEq(veToken.symbol(), "ve");
        assertEq(veToken.tokenURI(1), "");
        assertEq(veToken.stakeToken(), address(stakeToken));
        assertEq(address(veToken.lockObserver()), address(observer));
    }

    function test_lockLifecycleAndInvalidLockPaths() public {
        uint256 maxLockDuration = veToken.MAX_LOCK_DURATION();

        vm.expectRevert(VeToken.InvalidLock.selector);
        veToken.createLock(0, uint64(block.timestamp + 1));
        vm.expectRevert(VeToken.InvalidLock.selector);
        veToken.createLock(1, uint64(block.timestamp));
        vm.expectRevert(VeToken.InvalidLock.selector);
        veToken.createLock(1, uint64(block.timestamp + maxLockDuration + 1));

        uint64 end = uint64(block.timestamp + maxLockDuration);
        uint256 veId = veToken.createLock(1e18, end);
        assertEq(veToken.ownerOf(veId), address(this));
        assertEq(stakeToken.balanceOf(address(veToken)), 1e18);

        Lock userLock = veToken.locks(veId);
        assertEq(userLock.lockAmount(), 1e18);
        assertEq(userLock.lockEnd(), end);
        assertEq(veToken.votingPower(veId), 1e18);

        vm.expectRevert(VeToken.InvalidLock.selector);
        veToken.increaseLockAmount(veId, 0);
        veToken.increaseLockAmount(veId, 2e18);

        assertEq(observer.calls(), 1);
        assertEq(observer.lastVeId(), veId);
        Lock observedLock = observer.lastLock();
        assertEq(observedLock.lockAmount(), 1e18);
        assertEq(observedLock.lockEnd(), end);

        userLock = veToken.locks(veId);
        assertEq(userLock.lockAmount(), 3e18);
        assertEq(userLock.lockEnd(), end);

        vm.expectRevert(VeToken.InvalidLock.selector);
        veToken.extendLock(veId, end);
        vm.warp(10);
        uint64 extendedEnd = uint64(block.timestamp + maxLockDuration);
        veToken.extendLock(veId, extendedEnd);

        assertEq(observer.calls(), 2);
        observedLock = observer.lastLock();
        assertEq(observedLock.lockAmount(), 3e18);
        assertEq(observedLock.lockEnd(), end);

        userLock = veToken.locks(veId);
        assertEq(userLock.lockAmount(), 3e18);
        assertEq(userLock.lockEnd(), extendedEnd);

        vm.expectRevert(VeToken.InvalidLock.selector);
        veToken.withdrawLock(veId);
        vm.warp(extendedEnd);
        assertEq(veToken.votingPower(veId), 0);
        uint256 balanceBefore = stakeToken.balanceOf(address(this));
        veToken.withdrawLock(veId);

        assertEq(observer.calls(), 3);
        observedLock = observer.lastLock();
        assertEq(observedLock.lockAmount(), 3e18);
        assertEq(observedLock.lockEnd(), extendedEnd);
        assertEq(stakeToken.balanceOf(address(this)), balanceBefore + 3e18);
    }

    function test_approvedOperatorCanUpdateLock() public {
        uint256 veId = veToken.createLock(1e18, uint64(block.timestamp + veToken.MAX_LOCK_DURATION()));
        address operator = address(1234);
        stakeToken.transfer(operator, 1e18);
        veToken.approve(operator, veId);

        vm.startPrank(operator);
        stakeToken.approve(address(veToken), type(uint256).max);
        veToken.increaseLockAmount(veId, 1e18);
        vm.stopPrank();

        assertEq(veToken.locks(veId).lockAmount(), 2e18);
    }
}
