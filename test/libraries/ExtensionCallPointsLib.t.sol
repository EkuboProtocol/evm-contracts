// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {CallPoints, addressToCallPoints} from "../../src/types/callPoints.sol";
import {ExtensionCallPointsLib} from "../../src/libraries/ExtensionCallPointsLib.sol";
import {IExtension} from "../../src/interfaces/ICore.sol";

contract ExtensionCallPointsLibTest is Test {
    using ExtensionCallPointsLib for *;

    function test_shouldCall(IExtension extension, address locker) public pure {
        CallPoints memory cp = addressToCallPoints(address(extension));
        assertEq(extension.shouldCallBeforeInitializePool(locker), cp.beforeInitializePool);
        assertEq(extension.shouldCallAfterInitializePool(locker), cp.afterInitializePool);
        assertEq(extension.shouldCallBeforeSwap(locker), cp.beforeSwap);
        assertEq(extension.shouldCallAfterSwap(locker), cp.afterSwap);
        assertEq(extension.shouldCallBeforeUpdatePosition(locker), cp.beforeUpdatePosition);
        assertEq(extension.shouldCallAfterUpdatePosition(locker), cp.afterUpdatePosition);
        assertEq(extension.shouldCallBeforeCollectFees(locker), cp.beforeCollectFees);
        assertEq(extension.shouldCallAfterCollectFees(locker), cp.afterCollectFees);
    }
}
