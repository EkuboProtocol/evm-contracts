// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {FullTest} from "./FullTest.sol";
import {TokenWrapper} from "../src/TokenWrapper.sol";
import {TokenWrapperFactory} from "../src/TokenWrapperFactory.sol";
import {toDate, toQuarter} from "../src/libraries/TimeDescriptor.sol";
import {TestToken} from "./TestToken.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";

contract TokenWrapperPeriphery is BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function wrap(TokenWrapper wrapper, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, msg.sender, int256(uint256(amount))));
    }

    function wrap(TokenWrapper wrapper, address recipient, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, recipient, int256(uint256(amount))));
    }

    function unwrap(TokenWrapper wrapper, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, msg.sender, -int256(uint256(amount))));
    }

    function unwrap(TokenWrapper wrapper, address recipient, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, recipient, -int256(uint256(amount))));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (TokenWrapper wrapper, address payer, address recipient, int256 amount) =
            abi.decode(data, (TokenWrapper, address, address, int256));

        if (amount >= 0) {
            // this creates the deltas
            ACCOUNTANT.forward(address(wrapper), abi.encode(amount));
            // now withdraw to the recipient
            if (uint128(uint256(amount)) > 0) {
                ACCOUNTANT.withdraw(address(wrapper), recipient, uint128(uint256(amount)));
            }
            // and pay the wrapped token from the payer
            if (uint256(amount) != 0) {
                if (address(wrapper.UNDERLYING_TOKEN()) == NATIVE_TOKEN_ADDRESS) {
                    SafeTransferLib.safeTransferETH(address(ACCOUNTANT), uint256(amount));
                } else {
                    ACCOUNTANT.payFrom(payer, address(wrapper.UNDERLYING_TOKEN()), uint256(amount));
                }
            }
        } else {
            // this creates the deltas
            ACCOUNTANT.forward(address(wrapper), abi.encode(amount));
            // now withdraw to the recipient
            if (uint128(uint256(-amount)) > 0) {
                ACCOUNTANT.withdraw(address(wrapper.UNDERLYING_TOKEN()), recipient, uint128(uint256(-amount)));
            }
            // and pay the wrapped token from the payer
            if (uint256(-amount) != 0) {
                if (address(wrapper) == NATIVE_TOKEN_ADDRESS) {
                    SafeTransferLib.safeTransferETH(address(ACCOUNTANT), uint256(-amount));
                } else {
                    ACCOUNTANT.payFrom(payer, address(wrapper), uint256(-amount));
                }
            }
        }
    }
}

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
        assertEq(wrapper.UNLOCK_TIME(), unlockTime);
        assertEq(address(wrapper.UNDERLYING_TOKEN()), address(underlying));
    }

    function testWrap(uint256 time, uint64 unlockTime, uint128 wrapAmount) public {
        vm.warp(time);
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), unlockTime);
        wrapAmount = uint128(bound(wrapAmount, 0, uint128(type(int128).max)));

        underlying.approve(address(periphery), wrapAmount);
        assertEq(wrapper.totalSupply(), 0);
        periphery.wrap(wrapper, wrapAmount);
        assertEq(wrapper.totalSupply(), wrapAmount);

        assertEq(wrapper.balanceOf(address(this)), wrapAmount, "Didn't mint wrapper");
        assertEq(underlying.balanceOf(address(core)), wrapAmount, "Didn't transfer underlying");
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
        vm.assume(recipient != address(core));
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), 1755616480);
        wrapAmount = uint128(bound(wrapAmount, 1, uint128(type(int128).max)));
        unwrapAmount = uint128(bound(unwrapAmount, 1, wrapAmount));

        underlying.approve(address(periphery), wrapAmount);
        periphery.wrap(wrapper, wrapAmount);
        uint256 oldBalance = underlying.balanceOf(recipient);

        wrapper.approve(address(periphery), wrapAmount);

        vm.warp(time);
        if (time < wrapper.UNLOCK_TIME()) {
            assertEq(wrapper.totalSupply(), wrapAmount);
            vm.expectRevert(TokenWrapper.TooEarly.selector);
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
