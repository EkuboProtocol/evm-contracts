// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Payable} from "../../src/base/Payable.sol";
import {WETH} from "solady/tokens/WETH.sol";
import {TestToken} from "../TestToken.sol";

contract MockPayable is Payable {
    constructor(WETH weth) Payable(weth) {}
}

contract PayableTest is Test {
    WETH public weth;
    TestToken public token;
    MockPayable public mp;

    function setUp() public {
        weth = new WETH();
        token = new TestToken();
        mp = new MockPayable(weth);
    }

    function test_wrapETH(uint128 value) public {
        value = uint128(bound(value, 0, type(uint64).max));
        mp.wrapETH{value: value}();
        assertEq(weth.balanceOf(address(mp)), value);
    }

    function test_payToken(uint128 amount) public {
        token.approve(address(mp), amount);
        mp.pay(address(token), amount);
        assertEq(token.balanceOf(address(mp)), amount);
    }

    function test_clearMinimumToRecipient(uint128 amount, uint128 minimum, address recipient) public {
        vm.assume(recipient != address(this));
        token.transfer(address(mp), amount);
        if (minimum > amount) {
            vm.expectRevert(
                abi.encodeWithSelector(Payable.ClearMinimumBalanceNotReceived.selector, address(token), minimum, amount)
            );
        }
        mp.clearMinimumToRecipient(address(token), minimum, recipient);
        if (minimum <= amount) {
            assertEq(token.balanceOf(recipient), amount);
        }
    }
}
