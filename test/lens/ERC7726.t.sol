// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {BaseOracleTest} from "../extensions/Oracle.t.sol";
import {ERC7726, IERC7726_ETH_ADDRESS, IERC7726_BTC_ADDRESS, IERC7726_USD_ADDRESS} from "../../src/lens/ERC7726.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {TestToken} from "../TestToken.sol";

contract ERC7726Test is BaseOracleTest {
    ERC7726 internal erc;
    TestToken internal usdc;
    TestToken internal wbtc;

    function setUp() public override {
        BaseOracleTest.setUp();
        usdc = new TestToken(address(this));
        wbtc = new TestToken(address(this));
        erc = new ERC7726(oracle, address(usdc), address(wbtc), 60);
    }

    function test_getQuote() public {
        oracle.expandCapacity(address(usdc), 10);
        oracle.expandCapacity(address(wbtc), 10);

        // 0.5 usdc / o
        PoolKey memory usdcPool = createOraclePool(address(usdc), -693147);
        // 4 wbtc / o
        PoolKey memory wbtcPool = createOraclePool(address(wbtc), 693147 * 2);

        advanceTime(30);

        // 1 usdc / o
        movePrice(usdcPool, 0);
        // 256 wbtc / o
        movePrice(wbtcPool, 693147 * 8);

        advanceTime(30);
        // 4 usdc / o
        movePrice(usdcPool, 693147 * 2);
        // 16 wbtc / o
        movePrice(wbtcPool, 693147 * 4);

        assertEq(erc.getQuote(1e18, address(usdc), address(wbtc)), 45.254680164501233748e18, "usdc/wbtc first 60");
        assertEq(erc.getQuote(1e18, address(wbtc), address(usdc)), 0.022097162025341679e18, "wbtc/usdc first 60");

        assertEq(
            erc.getQuote(1e18, address(IERC7726_ETH_ADDRESS), address(IERC7726_USD_ADDRESS)),
            0.70710732110970267e18,
            "usd/eth first 60"
        );
        assertEq(
            erc.getQuote(1e18, address(IERC7726_BTC_ADDRESS), address(IERC7726_USD_ADDRESS)),
            0.022097162025341679e18,
            "usd/btc first 60"
        );

        advanceTime(12);

        assertEq(erc.getQuote(1e18, address(usdc), address(wbtc)), 39.396507221023958348e18, "usdc/wbtc after 72");
        assertEq(erc.getQuote(1e18, address(wbtc), address(usdc)), 0.025382960839390089e18, "wbtc/usdc after 72");

        advanceTime(60);

        assertEq(erc.getQuote(1e18, address(usdc), address(wbtc)), 3.999995782936508869e18, "usdc/wbtc after 132");
        assertEq(erc.getQuote(1e18, address(wbtc), address(usdc)), 0.250000263566746065e18, "wbtc/usdc after 132");

        assertEq(
            erc.getQuote(1e18, address(IERC7726_ETH_ADDRESS), address(IERC7726_USD_ADDRESS)),
            3.999995782936508869e18,
            "usd/eth after 132"
        );
        assertEq(
            erc.getQuote(1e18, address(IERC7726_BTC_ADDRESS), address(IERC7726_USD_ADDRESS)),
            0.250000263566746065e18,
            "usd/btc after 132"
        );
    }
}
