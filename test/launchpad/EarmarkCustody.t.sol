// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../TestToken.sol";
import {RevenueAllocator} from "../../src/launchpad/RevenueAllocator.sol";
import {TreasuryVault} from "../../src/launchpad/TreasuryVault.sol";
import {EarmarkVault} from "../../src/launchpad/EarmarkVault.sol";
import {HolderVault} from "../../src/launchpad/HolderVault.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @dev Custody separation: the treasury owner has no path into earmark vaults, and vice versa.
contract EarmarkCustodyTest is Test {
    address treasuryOwner = makeAddr("treasuryOwner");
    address vaultOwner = makeAddr("vaultOwner");
    address executor = makeAddr("executor");
    address constant OPS = address(0x0505);

    TreasuryVault treasury;
    RevenueAllocator allocator;
    TestToken token;

    function setUp() public {
        treasury = new TreasuryVault(treasuryOwner);
        allocator = new RevenueAllocator(vaultOwner, treasury, OPS);
        vm.prank(treasuryOwner);
        treasury.setDepositor(address(allocator), true);
        token = new TestToken(address(this));
        token.transfer(address(allocator), 100_000);
        allocator.allocate(address(token));
    }

    function _vaults() internal view returns (EarmarkVault[3] memory vaults) {
        vaults[0] = allocator.HOLDER_VAULT();
        vaults[1] = allocator.RUNR_VAULT();
        vaults[2] = allocator.ECO_VAULT();
    }

    function test_treasuryOwnerCannotTouchEarmarkVaults() public {
        EarmarkVault[3] memory vaults = _vaults();
        for (uint256 i = 0; i < vaults.length; i++) {
            uint256 held = token.balanceOf(address(vaults[i]));
            assertGt(held, 0);
            vm.prank(treasuryOwner);
            vm.expectRevert(Ownable.Unauthorized.selector);
            vaults[i].withdraw(address(token), treasuryOwner, held);
            vm.prank(treasuryOwner);
            vm.expectRevert(EarmarkVault.AllocatorOnly.selector);
            vaults[i].deposit(address(token), 1);
            assertEq(token.balanceOf(address(vaults[i])), held);
        }
    }

    function test_treasuryLedgerCannotReachEarmarkedFunds() public {
        // The treasury only holds its own 25% leg; withdrawing more than booked fails.
        uint256 booked = treasury.ledger(address(token), TreasuryVault.Category.UNRESTRICTED);
        assertEq(booked, 25_000);
        assertEq(token.balanceOf(address(treasury)), booked);
        vm.prank(treasuryOwner);
        vm.expectRevert(TreasuryVault.InsufficientLedger.selector);
        treasury.withdraw(address(token), TreasuryVault.Category.UNRESTRICTED, treasuryOwner, booked + 1);
        vm.prank(treasuryOwner);
        vm.expectRevert(TreasuryVault.InsufficientLedger.selector);
        treasury.withdraw(address(token), TreasuryVault.Category.RUNR_BUYBACK, treasuryOwner, 1);
        vm.prank(treasuryOwner);
        treasury.withdraw(address(token), TreasuryVault.Category.UNRESTRICTED, treasuryOwner, booked);
        assertEq(token.balanceOf(treasuryOwner), booked);
    }

    function test_vaultOwnerReleasesToExecutor() public {
        EarmarkVault runr = allocator.RUNR_VAULT();
        assertEq(runr.received(address(token)), 30_000);
        vm.prank(vaultOwner);
        vm.expectRevert(EarmarkVault.InvalidRecipient.selector);
        runr.withdraw(address(token), address(0), 1);
        vm.prank(vaultOwner);
        vm.expectEmit(true, true, false, true, address(runr));
        emit EarmarkVault.Withdrawn(address(token), executor, 12_000);
        runr.withdraw(address(token), executor, 12_000);
        assertEq(token.balanceOf(executor), 12_000);
        assertEq(runr.withdrawn(address(token)), 12_000);
        assertEq(runr.received(address(token)), 30_000);
    }

    function test_vaultOwnerCannotTouchTreasury() public {
        vm.prank(vaultOwner);
        vm.expectRevert(Ownable.Unauthorized.selector);
        treasury.withdraw(address(token), TreasuryVault.Category.UNRESTRICTED, vaultOwner, 1);
        vm.prank(vaultOwner);
        vm.expectRevert(TreasuryVault.DepositorOnly.selector);
        treasury.deposit(address(token), TreasuryVault.Category.UNRESTRICTED, 1);
    }

    function test_treasuryReclassifyAndOwnerDeposit() public {
        token.transfer(treasuryOwner, 500);
        vm.startPrank(treasuryOwner);
        token.approve(address(treasury), 500);
        treasury.deposit(address(token), TreasuryVault.Category.BOND, 500);
        treasury.reclassify(address(token), TreasuryVault.Category.BOND, TreasuryVault.Category.ECO_BUYBACK, 200);
        vm.expectRevert(TreasuryVault.InsufficientLedger.selector);
        treasury.reclassify(address(token), TreasuryVault.Category.BOND, TreasuryVault.Category.ECO_BUYBACK, 301);
        vm.expectRevert(TreasuryVault.InvalidRecipient.selector);
        treasury.withdraw(address(token), TreasuryVault.Category.BOND, address(0), 1);
        vm.stopPrank();
        assertEq(treasury.ledger(address(token), TreasuryVault.Category.BOND), 300);
        assertEq(treasury.ledger(address(token), TreasuryVault.Category.ECO_BUYBACK), 200);
        assertEq(token.balanceOf(address(treasury)), 25_500);
    }

    function test_holderVaultHasNoClaimEntryPoint() public {
        HolderVault holders = allocator.HOLDER_VAULT();
        (bool success,) = address(holders).call(abi.encodeWithSignature("claim(address)", address(token)));
        assertFalse(success);
        assertEq(holders.received(address(token)), 20_000);
    }
}
