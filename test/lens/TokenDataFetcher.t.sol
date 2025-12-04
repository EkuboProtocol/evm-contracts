// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {Test} from "forge-std/Test.sol";
import {TokenDataFetcher} from "../../src/lens/TokenDataFetcher.sol";
import {NATIVE_TOKEN_ADDRESS} from "../../src/math/constants.sol";
import {TestToken} from "../TestToken.sol";

contract TokenDataFetcherTest is Test {
    TokenDataFetcher internal tdf;

    TestToken tokenA;
    TestToken tokenB;

    function setUp() public {
        tdf = new TokenDataFetcher();
        tokenA = new TestToken(address(this));
        tokenB = new TestToken(address(this));
    }

    function test_getsBalanceManyTokens() public {
        tokenA.transfer(address(0), 10000);
        tokenB.approve(address(0xdeadbeef), 500);
        tokenA.approve(address(this), 500000);
        tokenB.transfer(address(0xdeadbeef), 1000000);
        vm.deal(address(this), address(this).balance - 1000);

        address[] memory tokens = new address[](3);
        tokens[0] = address(tokenA);
        tokens[1] = NATIVE_TOKEN_ADDRESS;
        tokens[2] = address(tokenB);

        address[] memory spenders = new address[](3);
        spenders[0] = address(0xdeadbeef);
        spenders[1] = address(address(this));
        spenders[2] = address(0);

        (TokenDataFetcher.Balance[] memory balances, TokenDataFetcher.Allowance[] memory allowances) =
            tdf.getNonzeroBalancesAndAllowances(address(this), tokens, spenders);
        assertEq(balances.length, 3);
        assertEq(balances[0].token, address(tokenA));
        assertEq(balances[0].amount, type(uint256).max - 10000);
        assertEq(balances[1].token, NATIVE_TOKEN_ADDRESS);
        assertEq(balances[1].amount, type(uint96).max - 1000);
        assertEq(balances[2].token, address(tokenB));
        assertEq(balances[2].amount, type(uint256).max - 1000000);

        assertEq(allowances.length, 2);
        assertEq(allowances[0].token, address(tokenA));
        assertEq(allowances[0].spender, address(this));
        assertEq(allowances[0].amount, 500000);
        assertEq(allowances[1].token, address(tokenB));
        assertEq(allowances[1].spender, address(0xdeadbeef));
        assertEq(allowances[1].amount, 500);
    }
}
