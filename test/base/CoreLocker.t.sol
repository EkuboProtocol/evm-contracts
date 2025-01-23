// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoreLocker} from "../../src/base/CoreLocker.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {Core} from "../../src/Core.sol";

contract Target is CoreLocker {
    function pay() external payable {}

    constructor(ICore core) CoreLocker(core) {}

    function handleLockData(bytes calldata) internal pure override returns (bytes memory) {
        revert();
    }
}

contract CoreLockerTest is Test {
    Core public core;
    Target public target;

    function setUp() public {
        core = new Core(address(0xdeadbeef), type(uint256).max);
        target = new Target(core);
    }

    function test_refundNativeETH() public {
        uint256 b = address(this).balance;
        target.pay{value: 100}();
        assertEq(address(this).balance, b - 100);
        target.refundNativeToken();
        assertEq(b, address(this).balance);
    }

    receive() external payable {}
}
