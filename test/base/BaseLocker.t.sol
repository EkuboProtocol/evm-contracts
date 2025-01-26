// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {Core} from "../../src/Core.sol";

contract Target is BaseLocker {
    constructor(ICore core) BaseLocker(core) {}

    function pay() external payable {}

    function handleLockData(bytes memory) internal pure override returns (bytes memory) {
        revert();
    }
}

contract BaseLockerTest is Test {
    Core public core;
    Target public target;

    function setUp() public {
        core = new Core(address(0xdeadbeef), type(uint256).max);
        target = new Target(core);
    }

    receive() external payable {}
}
