// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    MoneyMarketBorrowerBalances,
    createMoneyMarketBorrowerBalances
} from "../../src/types/moneyMarketBorrowerBalances.sol";

contract MoneyMarketBorrowerBalancesTest is Test {
    function test_conversionToAndFrom(MoneyMarketBorrowerBalances balances) public pure {
        assertEq(
            MoneyMarketBorrowerBalances.unwrap(
                createMoneyMarketBorrowerBalances({
                    _collateralAmount: balances.collateralAmount(), _debtAmount: balances.debtAmount()
                })
            ),
            MoneyMarketBorrowerBalances.unwrap(balances)
        );
    }

    function test_conversionFromAndTo(uint128 collateral, uint128 debt) public pure {
        MoneyMarketBorrowerBalances balances =
            createMoneyMarketBorrowerBalances({_collateralAmount: collateral, _debtAmount: debt});
        assertEq(balances.collateralAmount(), collateral);
        assertEq(balances.debtAmount(), debt);
    }

    function test_parse(uint128 collateral, uint128 debt) public pure {
        MoneyMarketBorrowerBalances balances =
            createMoneyMarketBorrowerBalances({_collateralAmount: collateral, _debtAmount: debt});
        (uint128 parsedCollateral, uint128 parsedDebt) = balances.parse();
        assertEq(parsedCollateral, collateral);
        assertEq(parsedDebt, debt);
    }
}
