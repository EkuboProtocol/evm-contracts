// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FullTest} from "./FullTest.sol";
import {RouterTest} from "./Router.t.sol";
import {MEVResist, mevResistCallPoints} from "../src/extensions/MEVResist.sol";
import {MEVResistRouter} from "../src/MEVResistRouter.sol";
import {BaseMEVResistTest} from "./extensions/MEVResist.t.sol";

// makes sure all the same tests pass for the mev router
contract MEVResistRouterTest is RouterTest, BaseMEVResistTest {
    function setUp() public override(BaseMEVResistTest, FullTest) {
        BaseMEVResistTest.setUp();
    }
}
