// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    TWAMMRecoverableBorrowerBalances,
    createTWAMMRecoverableBorrowerBalances
} from "../../src/types/twammRecoverableBorrowerBalances.sol";

contract TWAMMRecoverableBorrowerBalancesTest is Test {
    function test_conversionToAndFrom(TWAMMRecoverableBorrowerBalances balances) public pure {
        assertEq(
            TWAMMRecoverableBorrowerBalances.unwrap(
                createTWAMMRecoverableBorrowerBalances({
                    _collateralAmount: balances.collateralAmount(), _debtAmount: balances.debtAmount()
                })
            ),
            TWAMMRecoverableBorrowerBalances.unwrap(balances)
        );
    }

    function test_conversionFromAndTo(uint128 collateral, uint128 debt) public pure {
        TWAMMRecoverableBorrowerBalances balances =
            createTWAMMRecoverableBorrowerBalances({_collateralAmount: collateral, _debtAmount: debt});
        assertEq(balances.collateralAmount(), collateral);
        assertEq(balances.debtAmount(), debt);
    }

    function test_parse(uint128 collateral, uint128 debt) public pure {
        TWAMMRecoverableBorrowerBalances balances =
            createTWAMMRecoverableBorrowerBalances({_collateralAmount: collateral, _debtAmount: debt});
        (uint128 parsedCollateral, uint128 parsedDebt) = balances.parse();
        assertEq(parsedCollateral, collateral);
        assertEq(parsedDebt, debt);
    }
}
