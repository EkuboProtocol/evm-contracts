// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {BaseOrdersTest} from "./Orders.t.sol";
import {PositionsOwner} from "../src/PositionsOwner.sol";
import {RevenueBuybacks} from "../src/RevenueBuybacks.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {PoolKey, toConfig} from "../src/types/poolKey.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {TestToken} from "./TestToken.sol";

contract PositionsOwnerTest is BaseOrdersTest {
    using CoreLib for *;

    PositionsOwner positionsOwner;
    RevenueBuybacks rb;
    TestToken buybacksToken;

    function setUp() public override {
        BaseOrdersTest.setUp();
        buybacksToken = new TestToken(address(this));

        // make it so buybacksToken is always greatest
        if (address(buybacksToken) < address(token1)) {
            (token1, buybacksToken) = (buybacksToken, token1);
        }

        if (address(token1) < address(token0)) {
            (token0, token1) = (token1, token0);
        }

        // Create the revenue buybacks contract
        rb = new RevenueBuybacks(address(this), orders, address(buybacksToken));

        // Create the positions owner contract
        positionsOwner = new PositionsOwner(address(this), positions);

        // Transfer ownership of positions to the positions owner
        vm.prank(positions.owner());
        positions.transferOwnership(address(positionsOwner));
    }

    // increases the saved balance of the core contract to simulate protocol fees
    function donateViaCore(address token0, address token1, uint128 amount0, uint128 amount1) internal {
        (uint128 amount0Old, uint128 amount1Old) = positions.getProtocolFees(token0, token1);

        vm.store(
            address(core),
            CoreLib.savedBalancesSlot(address(positions), token0, token1, bytes32(0)),
            bytes32(((uint256(amount0Old + amount0) << 128)) | uint256(amount1Old + amount1))
        );

        if (token0 == address(0)) {
            vm.deal(address(core), amount0);
        } else {
            TestToken(token0).transfer(address(core), amount0);
        }
        TestToken(token1).transfer(address(core), amount1);
    }

    function test_setUp_token_order() public view {
        assertGt(uint160(address(token1)), uint160(address(token0)));
        assertGt(uint160(address(buybacksToken)), uint160(address(token1)));
    }

    function test_positions_ownership_transferred() public view {
        assertEq(positions.owner(), address(positionsOwner));
    }

    function test_transfer_positions_ownership() public {
        address newOwner = address(0xdeadbeef);
        positionsOwner.transferPositionsOwnership(newOwner);
        assertEq(positions.owner(), newOwner);
    }

    function test_transfer_positions_ownership_fails_if_not_owner() public {
        vm.prank(address(0xdeadbeef));
        vm.expectRevert(Ownable.Unauthorized.selector);
        positionsOwner.transferPositionsOwnership(address(0x1234));
    }

    function test_withdraw_and_roll_fails_if_no_tokens_configured() public {
        donateViaCore(address(token0), address(token1), 1e18, 1e18);

        vm.expectRevert(PositionsOwner.RevenueTokenNotConfigured.selector);
        positionsOwner.withdrawAndRoll(rb, address(token0), address(token1));
    }

    function test_withdraw_to_contract_fails_if_no_tokens_configured() public {
        donateViaCore(address(token0), address(token1), 1e18, 1e18);

        vm.expectRevert(PositionsOwner.RevenueTokenNotConfigured.selector);
        positionsOwner.withdrawToContract(rb, address(token0), address(token1));
    }

    function test_withdraw_and_roll_with_token0_configured() public {
        uint64 poolFee = uint64((uint256(1) << 64) / 100); // 1%

        // Configure token0 for buybacks
        rb.configure({token: address(token0), targetOrderDuration: 3600, minOrderDuration: 1800, fee: poolFee});
        rb.approveMax(address(token0));

        // Set up the pool
        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(buybacksToken),
            config: toConfig({_extension: address(twamm), _fee: poolFee, _tickSpacing: 0})
        });

        positions.maybeInitializePool(poolKey, 0);
        token0.approve(address(positions), 1e18);
        buybacksToken.approve(address(positions), 1e18);
        positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);

        // Donate protocol fees
        donateViaCore(address(token0), address(token1), 1e18, 1e17);

        // Check initial balances
        assertEq(token0.balanceOf(address(rb)), 0);
        assertEq(token1.balanceOf(address(rb)), 0);

        // Withdraw and roll
        positionsOwner.withdrawAndRoll(rb, address(token0), address(token1));

        // Check that token0 was transferred to buybacks contract and used for order
        assertEq(token0.balanceOf(address(rb)), 0); // Should be 0 because it was used for the order
        assertEq(token1.balanceOf(address(rb)), 1e17); // token1 should be transferred but not used
    }

    function test_withdraw_and_roll_with_both_tokens_configured() public {
        uint64 poolFee = uint64((uint256(1) << 64) / 100); // 1%

        // Configure both tokens for buybacks
        rb.configure({token: address(token0), targetOrderDuration: 3600, minOrderDuration: 1800, fee: poolFee});
        rb.configure({token: address(token1), targetOrderDuration: 3600, minOrderDuration: 1800, fee: poolFee});
        rb.approveMax(address(token0));
        rb.approveMax(address(token1));

        // Set up pools for both tokens
        PoolKey memory poolKey0 = PoolKey({
            token0: address(token0),
            token1: address(buybacksToken),
            config: toConfig({_extension: address(twamm), _fee: poolFee, _tickSpacing: 0})
        });

        PoolKey memory poolKey1 = PoolKey({
            token0: address(token1),
            token1: address(buybacksToken),
            config: toConfig({_extension: address(twamm), _fee: poolFee, _tickSpacing: 0})
        });

        positions.maybeInitializePool(poolKey0, 0);
        positions.maybeInitializePool(poolKey1, 0);

        token0.approve(address(positions), 1e18);
        token1.approve(address(positions), 1e18);
        buybacksToken.approve(address(positions), 2e18);

        positions.mintAndDeposit(poolKey0, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);
        positions.mintAndDeposit(poolKey1, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);

        // Donate protocol fees
        donateViaCore(address(token0), address(token1), 1e18, 1e18);

        // Withdraw and roll
        positionsOwner.withdrawAndRoll(rb, address(token0), address(token1));

        // Both tokens should have been used for orders
        assertEq(token0.balanceOf(address(rb)), 0);
        assertEq(token1.balanceOf(address(rb)), 0);
    }

    function test_withdraw_to_contract_without_roll() public {
        uint64 poolFee = uint64((uint256(1) << 64) / 100); // 1%

        // Configure token0 for buybacks
        rb.configure({token: address(token0), targetOrderDuration: 3600, minOrderDuration: 1800, fee: poolFee});

        // Donate protocol fees
        donateViaCore(address(token0), address(token1), 1e18, 1e17);

        // Check initial balances
        assertEq(token0.balanceOf(address(rb)), 0);
        assertEq(token1.balanceOf(address(rb)), 0);

        // Withdraw to contract without rolling
        positionsOwner.withdrawToContract(rb, address(token0), address(token1));

        // Check that tokens were transferred but no orders were created
        assertEq(token0.balanceOf(address(rb)), 1e18);
        assertEq(token1.balanceOf(address(rb)), 1e17);
    }

    function test_roll_tokens_separately() public {
        uint64 poolFee = uint64((uint256(1) << 64) / 100); // 1%

        // Configure token0 for buybacks
        rb.configure({token: address(token0), targetOrderDuration: 3600, minOrderDuration: 1800, fee: poolFee});
        rb.approveMax(address(token0));

        // Set up the pool
        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(buybacksToken),
            config: toConfig({_extension: address(twamm), _fee: poolFee, _tickSpacing: 0})
        });

        positions.maybeInitializePool(poolKey, 0);
        token0.approve(address(positions), 1e18);
        buybacksToken.approve(address(positions), 1e18);
        positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);

        // Transfer tokens directly to buybacks contract
        token0.transfer(address(rb), 1e18);
        token1.transfer(address(rb), 1e17);

        // Check initial balances
        assertEq(token0.balanceOf(address(rb)), 1e18);
        assertEq(token1.balanceOf(address(rb)), 1e17);

        // Roll tokens - anyone can call this
        vm.prank(address(0xdeadbeef));
        positionsOwner.rollTokens(rb, address(token0), address(token1));

        // Check that token0 was used for order, token1 was not
        assertEq(token0.balanceOf(address(rb)), 0);
        assertEq(token1.balanceOf(address(rb)), 1e17);
    }

    function test_no_fees_to_withdraw() public {
        uint64 poolFee = uint64((uint256(1) << 64) / 100); // 1%

        // Configure token0 for buybacks
        rb.configure({token: address(token0), targetOrderDuration: 3600, minOrderDuration: 1800, fee: poolFee});

        // No protocol fees donated, so nothing should happen
        positionsOwner.withdrawAndRoll(rb, address(token0), address(token1));

        // Balances should remain zero
        assertEq(token0.balanceOf(address(rb)), 0);
        assertEq(token1.balanceOf(address(rb)), 0);
    }
}
