// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {BaseOracleTest} from "../extensions/Oracle.t.sol";
import {PriceFetcher} from "../../src/lens/PriceFetcher.sol";
import {PoolKey} from "../../src/types/keys.sol";
import {TestToken} from "../TestToken.sol";

contract PriceFetcherTest is BaseOracleTest {
    PriceFetcher internal pf;

    function setUp() public override {
        BaseOracleTest.setUp();
        pf = new PriceFetcher(oracle);
    }

    function test_fetchPrices_gas_snapshot() public {
        createOraclePool(address(token0), 0);
        updateOraclePoolLiquidity(address(token0), 500);
        advanceTime(30);

        address[] memory baseTokens = new address[](1);
        baseTokens[0] = address(token0);
        pf.getPricesInOracleToken(30, baseTokens);
        vm.snapshotGasLastCall("getPricesInOracleToken(1 token)");
    }

    function test_canFetchPrices() public {
        createOraclePool(address(token0), 3737671);

        advanceTime(15);

        createOraclePool(address(token1), -4234108);

        updateOraclePoolLiquidity(address(token0), 500);
        updateOraclePoolLiquidity(address(token1), 7500);

        advanceTime(30);
        address[] memory baseTokens = new address[](4);
        baseTokens[0] = address(token0);
        baseTokens[1] = address(token1);
        baseTokens[2] = address(oracleToken);
        baseTokens[3] = address(0xdeadbeef);
        (address ot, PriceFetcher.Result[] memory results) = pf.getPricesInOracleToken(30, baseTokens);
        assertEq(ot, address(oracleToken));

        // ~= 42
        assertEq(results[0].priceX128, 8101965063774199046946818765421275446);
        assertEq(results[0].liquidity, 500);

        // ~= 69
        assertEq(results[1].priceX128, 23479468721532054986745577134847629670150);
        assertEq(results[1].liquidity, 7500);

        assertEq(results[2].priceX128, 1 << 128);
        assertEq(results[2].liquidity, type(uint128).max);

        assertEq(results[3].priceX128, 0);
        assertEq(results[3].liquidity, 0);

        address nt = address(new TestToken(address(this)));
        createOraclePool(nt, 11512931);
        updateOraclePoolLiquidity(nt, 100000);

        updateOraclePoolLiquidity(address(token0), 5000);
        updateOraclePoolLiquidity(address(token1), 2500);

        advanceTime(15);

        baseTokens = new address[](5);
        baseTokens[0] = address(token0);
        baseTokens[1] = address(token1);
        baseTokens[2] = address(oracleToken);
        baseTokens[3] = address(0xdeadbeef);
        baseTokens[4] = nt;

        (ot, results) = pf.getPricesInOracleToken(30, baseTokens);
        assertEq(ot, address(oracleToken));

        // ~= 42
        assertEq(results[0].priceX128, 8101965063774199046946818765421275446);
        // went up by not a lot
        assertEq(results[0].liquidity, 909);

        // ~= 69
        assertEq(results[1].priceX128, 23479468721532054986745577134847629670150);
        // went down by half
        assertEq(results[1].liquidity, 3750);

        assertEq(results[2].priceX128, 1 << 128);
        assertEq(results[2].liquidity, type(uint128).max);

        // insufficient history
        assertEq(results[3].priceX128, 0);
        assertEq(results[3].liquidity, 0);
    }
}
