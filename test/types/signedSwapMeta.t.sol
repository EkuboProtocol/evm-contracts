// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {SignedSwapMeta, createSignedSwapMeta, authorizedLocker, isExpired} from "../../src/types/signedSwapMeta.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract SignedSwapMetaTest is Test {
    function test_pack_unpack(address authorized, uint32 deadlineValue, uint32 feeValue, uint32 nonceValue)
        public
        pure
    {
        SignedSwapMeta meta = createSignedSwapMeta(authorized, deadlineValue, feeValue, nonceValue);

        assertEq(meta.authorizedLocker(), authorized);
        assertEq(meta.deadline(), deadlineValue);
        assertEq(meta.fee(), feeValue);
        assertEq(meta.nonce(), nonceValue);
    }

    function test_isExpired_matchesCurrentGtDeadline_withinSignedWindow(uint256 current, uint256 deadline) public pure {
        current = bound(current, 0, type(uint256).max - type(uint32).max);
        deadline = bound(
            deadline, FixedPointMathLib.zeroFloorSub(current, 1 << 31), current + uint256(int256(type(int32).max))
        );

        SignedSwapMeta meta = createSignedSwapMeta(address(0), uint32(deadline), 0, 0);
        assertEq(meta.isExpired(uint32(current)), current > deadline);
    }

    function test_isExpired_true_whenDeadlineFarAheadBeyondInt32Window() public pure {
        SignedSwapMeta meta = createSignedSwapMeta(address(0), 3_124_842_406, 0, 0);
        assertTrue(meta.isExpired(16));
    }
}
