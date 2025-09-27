// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {BaseOracleTest} from "../extensions/Oracle.t.sol";
import {ERC7726, IERC7726_ETH_ADDRESS, IERC7726_BTC_ADDRESS, IERC7726_USD_ADDRESS} from "../../src/lens/ERC7726.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {TestToken} from "../TestToken.sol";
import {IOracle} from "../../src/interfaces/extensions/IOracle.sol";

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

    function test_constructor_validation() public {
        // Test invalid oracle
        vm.expectRevert(ERC7726.InvalidOracle.selector);
        new ERC7726(IOracle(address(0)), address(usdc), address(wbtc), 60);

        // Test invalid USD proxy token
        vm.expectRevert(ERC7726.InvalidProxyToken.selector);
        new ERC7726(oracle, address(0), address(wbtc), 60);

        // Test invalid BTC proxy token
        vm.expectRevert(ERC7726.InvalidProxyToken.selector);
        new ERC7726(oracle, address(usdc), address(0), 60);

        // Test invalid TWAP duration
        vm.expectRevert(ERC7726.InvalidTwapDuration.selector);
        new ERC7726(oracle, address(usdc), address(wbtc), 0);

        // Test valid construction
        ERC7726 validOracle = new ERC7726(oracle, address(usdc), address(wbtc), 60);
        assertEq(address(validOracle.ORACLE()), address(oracle));
        assertEq(validOracle.USD_PROXY_TOKEN(), address(usdc));
        assertEq(validOracle.BTC_PROXY_TOKEN(), address(wbtc));
        assertEq(validOracle.TWAP_DURATION(), 60);
    }

    function test_getQuote_zero_amount() public {
        vm.expectRevert(ERC7726.ZeroBaseAmount.selector);
        erc.getQuote(0, address(usdc), address(wbtc));
    }

    function test_getQuote_insufficient_history() public {
        // Create a new oracle with a very long TWAP duration that exceeds block.timestamp
        ERC7726 longTwapOracle = new ERC7726(oracle, address(usdc), address(wbtc), uint32(block.timestamp + 1));

        oracle.expandCapacity(address(usdc), 10);
        createOraclePool(address(usdc), 0);

        // Should revert due to insufficient price history
        vm.expectRevert(ERC7726.InsufficientPriceHistory.selector);
        longTwapOracle.getQuote(1e18, address(usdc), address(0)); // ETH quote requires oracle call
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

    function test_getQuote_same_token() public {
        // Same token should return the same amount without needing oracle setup
        assertEq(erc.getQuote(1e18, address(usdc), address(usdc)), 1e18, "same token quote");
        assertEq(erc.getQuote(5e17, address(wbtc), address(wbtc)), 5e17, "same token quote different amount");

        // Test with standard addresses
        assertEq(erc.getQuote(2e18, IERC7726_ETH_ADDRESS, IERC7726_ETH_ADDRESS), 2e18, "ETH to ETH");
        assertEq(erc.getQuote(3e18, IERC7726_USD_ADDRESS, IERC7726_USD_ADDRESS), 3e18, "USD to USD");
        assertEq(erc.getQuote(4e18, IERC7726_BTC_ADDRESS, IERC7726_BTC_ADDRESS), 4e18, "BTC to BTC");
    }

    function test_getQuote_standard_addresses() public {
        oracle.expandCapacity(address(usdc), 10);
        oracle.expandCapacity(address(wbtc), 10);

        createOraclePool(address(usdc), 0);
        createOraclePool(address(wbtc), 0);
        advanceTime(60);

        // Test that standard addresses work
        uint256 ethToUsd = erc.getQuote(1e18, IERC7726_ETH_ADDRESS, IERC7726_USD_ADDRESS);
        uint256 ethToUsdc = erc.getQuote(1e18, address(0), address(usdc));
        assertEq(ethToUsd, ethToUsdc, "ETH standard address should work");

        uint256 btcToUsd = erc.getQuote(1e18, IERC7726_BTC_ADDRESS, IERC7726_USD_ADDRESS);
        uint256 wbtcToUsdc = erc.getQuote(1e18, address(wbtc), address(usdc));
        assertEq(btcToUsd, wbtcToUsdc, "BTC standard address should work");
    }

    function test_getQuote_different_amounts() public {
        oracle.expandCapacity(address(usdc), 10);
        oracle.expandCapacity(address(wbtc), 10);

        createOraclePool(address(usdc), 0);
        createOraclePool(address(wbtc), 693147); // 2x price
        advanceTime(60);

        uint256 quote1 = erc.getQuote(1e18, address(usdc), address(wbtc));
        uint256 quote2 = erc.getQuote(2e18, address(usdc), address(wbtc));

        // Should scale linearly (within rounding tolerance)
        assertApproxEqRel(quote2, quote1 * 2, 1e12, "quotes should scale linearly"); // Within 0.0001% due to rounding
    }

    function test_getQuote_reverse_pairs() public {
        oracle.expandCapacity(address(usdc), 10);
        oracle.expandCapacity(address(wbtc), 10);

        createOraclePool(address(usdc), 0);
        createOraclePool(address(wbtc), 693147); // 2x price
        advanceTime(60);

        uint256 usdcToWbtc = erc.getQuote(1e18, address(usdc), address(wbtc));
        uint256 wbtcToUsdc = erc.getQuote(1e18, address(wbtc), address(usdc));

        // Reverse pairs should be approximately inverse (within rounding)
        uint256 product = (usdcToWbtc * wbtcToUsdc) / 1e18;
        assertApproxEqRel(product, 1e18, 1e15); // Within 0.1% due to rounding
    }

    function test_immutable_values() public view {
        // Test that immutable values are set correctly
        assertEq(address(erc.ORACLE()), address(oracle));
        assertEq(erc.USD_PROXY_TOKEN(), address(usdc));
        assertEq(erc.BTC_PROXY_TOKEN(), address(wbtc));
        assertEq(erc.TWAP_DURATION(), 60);
    }
}
