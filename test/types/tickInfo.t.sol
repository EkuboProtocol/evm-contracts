// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {TickInfo, createTickInfo} from "../../src/types/tickInfo.sol";

contract TickInfoTest is Test {
    function test_conversionToAndFrom(TickInfo info) public pure {
        assertEq(
            TickInfo.unwrap(
                createTickInfo({_liquidityDelta: info.liquidityDelta(), _liquidityNet: info.liquidityNet()})
            ),
            TickInfo.unwrap(info)
        );
    }

    function test_conversionFromAndTo(int128 liquidityDelta, uint128 liquidityNet) public pure {
        TickInfo info = createTickInfo({_liquidityDelta: liquidityDelta, _liquidityNet: liquidityNet});
        assertEq(info.liquidityDelta(), liquidityDelta);
        assertEq(info.liquidityNet(), liquidityNet);
    }

    function test_conversionFromAndToDirtyBits(bytes32 liquidityDeltaDirty, bytes32 liquidityNetDirty) public pure {
        int128 liquidityDelta;
        uint128 liquidityNet;

        assembly ("memory-safe") {
            liquidityDelta := liquidityDeltaDirty
            liquidityNet := liquidityNetDirty
        }

        TickInfo info = createTickInfo({_liquidityDelta: liquidityDelta, _liquidityNet: liquidityNet});
        assertEq(info.liquidityDelta(), liquidityDelta, "liquidityDelta");
        assertEq(info.liquidityNet(), liquidityNet, "liquidityNet");
    }
}
