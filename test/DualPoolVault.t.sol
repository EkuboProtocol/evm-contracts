// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {FullTest} from "./FullTest.sol";
import {DualPoolVault} from "../src/examples/DualPoolVault.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolConfig, createStableswapPoolConfig} from "../src/types/poolConfig.sol";
import {PoolAllocation} from "../src/types/vaultTypes.sol";
import {TestToken} from "./TestToken.sol";

contract DualPoolVaultTest is FullTest {
    DualPoolVault vault;
    TestToken token2;

    address alice = makeAddr("alice");

    uint256 constant MIN_EPOCH_DURATION = 1 hours;

    function setUp() public override {
        super.setUp();

        // Create a third token for the second pool
        token2 = new TestToken(address(this));

        // Create vault with token0 as deposit token
        vault = new DualPoolVault(
            core,
            owner,
            address(token0),
            MIN_EPOCH_DURATION
        );

        // Give Alice tokens
        token0.transfer(alice, 1_000_000 ether);

        // Approve vault for deposits
        vm.prank(alice);
        token0.approve(address(vault), type(uint256).max);
    }

    function createPool(address tokenA, address tokenB) internal returns (PoolKey memory poolKey) {
        // Ensure token0 < token1 ordering
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        PoolConfig config = createStableswapPoolConfig(1 << 63, 10, 0, address(0));
        poolKey = PoolKey({token0: t0, token1: t1, config: config});
        core.initializePool(poolKey, 0);
    }

    // ============ Basic Configuration Tests ============

    function test_name_returnsCorrectName() public view {
        assertEq(vault.name(), "Dual Pool Ekubo Vault");
    }

    function test_symbol_returnsCorrectSymbol() public view {
        assertEq(vault.symbol(), "dpEKV");
    }

    function test_isFullyConfigured_falseInitially() public view {
        assertFalse(vault.isFullyConfigured());
    }

    // ============ Pool Configuration Tests ============

    function test_setPool0_onlyOwner() public {
        PoolKey memory poolKey = createPool(address(token0), address(token1));

        vm.prank(alice);
        vm.expectRevert();
        vault.setPool0(poolKey, 5000);
    }

    function test_setPool0_revertsIfNoDepositToken() public {
        PoolKey memory poolKey = createPool(address(token1), address(token2));

        vm.prank(owner);
        vm.expectRevert(DualPoolVault.PoolMustContainDepositToken.selector);
        vault.setPool0(poolKey, 5000);
    }

    function test_setPool0_success() public {
        PoolKey memory poolKey = createPool(address(token0), address(token1));

        vm.prank(owner);
        vault.setPool0(poolKey, 10000);

        (PoolKey memory storedKey, uint256 targetBps, bool isSet) = vault.getPool0();
        assertEq(storedKey.token0, poolKey.token0);
        assertEq(storedKey.token1, poolKey.token1);
        assertEq(targetBps, 10000);
        assertTrue(isSet);
    }

    function test_setPool1_success() public {
        PoolKey memory poolKey = createPool(address(token0), address(token2));

        vm.prank(owner);
        vault.setPool1(poolKey, 10000);

        (PoolKey memory storedKey, uint256 targetBps, bool isSet) = vault.getPool1();
        assertEq(storedKey.token0, poolKey.token0);
        assertEq(storedKey.token1, poolKey.token1);
        assertEq(targetBps, 10000);
        assertTrue(isSet);
    }

    function test_setPool0AndPool1_mustSum100() public {
        PoolKey memory poolKey0 = createPool(address(token0), address(token1));
        PoolKey memory poolKey1 = createPool(address(token0), address(token2));

        vm.startPrank(owner);
        vault.setPool0(poolKey0, 6000);

        vm.expectRevert(DualPoolVault.AllocationsMustSum100Percent.selector);
        vault.setPool1(poolKey1, 3000); // 6000 + 3000 != 10000

        vault.setPool1(poolKey1, 4000); // 6000 + 4000 = 10000
        vm.stopPrank();

        assertTrue(vault.isFullyConfigured());
    }

    function test_isFullyConfigured_trueWhenBothSet() public {
        PoolKey memory poolKey0 = createPool(address(token0), address(token1));
        PoolKey memory poolKey1 = createPool(address(token0), address(token2));

        vm.startPrank(owner);
        vault.setPool0(poolKey0, 5000);
        vault.setPool1(poolKey1, 5000);
        vm.stopPrank();

        assertTrue(vault.isFullyConfigured());
    }

    // ============ Allocation Update Tests ============

    function test_setAllocations_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.setAllocations(5000, 5000);
    }

    function test_setAllocations_revertsIfPoolNotSet() public {
        vm.prank(owner);
        vm.expectRevert(DualPoolVault.PoolNotSet.selector);
        vault.setAllocations(5000, 5000);
    }

    function test_setAllocations_success() public {
        PoolKey memory poolKey0 = createPool(address(token0), address(token1));
        PoolKey memory poolKey1 = createPool(address(token0), address(token2));

        vm.startPrank(owner);
        vault.setPool0(poolKey0, 5000);
        vault.setPool1(poolKey1, 5000);

        // Update allocations
        vault.setAllocations(7000, 3000);
        vm.stopPrank();

        (, uint256 bps0,) = vault.getPool0();
        (, uint256 bps1,) = vault.getPool1();
        assertEq(bps0, 7000);
        assertEq(bps1, 3000);
    }

    function test_setAllocations_mustSum100() public {
        PoolKey memory poolKey0 = createPool(address(token0), address(token1));
        PoolKey memory poolKey1 = createPool(address(token0), address(token2));

        vm.startPrank(owner);
        vault.setPool0(poolKey0, 5000);
        vault.setPool1(poolKey1, 5000);

        vm.expectRevert(DualPoolVault.AllocationsMustSum100Percent.selector);
        vault.setAllocations(6000, 3000);
        vm.stopPrank();
    }

    // ============ Target Allocations Tests ============

    function test_getTargetAllocations_emptyWhenNoPools() public view {
        PoolAllocation[] memory allocations = vault.getTargetAllocations();
        assertEq(allocations.length, 0);
    }

    function test_getTargetAllocations_onePoolWhenOnlyPool0Set() public {
        PoolKey memory poolKey0 = createPool(address(token0), address(token1));

        vm.prank(owner);
        vault.setPool0(poolKey0, 10000);

        PoolAllocation[] memory allocations = vault.getTargetAllocations();
        assertEq(allocations.length, 1);
        assertEq(allocations[0].targetBps, 10000);
    }

    function test_getTargetAllocations_twoPoolsWhenBothSet() public {
        PoolKey memory poolKey0 = createPool(address(token0), address(token1));
        PoolKey memory poolKey1 = createPool(address(token0), address(token2));

        vm.startPrank(owner);
        vault.setPool0(poolKey0, 6000);
        vault.setPool1(poolKey1, 4000);
        vm.stopPrank();

        PoolAllocation[] memory allocations = vault.getTargetAllocations();
        assertEq(allocations.length, 2);
        assertEq(allocations[0].targetBps, 6000);
        assertEq(allocations[1].targetBps, 4000);
    }

    function test_getTargetAllocations_skipsZeroAllocation() public {
        PoolKey memory poolKey0 = createPool(address(token0), address(token1));
        PoolKey memory poolKey1 = createPool(address(token0), address(token2));

        vm.startPrank(owner);
        vault.setPool0(poolKey0, 5000);
        vault.setPool1(poolKey1, 5000);
        // Set pool0 to 0, pool1 to 100%
        vault.setAllocations(0, 10000);
        vm.stopPrank();

        PoolAllocation[] memory allocations = vault.getTargetAllocations();
        assertEq(allocations.length, 1);
        assertEq(allocations[0].targetBps, 10000);
    }

    // ============ Full Cycle Tests ============

    function test_fullCycle_dualPoolDepositWithdraw() public {
        PoolKey memory poolKey0 = createPool(address(token0), address(token1));
        PoolKey memory poolKey1 = createPool(address(token0), address(token2));

        vm.startPrank(owner);
        vault.setPool0(poolKey0, 6000);
        vault.setPool1(poolKey1, 4000);
        vm.stopPrank();

        uint256 depositAmount = 1000 ether;

        // Alice deposits
        vm.prank(alice);
        vault.queueDeposit(depositAmount);

        // Process epoch
        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        // Claim shares
        vm.prank(alice);
        uint256 shares = vault.claimShares(0);
        assertGt(shares, 0);

        // Queue withdrawal
        vm.prank(alice);
        vault.queueWithdraw(shares);

        // Process withdrawal epoch
        skip(MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        // Claim withdrawal
        uint256 balanceBefore = token0.balanceOf(alice);
        vm.prank(alice);
        uint256 withdrawnAmount = vault.claimWithdrawal(1);

        // Should get back approximately the deposit amount
        assertApproxEqRel(withdrawnAmount, depositAmount, 0.05e18);
        assertEq(token0.balanceOf(alice), balanceBefore + withdrawnAmount);
    }
}
