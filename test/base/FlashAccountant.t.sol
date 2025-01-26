// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {FlashAccountant} from "../../src/base/FlashAccountant.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {Core} from "../../src/Core.sol";

contract ExampleLocker is BaseLocker {
    constructor(ICore core) BaseLocker(core) {}

    function handleLockData(bytes memory data) internal pure override returns (bytes memory result) {}
}

contract Target is FlashAccountant {
    function getLocker() external view returns (uint256 id, address locker) {
        (id, locker) = _getLocker();
    }
}

contract FlashAccountantTest is Test {
    Target public target;

    function setUp() public {
        target = new Target();
    }
}
