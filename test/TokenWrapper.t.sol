// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";
import {TokenWrapper} from "../src/TokenWrapper.sol";
import {TokenWrapperFactory} from "../src/TokenWrapperFactory.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {toDate, toQuarter} from "../src/libraries/TimeDescriptor.sol";

contract TestToken is ERC20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TokenWrapperTest is Test {
    TokenWrapperFactory factory;
    TestToken underlying;

    address user = makeAddr("user");

    function setUp() public {
        underlying = new TestToken("Ekubo Protocol", "EKUBO", 18);
        underlying.mint(user, 100e18);
        factory = new TokenWrapperFactory();
    }

    function testDeployWrapperGas() public {
        factory.deployWrapper(underlying, 1756140269);
        vm.snapshotGasLastCall("deployWrapper");
    }

    function testTokenInfo(uint256 time, uint256 unlockTime) public {
        time = bound(time, 0, type(uint256).max - type(uint32).max);
        vm.warp(time);
        unlockTime = bound(unlockTime, vm.getBlockTimestamp() + 1, vm.getBlockTimestamp() + type(uint32).max);

        TokenWrapper wrapper = factory.deployWrapper(underlying, unlockTime);

        assertEq(wrapper.symbol(), string.concat("gEKUBO-", toQuarter(unlockTime)));
        assertEq(wrapper.name(), string.concat("Ekubo Protocol ", toDate(unlockTime)));
        assertEq(wrapper.unlockTime(), unlockTime);
    }

    function testWrap(uint256 time, uint256 unlockTime, uint256 wrapAmount) public {
        vm.warp(time);
        TokenWrapper wrapper = factory.deployWrapper(underlying, unlockTime);
        vm.startPrank(user);
        underlying.approve(address(wrapper), wrapAmount);
        if (wrapAmount > underlying.balanceOf(user)) {
            vm.expectRevert();
            wrapper.wrap(wrapAmount);
        } else {
            wrapper.wrap(wrapAmount);
            assertEq(wrapper.balanceOf(user), wrapAmount, "Didn't mint wrapper");
            assertEq(underlying.balanceOf(address(wrapper)), wrapAmount, "Didn't transfer underlying");
        }
    }

    function testWrapGas() public {
        TokenWrapper wrapper = factory.deployWrapper(underlying, 0);
        vm.startPrank(user);
        underlying.approve(address(wrapper), 1);
        vm.cool(address(factory.implementation()));
        vm.cool(address(wrapper));
        vm.cool(address(underlying));
        vm.cool(address(user));
        wrapper.wrap(1);
        vm.snapshotGasLastCall("wrap");
    }

    function testUnwrapTo(address recipient, uint256 wrapAmount, uint256 unwrapAmount, uint256 time) public {
        TokenWrapper wrapper = factory.deployWrapper(underlying, 1755616480);
        wrapAmount = bound(wrapAmount, 0, underlying.balanceOf(user));

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
        TokenWrapper wrapper = factory.deployWrapper(underlying, 0);

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
