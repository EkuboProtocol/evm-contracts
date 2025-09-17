// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {CallPoints, addressToCallPoints} from "../../src/types/callPoints.sol";
import {ExtensionCallPointsLib} from "../../src/libraries/ExtensionCallPointsLib.sol";
import {IExtension} from "../../src/interfaces/ICore.sol";

contract ExtensionCallPointsLibTest is Test {
    using ExtensionCallPointsLib for *;

    function check_shouldCall(IExtension extension, address locker) public pure {
        CallPoints memory cp = addressToCallPoints(address(extension));
        bool skipSelfCall = address(extension) == locker;
        assertEq(extension.shouldCallBeforeInitializePool(locker), cp.beforeInitializePool && !skipSelfCall);
        assertEq(extension.shouldCallAfterInitializePool(locker), cp.afterInitializePool && !skipSelfCall);
        assertEq(extension.shouldCallBeforeSwap(locker), cp.beforeSwap && !skipSelfCall);
        assertEq(extension.shouldCallAfterSwap(locker), cp.afterSwap && !skipSelfCall);
        assertEq(extension.shouldCallBeforeUpdatePosition(locker), cp.beforeUpdatePosition && !skipSelfCall);
        assertEq(extension.shouldCallAfterUpdatePosition(locker), cp.afterUpdatePosition && !skipSelfCall);
        assertEq(extension.shouldCallBeforeCollectFees(locker), cp.beforeCollectFees && !skipSelfCall);
        assertEq(extension.shouldCallAfterCollectFees(locker), cp.afterCollectFees && !skipSelfCall);
    }
}
