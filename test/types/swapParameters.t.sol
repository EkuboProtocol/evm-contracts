// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {SwapParameters, createSwapParameters, SkipAheadTooLarge} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";

contract SwapParametersTest is Test {
    function test_conversionToAndFrom(SwapParameters params) public pure {
        // Filter out cases where skipAhead is too large or unused bits are set
        vm.assume(params.skipAhead() <= 0xFFFFFF);
        // Unused bits are bits 6-0, so mask them out
        vm.assume((uint256(SwapParameters.unwrap(params)) & 0x7F) == 0);
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

    function test_conversionFromAndTo(SqrtRatio sqrtRatioLimit, int128 amount, bool isToken1, uint24 skipAhead)
        public
        pure
    {
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

    /// forge-config: default.allow_internal_expect_revert = true
    function test_skipAheadTooLarge(uint256 skipAhead) public {
        vm.assume(skipAhead > 0xFFFFFF);
        vm.expectRevert(SkipAheadTooLarge.selector);
        createSwapParameters({_sqrtRatioLimit: SqrtRatio.wrap(0), _amount: 0, _isToken1: false, _skipAhead: skipAhead});
    }

    function test_parse(SqrtRatio sqrtRatioLimit, int128 amount, bool isToken1, uint24 skipAhead) public pure {
        SwapParameters params = createSwapParameters({
            _sqrtRatioLimit: sqrtRatioLimit,
            _amount: amount,
            _isToken1: isToken1,
            _skipAhead: skipAhead
        });
        (SqrtRatio r, int128 a, bool t, uint256 s) = params.parse();
        assertEq(SqrtRatio.unwrap(r), SqrtRatio.unwrap(sqrtRatioLimit), "sqrtRatioLimit");
        assertEq(a, amount, "amount");
        assertEq(t, isToken1, "isToken1");
        assertEq(s, skipAhead, "skipAhead");
    }
}
