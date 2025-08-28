// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {FullTest} from "./FullTest.sol";
import {
    TokenWrapperLib,
    WrappedTokenMinter,
    WrappedTokenBurner,
    TokenWrapperFactory,
    TokenWrapper
} from "../src/TokenWrapper.sol";
import {toDate, toQuarter} from "../src/libraries/TimeDescriptor.sol";
import {TestToken} from "./TestToken.sol";

contract TokenWrapperTest is FullTest {
    using TokenWrapperLib for TokenWrapper;

    TokenWrapperFactory factory;
    WrappedTokenMinter minter;
    WrappedTokenBurner burner;
    TestToken underlying;

    address user = makeAddr("user");

    function setUp() public override {
        FullTest.setUp();
        underlying = new TestToken(address(this));
        underlying.transfer(user, 100e18);
        factory = new TokenWrapperFactory(core);
        minter = new WrappedTokenMinter(core);
        burner = new WrappedTokenBurner(core);
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
        underlying.approve(address(minter), wrapAmount);
        if (wrapAmount > underlying.balanceOf(user)) {
            vm.expectRevert();
            minter.wrap(wrapper, wrapAmount);
        } else {
            minter.wrap(wrapper, wrapAmount);
            assertEq(wrapper.balanceOf(user), wrapAmount, "Didn't mint wrapper");
            assertEq(underlying.balanceOf(address(core)), wrapAmount, "Didn't transfer underlying");
        }
    }

    function testWrapGas() public {
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), 0);
        vm.startPrank(user);
        underlying.approve(address(minter), 1);
        vm.cool(address(factory.implementation()));
        vm.cool(address(wrapper));
        vm.cool(address(underlying));
        vm.cool(address(user));
        minter.wrap(wrapper, 1);
        vm.snapshotGasLastCall("wrap");
    }

    function testUnwrapTo(address recipient, uint128 wrapAmount, uint128 unwrapAmount, uint256 time) public {
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), 1755616480);
        wrapAmount = uint128(bound(wrapAmount, 0, underlying.balanceOf(user)));

        vm.startPrank(user);
        underlying.approve(address(minter), wrapAmount);
        minter.wrap(wrapper, wrapAmount);
        uint256 oldBalance = underlying.balanceOf(recipient);

        wrapper.approve(address(burner), wrapAmount);

        vm.warp(time);
        if (time < wrapper.unlockTime() || unwrapAmount > wrapAmount) {
            vm.expectRevert();
            burner.unwrap(wrapper, recipient, unwrapAmount);
            return;
        }
        burner.unwrap(wrapper, recipient, unwrapAmount);
        assertEq(wrapper.balanceOf(user), wrapAmount - unwrapAmount, "Didn't burn wrapper");
        assertEq(underlying.balanceOf(recipient), oldBalance + unwrapAmount, "Didn't transfer underlying");
    }

    function testUnwrapGas() public {
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), 0);

        vm.startPrank(user);
        underlying.approve(address(minter), 1);
        minter.wrap(wrapper, 1);
        wrapper.approve(address(burner), 1);
        assertEq(wrapper.allowance(user, address(burner)), 1);

        vm.cool(address(factory.implementation()));
        vm.cool(address(wrapper));
        vm.cool(address(underlying));
        vm.cool(address(user));
        burner.unwrap(wrapper, 1);
        vm.snapshotGasLastCall("unwrap");
    }
}
