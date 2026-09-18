// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../TestToken.sol";
import {BondDepository} from "../../src/launchpad/BondDepository.sol";
import {TreasuryVault} from "../../src/launchpad/TreasuryVault.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract BondDepositoryTest is Test {
    address user = makeAddr("user");
    TestToken runr;
    TestToken asset;
    TreasuryVault treasury;
    BondDepository depository;

    uint256 constant FUNDED = 1_000_000e18;
    uint128 constant PRICE = 2e18; // 2 RUNR per asset unit
    uint128 constant CAPACITY = 500_000e18;
    uint32 constant VESTING = 30 days;

    function setUp() public {
        vm.warp(1_000_000);
        runr = new TestToken(address(this));
        asset = new TestToken(address(this));
        treasury = new TreasuryVault(address(this));
        depository = new BondDepository(address(this), address(runr), treasury);
        treasury.setDepositor(address(depository), true);
        runr.approve(address(depository), type(uint256).max);
        depository.fund(FUNDED);
        depository.configure(address(asset), true, PRICE, CAPACITY, VESTING);
        asset.transfer(user, type(uint128).max);
        vm.prank(user);
        asset.approve(address(depository), type(uint256).max);
    }

    function _deposit(uint256 amount) internal returns (uint256 id) {
        vm.prank(user);
        id = depository.deposit(address(asset), amount, 0);
    }

    function test_setUp() public view {
        assertEq(depository.inventory(), FUNDED);
        assertEq(depository.owed(), 0);
        (bool enabled, uint128 price, uint128 capacity, uint32 vesting) = depository.markets(address(asset));
        assertTrue(enabled);
        assertEq(price, PRICE);
        assertEq(capacity, CAPACITY);
        assertEq(vesting, VESTING);
    }

    function testFuzz_depositVestClaim(uint128 amount, uint32 elapsed) public {
        amount = uint128(bound(amount, 1, CAPACITY / 2));
        elapsed = uint32(bound(elapsed, 0, 2 * VESTING));
        uint128 payout = uint128(uint256(amount) * 2);
        uint256 id = _deposit(amount);
        BondDepository.Bond memory bond = depository.getBond(id);
        assertEq(bond.owner, user);
        assertEq(bond.payout, payout);
        assertEq(bond.start, block.timestamp);
        assertEq(bond.duration, VESTING);
        assertEq(treasury.ledger(address(asset), TreasuryVault.Category.BOND), amount);
        assertEq(asset.balanceOf(address(treasury)), amount);
        assertEq(asset.balanceOf(address(depository)), 0);
        assertEq(depository.owed(), payout);
        assertEq(depository.inventory(), FUNDED - payout);
        (,, uint128 capacity,) = depository.markets(address(asset));
        assertEq(capacity, CAPACITY - payout);

        vm.warp(block.timestamp + elapsed);
        uint128 expected = elapsed >= VESTING ? payout : uint128(uint256(payout) * elapsed / VESTING);
        assertEq(depository.claimable(id), expected);
        if (expected == 0) {
            vm.prank(user);
            vm.expectRevert(BondDepository.NothingToClaim.selector);
            depository.claim(id);
        } else {
            vm.prank(user);
            assertEq(depository.claim(id), expected);
        }
        assertEq(runr.balanceOf(user), expected);

        vm.warp(bond.start + VESTING);
        if (expected < payout) {
            vm.prank(user);
            depository.claim(id);
        }
        assertEq(runr.balanceOf(user), payout);
        assertEq(depository.owed(), 0);
        assertEq(depository.claimable(id), 0);
        vm.prank(user);
        vm.expectRevert(BondDepository.NothingToClaim.selector);
        depository.claim(id);
    }

    function testFuzz_payoutMath(uint256 amount, uint128 price) public {
        price = uint128(bound(price, 1, type(uint128).max));
        amount = bound(amount, 0, type(uint128).max);
        depository.configure(address(asset), true, price, CAPACITY, VESTING);
        assertEq(depository.payoutFor(address(asset), amount), uint128(amount * price / 1e18));
    }

    function test_capacityEnforcedAcrossDeposits() public {
        _deposit(CAPACITY / 2);
        (,, uint128 capacity,) = depository.markets(address(asset));
        assertEq(capacity, 0);
        vm.prank(user);
        vm.expectRevert(BondDepository.CapacityExceeded.selector);
        depository.deposit(address(asset), 1e18, 0);
        vm.prank(user);
        vm.expectRevert(BondDepository.CapacityExceeded.selector);
        depository.deposit(address(asset), 1, 0);
    }

    function test_inventoryBacksEveryBond() public {
        depository.configure(address(asset), true, PRICE, type(uint128).max, VESTING);
        vm.prank(user);
        vm.expectRevert(BondDepository.InsufficientInventory.selector);
        depository.deposit(address(asset), FUNDED / 2 + 1, 0);
        _deposit(FUNDED / 2);
        assertEq(depository.inventory(), 0);
        vm.prank(user);
        vm.expectRevert(BondDepository.InsufficientInventory.selector);
        depository.deposit(address(asset), 1, 0);
        vm.expectRevert(BondDepository.InsufficientInventory.selector);
        depository.withdrawInventory(address(this), 1);
        depository.fund(10e18);
        depository.withdrawInventory(address(this), 10e18);
        assertEq(depository.inventory(), 0);
    }

    function test_hardCapsOnConfiguration() public {
        vm.expectRevert(BondDepository.InvalidVesting.selector);
        depository.configure(address(asset), true, PRICE, CAPACITY, 1 days - 1);
        vm.expectRevert(BondDepository.InvalidVesting.selector);
        depository.configure(address(asset), true, PRICE, CAPACITY, 365 days + 1);
        vm.expectRevert(BondDepository.InvalidMarket.selector);
        depository.configure(address(runr), true, PRICE, CAPACITY, VESTING);
        vm.expectRevert(BondDepository.InvalidMarket.selector);
        depository.configure(address(0), true, PRICE, CAPACITY, VESTING);
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        depository.configure(address(asset), true, PRICE, CAPACITY, VESTING);
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        depository.setPaused(true);
        vm.prank(user);
        vm.expectRevert(Ownable.Unauthorized.selector);
        depository.withdrawInventory(user, 1);
        depository.configure(address(asset), true, PRICE, CAPACITY, 1 days);
        depository.configure(address(asset), true, PRICE, CAPACITY, 365 days);
    }

    function test_depositGuards() public {
        vm.prank(user);
        vm.expectRevert(BondDepository.ZeroPayout.selector);
        depository.deposit(address(asset), 0, 0);
        vm.prank(user);
        vm.expectRevert(BondDepository.PayoutBelowMinimum.selector);
        depository.deposit(address(asset), 1e18, 2e18 + 1);
        vm.prank(user);
        vm.expectRevert(BondDepository.MarketDisabled.selector);
        depository.deposit(address(runr), 1e18, 0);
        depository.configure(address(asset), false, PRICE, CAPACITY, VESTING);
        vm.prank(user);
        vm.expectRevert(BondDepository.MarketDisabled.selector);
        depository.deposit(address(asset), 1e18, 0);
    }

    function test_pauseBlocksDepositsNotClaims() public {
        uint256 id = _deposit(1e18);
        depository.setPaused(true);
        vm.prank(user);
        vm.expectRevert(BondDepository.Paused.selector);
        depository.deposit(address(asset), 1e18, 0);
        vm.warp(block.timestamp + VESTING);
        vm.prank(user);
        assertEq(depository.claim(id), 2e18);
        depository.setPaused(false);
        _deposit(1e18);
    }

    function test_onlyBondOwnerClaims() public {
        uint256 id = _deposit(1e18);
        vm.warp(block.timestamp + VESTING);
        vm.expectRevert(BondDepository.BondOwnerOnly.selector);
        depository.claim(id);
        vm.expectRevert(BondDepository.BondOwnerOnly.selector);
        depository.claim(id + 1);
    }

    function test_noMintingPath() public {
        (bool success,) = address(depository).call(abi.encodeWithSignature("mint(address,uint256)", user, 1));
        assertFalse(success);
        assertEq(runr.totalSupply(), type(uint256).max);
    }

    function test_treasuryDepositorRoleRequired() public {
        treasury.setDepositor(address(depository), false);
        vm.prank(user);
        vm.expectRevert(TreasuryVault.DepositorOnly.selector);
        depository.deposit(address(asset), 1e18, 0);
    }
}
