// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

// CSO reproduction from EKU-661, inverted for EKU-723: it passes only when the theft fails.

import {LaunchRouterTest} from "./LaunchRouter.t.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {createSwapParameters} from "../src/types/swapParameters.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";

contract ReentrantReviewRecipient {
    LaunchRouter immutable router;
    PoolKey key;
    bool entered;

    constructor(LaunchRouter router_, PoolKey memory key_) {
        router = router_;
        key = key_;
    }

    receive() external payable {
        if (!entered) {
            entered = true;
            router.swap(key, createSwapParameters(SqrtRatio.wrap(0), 0, true, 0), 0, address(this), block.timestamp);
        }
    }
}

contract LaunchRouterSecurityReviewTest is LaunchRouterTest {
    function test_reviewRecipientCannotReceivePayerSurplus() public {
        (PoolKey memory key,) = _routerCreate(address(0), 0, 0);
        vm.warp(START + 100);
        vm.prank(PAYER);
        PoolBalanceUpdate bought = launchRouter.swap{value: 2 ether}(
            key, createSwapParameters(SqrtRatio.wrap(0), int128(2 ether), false, 0), 1, PAYER, block.timestamp
        );
        ReentrantReviewRecipient recipient = new ReentrantReviewRecipient(launchRouter, key);
        uint256 beforePayer = PAYER.balance;
        // The nested swap reverts with Reentrant, so the recipient's receive hook fails and Core's native
        // payout reverts the whole sell. Neither the output nor the payer's surplus reaches the recipient.
        vm.expectRevert(abi.encodeWithSignature("ETHTransferFailed()"));
        vm.prank(PAYER);
        launchRouter.swap{value: 1 ether}(
            key,
            createSwapParameters(SqrtRatio.wrap(0), -bought.delta1() / 2, true, 0),
            1,
            address(recipient),
            block.timestamp
        );
        assertEq(address(recipient).balance, 0);
        assertEq(PAYER.balance, beforePayer);
        assertEq(address(launchRouter).balance, 0);
    }
}
