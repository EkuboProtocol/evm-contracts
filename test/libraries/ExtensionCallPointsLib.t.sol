// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {CallPoints, addressToCallPoints} from "../../src/types/callPoints.sol";
import {ExtensionCallPointsLib} from "../../src/libraries/ExtensionCallPointsLib.sol";
import {IExtension} from "../../src/interfaces/ICore.sol";

contract ExtensionCallPointsLibTest is Test {
    using ExtensionCallPointsLib for *;

    function test_shouldCall(IExtension extension) public pure {
        CallPoints memory cp = addressToCallPoints(address(extension));
        assertEq(extension.shouldCallBeforeInitializePool(), cp.beforeInitializePool);
        assertEq(extension.shouldCallAfterInitializePool(), cp.afterInitializePool);
        assertEq(extension.shouldCallBeforeSwap(), cp.beforeSwap);
        assertEq(extension.shouldCallAfterSwap(), cp.afterSwap);
        assertEq(extension.shouldCallBeforeUpdatePosition(), cp.beforeUpdatePosition);
        assertEq(extension.shouldCallAfterUpdatePosition(), cp.afterUpdatePosition);
        assertEq(extension.shouldCallBeforeCollectFees(), cp.beforeCollectFees);
        assertEq(extension.shouldCallAfterCollectFees(), cp.afterCollectFees);
    }
}
