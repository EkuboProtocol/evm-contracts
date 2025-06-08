// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FullTest} from "./FullTest.sol";
import {RouterTest} from "./Router.t.sol";
import {MEVResist, mevResistCallPoints} from "../src/extensions/MEVResist.sol";
import {MEVResistRouter} from "../src/MEVResistRouter.sol";

// makes sure all the same tests pass for the mev router
contract MEVResistRouterTest is RouterTest {
    MEVResist mevResist;

    function setUp() public override {
        FullTest.setUp();
        address deployAddress = address(uint160(mevResistCallPoints().toUint8()) << 152);
        deployCodeTo("MEVResist.sol", abi.encode(core), deployAddress);
        mevResist = MEVResist(deployAddress);
        router = new MEVResistRouter(core, address(mevResist));
    }
}
