// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FullTest} from "./FullTest.sol";
import {RouterTest} from "./Router.t.sol";
import {MEVCapture, mevCaptureCallPoints} from "../src/extensions/MEVCapture.sol";
import {MEVCaptureRouter} from "../src/MEVCaptureRouter.sol";
import {BaseMEVCaptureTest} from "./extensions/MEVCapture.t.sol";

// makes sure all the same tests pass for the mev router
contract MEVCaptureRouterTest is RouterTest, BaseMEVCaptureTest {
    function setUp() public override(BaseMEVCaptureTest, FullTest) {
        BaseMEVCaptureTest.setUp();
    }

    function coolAllContracts() internal virtual override(FullTest, BaseMEVCaptureTest) {
        BaseMEVCaptureTest.coolAllContracts();
    }
}
