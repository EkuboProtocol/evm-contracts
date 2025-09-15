// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {FullTest} from "./FullTest.sol";
import {RouterTest} from "./Router.t.sol";
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
