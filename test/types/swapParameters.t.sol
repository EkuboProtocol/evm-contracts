// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

import {Test} from "forge-std/Test.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../../src/types/sqrtRatio.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {isPriceIncreasing} from "../../src/math/isPriceIncreasing.sol";

contract SwapParametersTest is Test {
    function test_conversionToAndFrom(SwapParameters params) public pure {
        assertEq(
            SwapParameters.unwrap(
                createSwapParameters({
                    _sqrtRatioLimit: params.sqrtRatioLimit(),
                    _amount: params.amount(),
                    _isToken1: params.isToken1(),
                    _skipAhead: params.skipAhead()
                })
            ),
            SwapParameters.unwrap(params)
        );
    }

    function test_isExactOut(SwapParameters params) public pure {
        assertEq(params.isExactOut(), params.amount() < 0);
    }

    function test_isPriceIncreasing(SwapParameters params) public pure {
        assertEq(params.isPriceIncreasing(), isPriceIncreasing(params.amount(), params.isToken1()));
    }

    function test_withDefaultSqrtRatioLimit_does_not_replace_params(SwapParameters params) public pure {
        SwapParameters updated = params.withDefaultSqrtRatioLimit();
        assertEq(updated.amount(), params.amount(), "amount");
        assertEq(updated.isToken1(), params.isToken1(), "isToken1");
        assertEq(updated.skipAhead(), params.skipAhead(), "skipAhead");
        if (params.sqrtRatioLimit().isZero()) {
            assertEq(
                updated.sqrtRatioLimit().toFixed(),
                params.isPriceIncreasing() ? MAX_SQRT_RATIO.toFixed() : MIN_SQRT_RATIO.toFixed(),
                "sqrt ratio limit is updated"
            );
        } else {
            assertEq(
                updated.sqrtRatioLimit().toFixed(), params.sqrtRatioLimit().toFixed(), "sqrt ratio limit is not updated"
            );
        }
    }

    function test_withDefaultSqrtRatioLimit() public pure {
        assertEq(
            createSwapParameters({_amount: 1, _isToken1: false, _skipAhead: 0, _sqrtRatioLimit: SqrtRatio.wrap(0)})
                .withDefaultSqrtRatioLimit().sqrtRatioLimit().toFixed(),
            MIN_SQRT_RATIO.toFixed()
        );
        assertEq(
            createSwapParameters({_amount: 1, _isToken1: true, _skipAhead: 0, _sqrtRatioLimit: SqrtRatio.wrap(0)})
                .withDefaultSqrtRatioLimit().sqrtRatioLimit().toFixed(),
            MAX_SQRT_RATIO.toFixed()
        );
        assertEq(
            createSwapParameters({_amount: -1, _isToken1: false, _skipAhead: 0, _sqrtRatioLimit: SqrtRatio.wrap(0)})
                .withDefaultSqrtRatioLimit().sqrtRatioLimit().toFixed(),
            MAX_SQRT_RATIO.toFixed()
        );
        assertEq(
            createSwapParameters({_amount: -1, _isToken1: true, _skipAhead: 0, _sqrtRatioLimit: SqrtRatio.wrap(0)})
                .withDefaultSqrtRatioLimit().sqrtRatioLimit().toFixed(),
            MIN_SQRT_RATIO.toFixed()
        );
    }

    function test_conversionFromAndTo(SqrtRatio sqrtRatioLimit, int128 amount, bool isToken1, uint256 skipAhead)
        public
        pure
    {
        skipAhead = bound(skipAhead, 0, type(uint32).max >> 1);
        SwapParameters params = createSwapParameters({
            _sqrtRatioLimit: sqrtRatioLimit, _amount: amount, _isToken1: isToken1, _skipAhead: skipAhead
        });
        assertEq(SqrtRatio.unwrap(params.sqrtRatioLimit()), SqrtRatio.unwrap(sqrtRatioLimit));
        assertEq(params.amount(), amount);
        assertEq(params.isToken1(), isToken1);
        assertEq(params.skipAhead(), skipAhead);
    }

    function test_conversionFromAndToDirtyBits(
        bytes32 sqrtRatioLimitDirty,
        bytes32 amountDirty,
        bytes32 isToken1Dirty,
        bytes32 skipAheadDirty
    ) public pure {
        SqrtRatio sqrtRatioLimit;
        int128 amount;
        bool isToken1;
        uint256 skipAhead;

        assembly ("memory-safe") {
            sqrtRatioLimit := sqrtRatioLimitDirty
            amount := amountDirty
            isToken1 := isToken1Dirty
            skipAhead := skipAheadDirty
        }

        vm.assume(skipAhead <= 0xFFFFFF);

        SwapParameters params = createSwapParameters({
            _sqrtRatioLimit: sqrtRatioLimit, _amount: amount, _isToken1: isToken1, _skipAhead: skipAhead
        });
        assertEq(SqrtRatio.unwrap(params.sqrtRatioLimit()), SqrtRatio.unwrap(sqrtRatioLimit), "sqrtRatioLimit");
        assertEq(params.amount(), amount, "amount");
        assertEq(params.isToken1(), isToken1, "isToken1");
        assertEq(params.skipAhead(), skipAhead, "skipAhead");
    }
}
