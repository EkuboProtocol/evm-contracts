// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {BaseOrdersTest} from "./Orders.t.sol";
import {PositionsOwner} from "../src/PositionsOwner.sol";
import {RevenueBuybacks} from "../src/RevenueBuybacks.sol";
import {CoreStorageLayout} from "../src/libraries/CoreStorageLayout.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {createFullRangePoolConfig} from "../src/types/poolConfig.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {TestToken} from "./TestToken.sol";
import {StorageSlot} from "../src/types/storageSlot.sol";

contract PositionsOwnerTest is BaseOrdersTest {
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
        positionsOwner = new PositionsOwner(address(this), positions, rb);

        // Transfer ownership of positions to the positions owner
        vm.prank(positions.owner());
        positions.transferOwnership(address(positionsOwner));
    }

    // increases the saved balance of the core contract to simulate protocol fees
    function cheatDonateProtocolFees(address token0, address token1, uint128 amount0, uint128 amount1) internal {
        (uint128 amount0Old, uint128 amount1Old) = positions.getProtocolFees(token0, token1);

        vm.store(
            address(core),
            StorageSlot.unwrap(CoreStorageLayout.savedBalancesSlot(address(positions), token0, token1, bytes32(0))),
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
        cheatDonateProtocolFees(address(token0), address(token1), 1e18, 1e18);

        vm.expectRevert(PositionsOwner.RevenueTokenNotConfigured.selector);
        positionsOwner.withdrawAndRoll(address(token0), address(token1));
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
            config: createFullRangePoolConfig({_extension: address(twamm), _fee: poolFee})
        });

        positions.maybeInitializePool(poolKey, 0);
        token0.approve(address(positions), 1e18);
        buybacksToken.approve(address(positions), 1e18);
        positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);

        // Donate protocol fees
        cheatDonateProtocolFees(address(token0), address(token1), 1e18, 1e17);

        // Withdraw and roll
        vm.expectRevert(PositionsOwner.RevenueTokenNotConfigured.selector);
        positionsOwner.withdrawAndRoll(address(token0), address(token1));
    }

    function test_withdraw_and_roll_with_token1_configured() public {
        uint64 poolFee = uint64((uint256(1) << 64) / 100); // 1%

        // Configure token0 for buybacks
        rb.configure({token: address(token1), targetOrderDuration: 3600, minOrderDuration: 1800, fee: poolFee});
        rb.approveMax(address(token1));

        // Set up the pool
        PoolKey memory poolKey = PoolKey({
            token0: address(token1),
            token1: address(buybacksToken),
            config: createFullRangePoolConfig({_extension: address(twamm), _fee: poolFee})
        });

        positions.maybeInitializePool(poolKey, 0);
        token1.approve(address(positions), 1e18);
        buybacksToken.approve(address(positions), 1e18);
        positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);

        // Donate protocol fees
        cheatDonateProtocolFees(address(token0), address(token1), 1e18, 1e17);

        // Withdraw and roll
        vm.expectRevert(PositionsOwner.RevenueTokenNotConfigured.selector);
        positionsOwner.withdrawAndRoll(address(token0), address(token1));
    }

    function test_withdraw_and_roll_with_both_tokens_configured(uint80 donate0, uint80 donate1) public {
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
            config: createFullRangePoolConfig({_extension: address(twamm), _fee: poolFee})
        });

        PoolKey memory poolKey1 = PoolKey({
            token0: address(token1),
            token1: address(buybacksToken),
            config: createFullRangePoolConfig({_extension: address(twamm), _fee: poolFee})
        });

        positions.maybeInitializePool(poolKey0, 0);
        positions.maybeInitializePool(poolKey1, 0);

        token0.approve(address(positions), 1e18);
        token1.approve(address(positions), 1e18);
        buybacksToken.approve(address(positions), 2e18);

        positions.mintAndDeposit(poolKey0, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);
        positions.mintAndDeposit(poolKey1, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);

        (uint128 fees0, uint128 fees1) = positions.getProtocolFees(address(token0), address(token1));
        assertEq(fees0, 0);
        assertEq(fees1, 0);

        // Donate protocol fees
        cheatDonateProtocolFees(address(token0), address(token1), donate0, donate1);

        (fees0, fees1) = positions.getProtocolFees(address(token0), address(token1));
        assertEq(fees0, donate0);
        assertEq(fees1, donate1);

        // Withdraw and roll
        positionsOwner.withdrawAndRoll(address(token0), address(token1));

        (fees0, fees1) = positions.getProtocolFees(address(token0), address(token1));
        // it leaves 1 in there for gas efficiency
        assertEq(fees0, donate0 == 0 ? 0 : 1);
        assertEq(fees1, donate1 == 0 ? 0 : 1);

        // Both tokens should have been used for orders
        assertEq(token0.balanceOf(address(rb)), 0);
        assertEq(token1.balanceOf(address(rb)), 0);
    }
}
