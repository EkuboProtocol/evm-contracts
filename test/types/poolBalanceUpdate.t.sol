// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

import {Test} from "forge-std/Test.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";

contract PoolBalanceUpdateTest is Test {
    function test_conversionToAndFrom(PoolBalanceUpdate update) public pure {
        assertEq(
            PoolBalanceUpdate.unwrap(createPoolBalanceUpdate({_delta0: update.delta0(), _delta1: update.delta1()})),
            PoolBalanceUpdate.unwrap(update)
        );
    }

    function test_conversionFromAndTo(int128 delta0, int128 delta1) public pure {
        PoolBalanceUpdate update = createPoolBalanceUpdate({_delta0: delta0, _delta1: delta1});
        assertEq(update.delta0(), delta0);
        assertEq(update.delta1(), delta1);
    }

    function test_conversionFromAndToDirtyBits(bytes32 delta0Dirty, bytes32 delta1Dirty) public pure {
        int128 delta0;
        int128 delta1;

        assembly ("memory-safe") {
            delta0 := delta0Dirty
            delta1 := delta1Dirty
        }

        PoolBalanceUpdate update = createPoolBalanceUpdate({_delta0: delta0, _delta1: delta1});
        assertEq(update.delta0(), delta0, "delta0");
        assertEq(update.delta1(), delta1, "delta1");
    }
}
