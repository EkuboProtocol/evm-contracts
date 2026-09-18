// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../TestToken.sol";
import {RevenueAllocator} from "../../src/launchpad/RevenueAllocator.sol";
import {TreasuryVault} from "../../src/launchpad/TreasuryVault.sol";
import {EarmarkVault} from "../../src/launchpad/EarmarkVault.sol";

contract RevenueAllocatorTest is Test {
    address treasuryOwner = makeAddr("treasuryOwner");
    address vaultOwner = makeAddr("vaultOwner");
    address constant OPS = address(0x0505);

    TreasuryVault treasury;
    RevenueAllocator allocator;
    TestToken tokenA;
    TestToken tokenB;

    function setUp() public {
        treasury = new TreasuryVault(treasuryOwner);
        allocator = new RevenueAllocator(vaultOwner, treasury, OPS);
        vm.prank(treasuryOwner);
        treasury.setDepositor(address(allocator), true);
        tokenA = new TestToken(address(this));
        tokenB = new TestToken(address(this));
    }

    function _legs(address token) internal view returns (uint256 t, uint256 h, uint256 r, uint256 e, uint256 o) {
        t = treasury.ledger(token, TreasuryVault.Category.UNRESTRICTED);
        h = allocator.HOLDER_VAULT().received(token);
        r = allocator.RUNR_VAULT().received(token);
        e = allocator.ECO_VAULT().received(token);
        o = TestToken(token).balanceOf(OPS);
    }

    function test_wiring() public view {
        assertEq(allocator.HOLDER_VAULT().ALLOCATOR(), address(allocator));
        assertEq(allocator.RUNR_VAULT().ALLOCATOR(), address(allocator));
        assertEq(allocator.ECO_VAULT().ALLOCATOR(), address(allocator));
        assertEq(allocator.HOLDER_VAULT().owner(), vaultOwner);
        assertEq(allocator.RUNR_VAULT().owner(), vaultOwner);
        assertEq(allocator.ECO_VAULT().owner(), vaultOwner);
        assertEq(allocator.RUNR_VAULT().PURPOSE(), bytes32("RUNR buyback"));
        assertEq(allocator.ECO_VAULT().PURPOSE(), bytes32("Ecosystem buyback"));
        assertEq(allocator.HOLDER_VAULT().PURPOSE(), bytes32("RUNR holders"));
        assertEq(
            allocator.TREASURY_BPS() + allocator.HOLDER_BPS() + allocator.RUNR_BUYBACK_BPS() + allocator.ECO_BPS()
                + allocator.OPS_BPS(),
            allocator.BPS()
        );
    }

    function test_constructorRejectsZeroDestinations() public {
        vm.expectRevert(RevenueAllocator.InvalidDestination.selector);
        new RevenueAllocator(vaultOwner, TreasuryVault(address(0)), OPS);
        vm.expectRevert(RevenueAllocator.InvalidDestination.selector);
        new RevenueAllocator(vaultOwner, treasury, address(0));
    }

    function testFuzz_allocateConservesAndRoundsToTreasury(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        tokenA.transfer(address(allocator), amount);
        assertEq(allocator.pending(address(tokenA)), amount);
        allocator.allocate(address(tokenA));
        (uint256 t, uint256 h, uint256 r, uint256 e, uint256 o) = _legs(address(tokenA));
        assertEq(t + h + r + e + o, amount, "conservation");
        assertEq(h, amount * 2000 / 10_000);
        assertEq(r, amount * 3000 / 10_000);
        assertEq(e, amount * 1500 / 10_000);
        assertEq(o, amount * 1000 / 10_000);
        assertGe(t, amount * 2500 / 10_000);
        assertLe(t - amount * 2500 / 10_000, 4, "dust bound");
        assertEq(tokenA.balanceOf(address(allocator)), 0);
        assertEq(allocator.pending(address(tokenA)), 0);
        assertEq(tokenA.balanceOf(address(treasury)), t);
        assertEq(tokenA.balanceOf(address(allocator.HOLDER_VAULT())), h);
        assertEq(tokenA.balanceOf(address(allocator.RUNR_VAULT())), r);
        assertEq(tokenA.balanceOf(address(allocator.ECO_VAULT())), e);
        RevenueAllocator.Totals memory totals = allocator.totals(address(tokenA));
        assertEq(totals.treasury, t);
        assertEq(totals.holders, h);
        assertEq(totals.runrBuyback, r);
        assertEq(totals.ecosystem, e);
        assertEq(totals.ops, o);
    }

    function test_roundingRemainderGoesToTreasury() public {
        RevenueAllocator.Totals memory legs = allocator.split(10_001);
        assertEq(legs.holders, 2000);
        assertEq(legs.runrBuyback, 3000);
        assertEq(legs.ecosystem, 1500);
        assertEq(legs.ops, 1000);
        assertEq(legs.treasury, 2501);
        legs = allocator.split(1);
        assertEq(legs.treasury, 1);
        assertEq(legs.holders + legs.runrBuyback + legs.ecosystem + legs.ops, 0);
    }

    function test_allocateTracksTotalsPerTokenAcrossCalls() public {
        tokenA.transfer(address(allocator), 10_000);
        allocator.allocate(address(tokenA));
        tokenA.transfer(address(allocator), 30_000);
        allocator.allocate(address(tokenA));
        tokenB.transfer(address(allocator), 100);
        allocator.allocate(address(tokenB));
        RevenueAllocator.Totals memory a = allocator.totals(address(tokenA));
        RevenueAllocator.Totals memory b = allocator.totals(address(tokenB));
        assertEq(a.treasury, 10_000);
        assertEq(a.holders, 8000);
        assertEq(a.runrBuyback, 12_000);
        assertEq(a.ecosystem, 6000);
        assertEq(a.ops, 4000);
        assertEq(b.treasury, 25);
        assertEq(b.holders, 20);
        assertEq(b.runrBuyback, 30);
        assertEq(b.ecosystem, 15);
        assertEq(b.ops, 10);
        assertEq(treasury.ledger(address(tokenA), TreasuryVault.Category.UNRESTRICTED), 10_000);
        assertEq(treasury.ledger(address(tokenB), TreasuryVault.Category.UNRESTRICTED), 25);
    }

    function test_allocateNothingReverts() public {
        vm.expectRevert(RevenueAllocator.NothingToAllocate.selector);
        allocator.allocate(address(tokenA));
    }

    function test_allocateRequiresTreasuryDepositorRole() public {
        vm.prank(treasuryOwner);
        treasury.setDepositor(address(allocator), false);
        tokenA.transfer(address(allocator), 10_000);
        vm.expectRevert(TreasuryVault.DepositorOnly.selector);
        allocator.allocate(address(tokenA));
    }

    function test_allocateEmitsPerLegAmounts() public {
        tokenA.transfer(address(allocator), 10_000);
        vm.expectEmit(true, false, false, true, address(allocator));
        emit RevenueAllocator.Allocated(address(tokenA), 10_000, 2500, 2000, 3000, 1500, 1000);
        allocator.allocate(address(tokenA));
    }
}
