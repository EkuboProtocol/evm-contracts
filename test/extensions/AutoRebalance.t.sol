// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {AutoRebalance, autoRebalanceCallPoints} from "../../src/extensions/AutoRebalance.sol";
import {PoolConfig} from "../../src/types/poolConfig.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {createSwapParameters} from "../../src/types/swapParameters.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";

contract AutoRebalanceTest is FullTest {
    using CoreLib for *;

    AutoRebalance internal autoRebalance;
    PoolKey internal poolKey;

    function setUp() public override {
        FullTest.setUp();

        address deployAddress = address(uint160(autoRebalanceCallPoints().toUint8()) << 152);
        deployCodeTo(
            "AutoRebalance.sol",
            abi.encode(
                core,
                address(token0),
                address(token1),
                uint64(0),
                uint32(100),
                uint32(2),
                int32(0),
                uint64(5_000),
                address(this),
                "Auto USDC/USDT",
                "ausd"
            ),
            deployAddress
        );
        autoRebalance = AutoRebalance(deployAddress);

        (address poolToken0, address poolToken1, PoolConfig config) = autoRebalance.POOL_KEY();
        poolKey = PoolKey({token0: poolToken0, token1: poolToken1, config: config});

        token0.approve(address(autoRebalance), type(uint256).max);
        token1.approve(address(autoRebalance), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);
    }

    function test_registers_and_extension_initializes_pool() public {
        vm.expectRevert(AutoRebalance.InvalidPoolConfig.selector);
        core.initializePool(poolKey, 0);

        autoRebalance.initializePool();
        PoolState state = core.poolState(poolKey.toPoolId());
        assertTrue(state.isInitialized());
        assertEq(state.tick(), 0);
        assertEq(autoRebalance.lastProcessedBlock(), block.number);
    }

    function test_contribution_mints_claimable_shares_next_block() public {
        autoRebalance.initializePool();

        uint256 contributionId = autoRebalance.contribute(1_000_000, 1_000_000, address(this), 0, 0);
        assertEq(autoRebalance.balanceOf(address(this)), 0);
        assertEq(autoRebalance.balanceOf(address(autoRebalance)), 0);
        assertEq(autoRebalance.activeLiquidity(), 0);

        vm.roll(block.number + 1);
        uint256 shares = autoRebalance.claimContribution(contributionId);

        assertGt(shares, 0);
        assertEq(autoRebalance.balanceOf(address(this)), shares);
        assertEq(autoRebalance.balanceOf(address(autoRebalance)), 0);
        assertGt(autoRebalance.activeLiquidity(), 0);
    }

    function test_direct_position_updates_are_disabled() public {
        autoRebalance.initializePool();

        vm.expectRevert(AutoRebalance.UnauthorizedPositionUpdate.selector);
        positions.mintAndDeposit(poolKey, -200, 200, 1_000, 1_000, 0);
    }

    function test_direct_router_swaps_are_disabled() public {
        _bootstrap();

        vm.expectRevert(AutoRebalance.DirectSwapDisabled.selector);
        router.swap(poolKey, createSwapParameters(SqrtRatio.wrap(0), 10, false, 0), 0);
    }

    function test_extension_swap_works() public {
        _bootstrap();

        uint256 token1Before = token1.balanceOf(address(this));
        PoolBalanceUpdate balanceUpdate =
            autoRebalance.swap(createSwapParameters(SqrtRatio.wrap(0), 10, false, 0), 0, address(this));

        assertEq(balanceUpdate.delta0(), 10);
        assertLt(balanceUpdate.delta1(), 0);
        assertGt(token1.balanceOf(address(this)), token1Before);
    }

    function test_withdraw_returns_assets_and_burns_shares() public {
        uint256 shares = _bootstrap();

        uint256 token0Before = token0.balanceOf(address(this));
        uint256 token1Before = token1.balanceOf(address(this));
        (uint128 amount0, uint128 amount1) = autoRebalance.withdraw(shares, 0, 0, address(this));

        assertEq(autoRebalance.balanceOf(address(this)), 0);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertEq(token0.balanceOf(address(this)), token0Before + amount0);
        assertEq(token1.balanceOf(address(this)), token1Before + amount1);
    }

    function test_single_sided_contribution_stays_idle_and_withdrawable() public {
        autoRebalance.initializePool();

        uint256 contributionId = autoRebalance.contribute(1_000_000, 0, address(this), 0, 0);
        vm.roll(block.number + 1);
        uint256 shares = autoRebalance.claimContribution(contributionId);

        assertEq(autoRebalance.activeLiquidity(), 0);
        assertEq(autoRebalance.idle0(), 1_000_000);
        assertEq(autoRebalance.idle1(), 0);

        (uint128 amount0, uint128 amount1) = autoRebalance.withdraw(shares, 0, 0, address(this));
        assertEq(amount0, 1_000_000);
        assertEq(amount1, 0);
    }

    function test_contribution_cap_is_relative_to_active_liquidity() public {
        _bootstrap();

        vm.expectRevert(AutoRebalance.ContributionTooLarge.selector);
        autoRebalance.contribute(2_000_000, 2_000_000, address(this), 0, 0);
    }

    function test_accepted_contribution_cannot_be_refunded_after_deadline() public {
        autoRebalance.initializePool();

        uint256 contributionId =
            autoRebalance.contribute(1_000_000, 1_000_000, address(this), 0, uint64(block.number + 2));
        vm.roll(block.number + 1);
        uint256 shares = autoRebalance.processPending(contributionId);
        assertGt(shares, 0);

        vm.roll(block.number + 2);
        vm.expectRevert(AutoRebalance.ContributionNotEligible.selector);
        autoRebalance.refundContribution(contributionId);

        assertEq(autoRebalance.claimContribution(contributionId), shares);
    }

    function _bootstrap() private returns (uint256 shares) {
        autoRebalance.initializePool();
        uint256 contributionId = autoRebalance.contribute(1_000_000, 1_000_000, address(this), 0, 0);
        vm.roll(block.number + 1);
        shares = autoRebalance.claimContribution(contributionId);
    }
}
