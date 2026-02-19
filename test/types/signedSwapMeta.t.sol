// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    SignedSwapMeta,
    createSignedSwapMeta,
    authorizedLocker,
    deadline,
    fee,
    nonce,
    parseSignedSwapMeta,
    isNotExpired
} from "../../src/types/signedSwapMeta.sol";

contract SignedSwapMetaTest is Test {
    function test_pack_unpack(address authorized, uint32 deadlineValue, uint32 feeValue, uint32 nonceValue)
        public
        pure
    {
        SignedSwapMeta meta = createSignedSwapMeta(authorized, deadlineValue, feeValue, nonceValue);

        assertEq(authorizedLocker(meta), authorized);
        assertEq(deadline(meta), deadlineValue);
        assertEq(fee(meta), feeValue);
        assertEq(nonce(meta), nonceValue);

        (address parsedAuthorized, uint32 parsedDeadline, uint32 parsedFee, uint32 parsedNonce) =
            parseSignedSwapMeta(meta);
        assertEq(parsedAuthorized, authorized);
        assertEq(parsedDeadline, deadlineValue);
        assertEq(parsedFee, feeValue);
        assertEq(parsedNonce, nonceValue);
    }

    function test_isNotExpired_without_wrap() public pure {
        SignedSwapMeta meta = createSignedSwapMeta(address(0), 1000, 0, 0);
        assertTrue(isNotExpired(meta, 999));
        assertTrue(isNotExpired(meta, 1000));
        assertFalse(isNotExpired(meta, 1001));
    }

    function test_isNotExpired_with_wrap() public pure {
        SignedSwapMeta metaFuture = createSignedSwapMeta(address(0), 3, 0, 0);
        assertTrue(isNotExpired(metaFuture, type(uint32).max - 5));

        SignedSwapMeta metaPast = createSignedSwapMeta(address(0), type(uint32).max - 5, 0, 0);
        assertFalse(isNotExpired(metaPast, 3));
    }
}
