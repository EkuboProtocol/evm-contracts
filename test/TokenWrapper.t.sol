// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {FullTest} from "./FullTest.sol";
import {TokenWrapperFactory, TokenWrapper} from "../src/TokenWrapper.sol";
import {toDate, toQuarter} from "../src/libraries/TimeDescriptor.sol";
import {TestToken} from "./TestToken.sol";

contract TokenWrapperTest is FullTest {
    TokenWrapperFactory factory;
    TestToken underlying;

    address user = makeAddr("user");

    function setUp() public override {
        FullTest.setUp();
        underlying = new TestToken(address(this));
        underlying.transfer(user, 100e18);
        factory = new TokenWrapperFactory(core);
    }

    function testDeployWrapperGas() public {
        factory.deployWrapper(IERC20(address(underlying)), 1756140269);
        vm.snapshotGasLastCall("deployWrapper");
    }

    function testTokenInfo(uint256 time, uint64 unlockTime) public {
        time = bound(time, 0, type(uint64).max - type(uint32).max);
        vm.warp(time);
        unlockTime = uint64(bound(unlockTime, vm.getBlockTimestamp() + 1, vm.getBlockTimestamp() + type(uint32).max));

        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), unlockTime);

        assertEq(wrapper.symbol(), string.concat("gTT-", toQuarter(unlockTime)));
        assertEq(wrapper.name(), string.concat("TestToken ", toDate(unlockTime)));
        assertEq(wrapper.unlockTime(), unlockTime);
    }

    function testWrap(uint256 time, uint64 unlockTime, uint128 wrapAmount) public {
        vm.warp(time);
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), unlockTime);
        vm.startPrank(user);
        underlying.approve(address(wrapper), wrapAmount);
        if (wrapAmount > underlying.balanceOf(user)) {
            vm.expectRevert();
            wrapper.wrap(wrapAmount);
        } else {
            wrapper.wrap(wrapAmount);
            assertEq(wrapper.balanceOf(user), wrapAmount, "Didn't mint wrapper");
            assertEq(underlying.balanceOf(address(core)), wrapAmount, "Didn't transfer underlying");
        }
    }

    function testWrapGas() public {
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), 0);
        vm.startPrank(user);
        underlying.approve(address(wrapper), 1);
        vm.cool(address(factory.implementation()));
        vm.cool(address(wrapper));
        vm.cool(address(underlying));
        vm.cool(address(user));
        wrapper.wrap(1);
        vm.snapshotGasLastCall("wrap");
    }

    function testUnwrapTo(address recipient, uint128 wrapAmount, uint128 unwrapAmount, uint256 time) public {
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), 1755616480);
        wrapAmount = uint128(bound(wrapAmount, 0, underlying.balanceOf(user)));

        vm.startPrank(user);
        underlying.approve(address(wrapper), wrapAmount);
        wrapper.wrap(wrapAmount);
        uint256 oldBalance = underlying.balanceOf(recipient);

        vm.warp(time);
        if (time < wrapper.unlockTime() || unwrapAmount > wrapAmount) {
            vm.expectRevert();
            wrapper.unwrap(unwrapAmount);
            return;
        }
        wrapper.unwrapTo(recipient, unwrapAmount);
        assertEq(wrapper.balanceOf(user), wrapAmount - unwrapAmount, "Didn't burn wrapper");
        assertEq(underlying.balanceOf(recipient), oldBalance + unwrapAmount, "Didn't transfer underlying");
    }

    function testUnwrapGas() public {
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), 0);

        vm.startPrank(user);
        underlying.approve(address(wrapper), 1);
        wrapper.wrap(1);

        vm.cool(address(factory.implementation()));
        vm.cool(address(wrapper));
        vm.cool(address(underlying));
        vm.cool(address(user));
        wrapper.unwrapTo(user, 1);
        vm.snapshotGasLastCall("unwrap");
    }
}
