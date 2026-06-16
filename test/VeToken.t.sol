// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {TestToken} from "./TestToken.sol";
import {Lock, VeToken, lockAmount, lockEnd} from "../src/VeToken.sol";
import {VE33, ve33CallPoints} from "../src/extensions/VE33.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";

using {lockAmount, lockEnd} for Lock;

contract VeTokenTest is FullTest {
    using CoreLib for *;

    TestToken internal stakeToken;
    VE33 internal ve33;
    VeToken internal veToken;

    function setUp() public override {
        super.setUp();

        stakeToken = new TestToken(address(this));
        address deployAddress = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("VE33.sol", abi.encode(core, address(stakeToken)), deployAddress);
        ve33 = VE33(payable(deployAddress));
        veToken = new VeToken(core, ve33);
        stakeToken.approve(address(veToken), type(uint256).max);
    }

    function coolAllContracts() internal override {
        FullTest.coolAllContracts();
        vm.cool(address(ve33));
        vm.cool(address(veToken));
        vm.cool(address(stakeToken));
    }

    function test_gas_createLock() public {
        coolAllContracts();
        veToken.createLock(1e18, uint64(block.timestamp + veToken.MAX_LOCK_DURATION()));
        vm.snapshotGasLastCall("VeToken#createLock");
    }

    function test_constructorAndMetadata() public view {
        assertEq(veToken.name(), "Vote Escrow TestToken");
        assertEq(veToken.symbol(), "veTT");
        assertEq(veToken.tokenURI(1), "");
        assertEq(veToken.stakeToken(), address(stakeToken));
        assertEq(address(veToken.ve33()), address(ve33));
    }

    function test_lockLifecycleAndInvalidLockPaths() public {
        uint256 maxLockDuration = veToken.MAX_LOCK_DURATION();

        vm.expectRevert(VE33.InvalidLock.selector);
        veToken.createLock(0, uint64(block.timestamp + 1));
        vm.expectRevert(VE33.InvalidLock.selector);
        veToken.createLock(1, uint64(block.timestamp));
        vm.expectRevert(VE33.InvalidLock.selector);
        veToken.createLock(1, uint64(block.timestamp + maxLockDuration + 1));

        uint64 end = uint64(block.timestamp + maxLockDuration);
        uint256 veId = veToken.createLock(1e18, end);
        assertEq(veToken.ownerOf(veId), address(this));
        bytes32 salt = bytes32(veId);
        bytes32 lockId = keccak256(abi.encode(address(veToken), salt, end));
        (uint128 saved,) = core.savedBalances(address(ve33), address(stakeToken), address(type(uint160).max), lockId);
        assertEq(saved, 1e18);
        assertEq(ve33.lockAmounts(address(veToken), salt, end), 1e18);
        assertEq(ve33.lockAmounts(address(this), salt, end), 0);

        Lock userLock = veToken.locks(veId);
        assertEq(userLock.lockAmount(), 1e18);
        assertEq(userLock.lockEnd(), end);
        assertEq(veToken.votingPower(veId), 1e18);

        vm.expectRevert(VE33.InvalidLock.selector);
        veToken.increaseLockAmount(veId, 0);
        veToken.increaseLockAmount(veId, 2e18);

        userLock = veToken.locks(veId);
        assertEq(userLock.lockAmount(), 3e18);
        assertEq(userLock.lockEnd(), end);

        vm.expectRevert(VeToken.InvalidLock.selector);
        veToken.extendLock(veId, end);
        vm.warp(10);
        uint64 extendedEnd = uint64(block.timestamp + maxLockDuration);
        veToken.extendLock(veId, extendedEnd);

        userLock = veToken.locks(veId);
        assertEq(userLock.lockAmount(), 3e18);
        assertEq(userLock.lockEnd(), extendedEnd);
        bytes32 extendedLockId = keccak256(abi.encode(address(veToken), salt, extendedEnd));
        (saved,) = core.savedBalances(address(ve33), address(stakeToken), address(type(uint160).max), lockId);
        assertEq(saved, 0);
        (saved,) = core.savedBalances(address(ve33), address(stakeToken), address(type(uint160).max), extendedLockId);
        assertEq(saved, 3e18);

        vm.expectRevert(VE33.InvalidLock.selector);
        veToken.withdrawLock(veId);
        vm.warp(extendedEnd);
        assertEq(veToken.votingPower(veId), 0);
        uint256 balanceBefore = stakeToken.balanceOf(address(this));
        veToken.withdrawLock(veId);

        assertEq(stakeToken.balanceOf(address(this)), balanceBefore + 3e18);
        (saved,) = core.savedBalances(address(ve33), address(stakeToken), address(type(uint160).max), extendedLockId);
        assertEq(saved, 0);
        vm.expectRevert(VeToken.InvalidLock.selector);
        veToken.ownerOf(veId);
    }

    function test_onlyOwnerCanUpdateLock() public {
        uint256 veId = veToken.createLock(1e18, uint64(block.timestamp + veToken.MAX_LOCK_DURATION()));
        address operator = address(1234);
        stakeToken.transfer(operator, 1e18);

        vm.startPrank(operator);
        stakeToken.approve(address(veToken), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(VeToken.NotAuthorizedForToken.selector, operator, veId));
        veToken.increaseLockAmount(veId, 1e18);
        vm.stopPrank();

        assertEq(veToken.locks(veId).lockAmount(), 1e18);
    }
}
