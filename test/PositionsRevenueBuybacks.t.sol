// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseOrdersTest} from "./Orders.t.sol";
import {PositionsRevenueBuybacks} from "../src/PositionsRevenueBuybacks.sol";
import {CoreStorageLayout} from "../src/libraries/CoreStorageLayout.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {createFullRangePoolConfig} from "../src/types/poolConfig.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {TestToken} from "./TestToken.sol";
import {StorageSlot} from "../src/types/storageSlot.sol";

contract PositionsRevenueBuybacksTest is BaseOrdersTest {
    PositionsRevenueBuybacks buybacks;
    TestToken buybacksToken;

    function setUp() public override {
        BaseOrdersTest.setUp();
        buybacksToken = new TestToken(address(this));

        if (address(buybacksToken) < address(token1)) {
            (token1, buybacksToken) = (buybacksToken, token1);
        }

        if (address(token1) < address(token0)) {
            (token0, token1) = (token1, token0);
        }

        buybacks = new PositionsRevenueBuybacks(address(this), positions, orders, address(buybacksToken));

        vm.prank(positions.owner());
        positions.transferOwnership(address(buybacks));
    }

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

    function configure(address token, uint32 targetOrderDuration, uint32 minOrderDuration, uint64 fee) internal {
        buybacks.configure(token, targetOrderDuration, minOrderDuration, fee);
    }

    function test_setUp_token_order() public view {
        assertGt(uint160(address(token1)), uint160(address(token0)));
        assertGt(uint160(address(buybacksToken)), uint160(address(token1)));
    }

    function test_positions_ownership_transferred() public view {
        assertEq(positions.owner(), address(buybacks));
    }

    function test_owner_can_transfer_positions_ownership_away() public {
        address newOwner = address(0xdeadbeef);

        buybacks.call(address(positions), 0, abi.encodeWithSelector(Ownable.transferOwnership.selector, newOwner));

        assertEq(positions.owner(), newOwner);
    }

    function test_withdraw_protocol_fees_leaves_tokens_if_not_configured() public {
        cheatDonateProtocolFees(address(token0), address(token1), 1e18, 2e18);

        buybacks.withdrawProtocolFees(address(token0), address(token1));
        assertEq(token0.balanceOf(address(buybacks)), 1e18 - 1);
        assertEq(token1.balanceOf(address(buybacks)), 2e18 - 1);
    }

    function test_withdraw_protocol_fees_can_be_called_before_roll() public {
        cheatDonateProtocolFees(address(token0), address(token1), 1e18, 2e18);

        (uint128 amount0, uint128 amount1) = buybacks.withdrawProtocolFees(address(token0), address(token1));
        assertEq(amount0, 1e18 - 1);
        assertEq(amount1, 2e18 - 1);
        assertEq(token0.balanceOf(address(buybacks)), 1e18 - 1);
        assertEq(token1.balanceOf(address(buybacks)), 2e18 - 1);

        (amount0, amount1) = positions.getProtocolFees(address(token0), address(token1));
        assertEq(amount0, 1);
        assertEq(amount1, 1);
    }

    function test_owner_can_collect_withdrawn_tokens() public {
        address recipient = address(0x1234);

        cheatDonateProtocolFees(address(token0), address(token1), 1e18, 2e18);
        buybacks.withdrawProtocolFees(address(token0), address(token1));

        assertEq(token0.balanceOf(address(buybacks)), 1e18 - 1);
        buybacks.call(
            address(token0), 0, abi.encodeWithSelector(token0.transfer.selector, recipient, uint256(1e18 - 1))
        );

        assertEq(token0.balanceOf(address(buybacks)), 0);
        assertEq(token0.balanceOf(recipient), 1e18 - 1);
    }

    function test_withdraw_protocol_fees_and_roll_with_one_token_configured() public {
        uint64 poolFee = uint64((uint256(1) << 64) / 100);

        configure(address(token0), 3600, 1800, poolFee);
        buybacks.approveMax(address(token0));

        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(buybacksToken),
            config: createFullRangePoolConfig({_extension: address(twamm), _fee: poolFee})
        });

        positions.maybeInitializePool(poolKey, 0);
        token0.approve(address(positions), 1e18);
        buybacksToken.approve(address(positions), 1e18);
        positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);

        cheatDonateProtocolFees(address(token0), address(token1), 1e18, 1e17);

        buybacks.withdrawProtocolFees(address(token0), address(token1));
        buybacks.roll(address(token0));
        assertEq(token0.balanceOf(address(buybacks)), 0);
        assertEq(token1.balanceOf(address(buybacks)), 1e17 - 1);
    }

    function test_withdraw_protocol_fees_and_roll_with_token1_configured() public {
        uint64 poolFee = uint64((uint256(1) << 64) / 100);

        configure(address(token1), 3600, 1800, poolFee);
        buybacks.approveMax(address(token1));

        PoolKey memory poolKey = PoolKey({
            token0: address(token1),
            token1: address(buybacksToken),
            config: createFullRangePoolConfig({_extension: address(twamm), _fee: poolFee})
        });

        positions.maybeInitializePool(poolKey, 0);
        token1.approve(address(positions), 1e18);
        buybacksToken.approve(address(positions), 1e18);
        positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);

        cheatDonateProtocolFees(address(token0), address(token1), 1e18, 1e17);

        buybacks.withdrawProtocolFees(address(token0), address(token1));
        buybacks.roll(address(token1));
    }

    function test_withdraw_protocol_fees_and_roll_with_both_tokens_configured(uint80 donate0, uint80 donate1) public {
        uint64 poolFee = uint64((uint256(1) << 64) / 100);

        configure(address(token0), 3600, 1800, poolFee);
        configure(address(token1), 3600, 1800, poolFee);
        buybacks.approveMax(address(token0));
        buybacks.approveMax(address(token1));

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

        cheatDonateProtocolFees(address(token0), address(token1), donate0, donate1);

        (fees0, fees1) = positions.getProtocolFees(address(token0), address(token1));
        assertEq(fees0, donate0);
        assertEq(fees1, donate1);

        buybacks.withdrawProtocolFees(address(token0), address(token1));
        buybacks.roll(address(token0));
        buybacks.roll(address(token1));

        (fees0, fees1) = positions.getProtocolFees(address(token0), address(token1));
        assertEq(fees0, donate0 == 0 ? 0 : 1);
        assertEq(fees1, donate1 == 0 ? 0 : 1);

        assertLe(token0.balanceOf(address(buybacks)), 1);
        assertLe(token1.balanceOf(address(buybacks)), 1);
    }
}
