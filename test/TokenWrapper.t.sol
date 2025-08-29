// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {FullTest} from "./FullTest.sol";
import {TokenWrapper} from "../src/TokenWrapper.sol";
import {TokenWrapperFactory} from "../src/TokenWrapperFactory.sol";
import {TokenWrapperPeriphery} from "../src/TokenWrapperPeriphery.sol";
import {toDate, toQuarter} from "../src/libraries/TimeDescriptor.sol";
import {TestToken} from "./TestToken.sol";

contract TokenWrapperTest is FullTest {
    TokenWrapperFactory factory;
    TokenWrapperPeriphery periphery;
    TestToken underlying;

    function setUp() public override {
        FullTest.setUp();
        underlying = new TestToken(address(this));
        factory = new TokenWrapperFactory(core);
        periphery = new TokenWrapperPeriphery(core);
    }

    function coolAllContracts() internal virtual override {
        FullTest.coolAllContracts();
        vm.cool(address(underlying));
        vm.cool(address(factory));
        vm.cool(address(periphery));
        vm.cool(address(periphery));
    }

    function testDeployWrapperGas() public {
        factory.deployWrapper(IERC20(address(underlying)), 1756140269);
        vm.snapshotGasLastCall("deployWrapper");
    }

    function testTokenInfo(uint256 time, uint256 unlockTime) public {
        vm.warp(time);

        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), unlockTime);

        assertEq(wrapper.symbol(), string.concat("gTT-", toQuarter(unlockTime)));
        assertEq(wrapper.name(), string.concat("TestToken ", toDate(unlockTime)));
        assertEq(wrapper.unlockTime(), unlockTime);
        assertEq(address(wrapper.underlyingToken()), address(underlying));
    }

    function testWrap(uint256 time, uint64 unlockTime, uint128 wrapAmount) public {
        vm.warp(time);
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), unlockTime);

        underlying.approve(address(periphery), wrapAmount);
        if (wrapAmount > underlying.balanceOf(address(this))) {
            assertEq(wrapper.totalSupply(), 0);
            vm.expectRevert();
            periphery.wrap(wrapper, wrapAmount);
            assertEq(wrapper.totalSupply(), 0);
        } else {
            assertEq(wrapper.totalSupply(), 0);
            periphery.wrap(wrapper, wrapAmount);
            assertEq(wrapper.totalSupply(), wrapAmount);

            assertEq(wrapper.balanceOf(address(this)), wrapAmount, "Didn't mint wrapper");
            assertEq(underlying.balanceOf(address(core)), wrapAmount, "Didn't transfer underlying");
        }
    }

    function testWrapGas() public {
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), 0);
        underlying.approve(address(periphery), 1);
        coolAllContracts();
        vm.cool(address(wrapper));
        periphery.wrap(wrapper, 1);
        vm.snapshotGasLastCall("wrap");
    }

    function testUnwrapTo(address recipient, uint128 wrapAmount, uint128 unwrapAmount, uint256 time) public {
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), 1755616480);

        underlying.approve(address(periphery), wrapAmount);
        periphery.wrap(wrapper, wrapAmount);
        uint256 oldBalance = underlying.balanceOf(recipient);

        wrapper.approve(address(periphery), wrapAmount);

        vm.warp(time);
        if (time < wrapper.unlockTime() || unwrapAmount > wrapAmount) {
            assertEq(wrapper.totalSupply(), wrapAmount);
            vm.expectRevert();
            periphery.unwrap(wrapper, recipient, unwrapAmount);
            assertEq(wrapper.totalSupply(), wrapAmount);
        } else {
            assertEq(wrapper.totalSupply(), wrapAmount);
            periphery.unwrap(wrapper, recipient, unwrapAmount);
            assertEq(wrapper.balanceOf(address(this)), wrapAmount - unwrapAmount, "Didn't burn wrapper");
            assertEq(underlying.balanceOf(recipient), oldBalance + unwrapAmount, "Didn't transfer underlying");
            assertEq(wrapper.totalSupply(), wrapAmount - unwrapAmount);
        }
    }

    function testUnwrapGas() public {
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), 0);

        underlying.approve(address(periphery), 1);
        periphery.wrap(wrapper, 1);
        wrapper.approve(address(periphery), 1);
        assertEq(wrapper.allowance(address(this), address(periphery)), 1);

        coolAllContracts();
        vm.cool(address(wrapper));

        periphery.unwrap(wrapper, 1);
        vm.snapshotGasLastCall("unwrap");
    }
}
