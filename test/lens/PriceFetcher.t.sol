// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {BaseOracleTest} from "../extensions/Oracle.t.sol";
import {PriceFetcher} from "../../src/lens/PriceFetcher.sol";
import {PoolKey} from "../../src/types/keys.sol";

contract PriceFetcherTest is BaseOracleTest {
    PriceFetcher internal pf;

    function setUp() public override {
        BaseOracleTest.setUp();
        pf = new PriceFetcher(oracle);
    }

    function test_canFetchPrices() public {
        PoolKey memory pk0 = createOraclePool(address(token0), 10000);
        PoolKey memory pk1 = createOraclePool(address(token1), -1000);
    }
}
