// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {BaseURLTokenURIGenerator} from "../src/BaseURLTokenURIGenerator.sol";

contract BaseURLTokenURIGeneratorTest is Test {
    function test_concatenatesBaseUrl() public {
        BaseURLTokenURIGenerator b = new BaseURLTokenURIGenerator(address(this), "this is a string: ");
        assertEq(b.generateTokenURI(1234), "this is a string: 1234");
    }

    function test_canChangeBaseURL() public {
        BaseURLTokenURIGenerator b = new BaseURLTokenURIGenerator(address(this), "this is a string: ");
        b.setBaseURL("hello world: ");
        assertEq(b.generateTokenURI(1234), "hello world: 1234");
    }

    function test_onlyOwnerCanChange() public {
        BaseURLTokenURIGenerator b = new BaseURLTokenURIGenerator(address(this), "this is a string: ");
        vm.prank(address(uint160(address(this)) + 1));
        vm.expectRevert(Ownable.Unauthorized.selector);
        b.setBaseURL("hello world: ");
    }

    function test_ownerCanPointAtNewImplementation() public {
        BaseURLTokenURIGenerator b = new BaseURLTokenURIGenerator(address(this), "this is a string: ");
        BaseURLTokenURIGenerator b2 = new BaseURLTokenURIGenerator(address(this), "version 2 of string: ");
        b.setReplacementContract(address(b2));
        assertEq(b.generateTokenURI(12345), "version 2 of string: 12345");
    }

    function test_onlyOwnerCanChangeReplacement() public {
        BaseURLTokenURIGenerator b = new BaseURLTokenURIGenerator(address(this), "this is a string: ");
        vm.prank(address(uint160(address(this)) + 1));
        vm.expectRevert(Ownable.Unauthorized.selector);
        b.setReplacementContract(address(0));
    }
}
