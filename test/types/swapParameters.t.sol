// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
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

    function test_conversionFromAndTo(SqrtRatio sqrtRatioLimit, int128 amount, bool isToken1, uint256 skipAhead)
        public
        pure
    {
        skipAhead = bound(skipAhead, 0, type(uint32).max >> 1);
        SwapParameters params = createSwapParameters({
            _sqrtRatioLimit: sqrtRatioLimit,
            _amount: amount,
            _isToken1: isToken1,
            _skipAhead: skipAhead
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
            _sqrtRatioLimit: sqrtRatioLimit,
            _amount: amount,
            _isToken1: isToken1,
            _skipAhead: skipAhead
        });
        assertEq(SqrtRatio.unwrap(params.sqrtRatioLimit()), SqrtRatio.unwrap(sqrtRatioLimit), "sqrtRatioLimit");
        assertEq(params.amount(), amount, "amount");
        assertEq(params.isToken1(), isToken1, "isToken1");
        assertEq(params.skipAhead(), skipAhead, "skipAhead");
    }
}
