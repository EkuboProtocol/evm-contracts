// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {
    SqrtRatio,
    MIN_SQRT_RATIO_RAW,
    MAX_SQRT_RATIO_RAW,
    TWO_POW_95,
    TWO_POW_94,
    TWO_POW_62,
    BIT_MASK
} from "../src/types/sqrtRatio.sol";
import {SwapParameters, createSwapParameters} from "../src/types/swapParameters.sol";

/// @notice Hands the swap parameters to Core exactly as given, so a zero limit is not replaced by the default.
contract RawLimitSwapper is BaseLocker {
    using CoreLib for *;
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function swap(PoolKey memory poolKey, SwapParameters params) external returns (PoolBalanceUpdate balanceUpdate) {
        balanceUpdate = abi.decode(lock(abi.encode(poolKey, params, msg.sender)), (PoolBalanceUpdate));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory poolKey, SwapParameters params, address payer) =
            abi.decode(data, (PoolKey, SwapParameters, address));

        (PoolBalanceUpdate balanceUpdate,) = ICore(payable(address(ACCOUNTANT))).swap(0, poolKey, params);

        if (balanceUpdate.delta0() > 0) {
            ACCOUNTANT.payFrom(payer, poolKey.token0, uint128(balanceUpdate.delta0()));
        } else if (balanceUpdate.delta0() < 0) {
            ACCOUNTANT.withdraw(poolKey.token0, payer, uint128(-balanceUpdate.delta0()));
        }

        if (balanceUpdate.delta1() > 0) {
            ACCOUNTANT.payFrom(payer, poolKey.token1, uint128(balanceUpdate.delta1()));
        } else if (balanceUpdate.delta1() < 0) {
            ACCOUNTANT.withdraw(poolKey.token1, payer, uint128(-balanceUpdate.delta1()));
        }

        return abi.encode(balanceUpdate);
    }
}

contract SqrtRatioLimitTest is FullTest {
    RawLimitSwapper internal swapper;
    PoolKey internal poolKey;

    function setUp() public override {
        FullTest.setUp();
        swapper = new RawLimitSwapper(core);
        token0.approve(address(swapper), type(uint256).max);
        token1.approve(address(swapper), type(uint256).max);

        poolKey = createPool({tick: 0, fee: 196, tickSpacingExp: 5});
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);
    }

    /// @dev The definition of a valid limit written out in plain arithmetic, independent of `isValid`.
    function isValidLimit(uint256 raw) internal pure returns (bool) {
        return raw >= MIN_SQRT_RATIO_RAW && raw <= MAX_SQRT_RATIO_RAW && (raw & ~uint256(BIT_MASK)) >= TWO_POW_62;
    }

    function params(uint96 limit, int128 amount, bool isToken1) internal pure returns (SwapParameters) {
        return createSwapParameters({
            _sqrtRatioLimit: SqrtRatio.wrap(limit), _amount: amount, _isToken1: isToken1, _skipAhead: 0, _minFee: 0
        });
    }

    function test_swap_reverts_for_invalid_limit() public {
        uint96[8] memory invalid = [
            uint96(0),
            1,
            MIN_SQRT_RATIO_RAW - 1,
            MAX_SQRT_RATIO_RAW + 1,
            type(uint96).max,
            // in range, but the mantissa is not normalized
            TWO_POW_94 + TWO_POW_62 - 1,
            TWO_POW_95 + TWO_POW_62 - 1,
            BIT_MASK + TWO_POW_62 - 1
        ];
        int128[3] memory amounts = [int128(1000), -1000, 0];

        for (uint256 i; i < invalid.length; i++) {
            assertFalse(isValidLimit(invalid[i]));
            for (uint256 j; j < amounts.length; j++) {
                vm.expectRevert(ICore.InvalidSqrtRatioLimit.selector);
                swapper.swap(poolKey, params(invalid[i], amounts[j], false));
                vm.expectRevert(ICore.InvalidSqrtRatioLimit.selector);
                swapper.swap(poolKey, params(invalid[i], amounts[j], true));
            }
        }
    }

    function test_swap_accepts_min_and_max_limits() public {
        // both bounds are inclusive, so the swap proceeds or fails only on direction
        PoolBalanceUpdate decreasing = swapper.swap(poolKey, params(MIN_SQRT_RATIO_RAW, 1000, false));
        assertEq(decreasing.delta0(), 1000);
        PoolBalanceUpdate increasing = swapper.swap(poolKey, params(MAX_SQRT_RATIO_RAW, 1000, true));
        assertEq(increasing.delta1(), 1000);

        vm.expectRevert(ICore.SqrtRatioLimitWrongDirection.selector);
        swapper.swap(poolKey, params(MAX_SQRT_RATIO_RAW, 1000, false));
        vm.expectRevert(ICore.SqrtRatioLimitWrongDirection.selector);
        swapper.swap(poolKey, params(MIN_SQRT_RATIO_RAW, 1000, true));
    }

    function test_swap_limit_validation(uint96 limit, uint8 shape, int128 amount, bool isToken1) public {
        amount = int128(bound(amount, -100_000, 100_000));
        shape %= 4;
        if (shape == 1) {
            // below the minimum
            limit = limit % MIN_SQRT_RATIO_RAW;
        } else if (shape == 2) {
            // above the maximum
            limit = MAX_SQRT_RATIO_RAW + 1 + limit % (type(uint96).max - MAX_SQRT_RATIO_RAW);
        } else if (shape == 3) {
            // mantissa below 2**62 in any of the four regions
            limit = (limit & BIT_MASK) | (limit % TWO_POW_62);
        }

        if (!isValidLimit(limit)) {
            vm.expectRevert(ICore.InvalidSqrtRatioLimit.selector);
            swapper.swap(poolKey, params(limit, amount, isToken1));
        } else {
            try swapper.swap(poolKey, params(limit, amount, isToken1)) {}
            catch (bytes memory revertData) {
                assertTrue(bytes4(revertData) != ICore.InvalidSqrtRatioLimit.selector, "valid limit rejected");
            }
        }
    }
}
