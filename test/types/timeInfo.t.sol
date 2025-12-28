// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {TimeInfo, createTimeInfo} from "../../src/types/timeInfo.sol";

contract TimeInfoTest is Test {
    function test_conversionToAndFrom(TimeInfo info) public pure {
        assertEq(
            TimeInfo.unwrap(
                createTimeInfo({
                    _numOrders: info.numOrders(),
                    _saleRateDeltaToken0: info.saleRateDeltaToken0(),
                    _saleRateDeltaToken1: info.saleRateDeltaToken1()
                })
            ),
            TimeInfo.unwrap(info)
        );
    }

    function test_conversionFromAndTo(uint32 numOrders, int112 saleRateDeltaToken0, int112 saleRateDeltaToken1)
        public
        pure
    {
        TimeInfo info = createTimeInfo({
            _numOrders: numOrders, _saleRateDeltaToken0: saleRateDeltaToken0, _saleRateDeltaToken1: saleRateDeltaToken1
        });
        assertEq(info.numOrders(), numOrders);
        assertEq(info.saleRateDeltaToken0(), saleRateDeltaToken0);
        assertEq(info.saleRateDeltaToken1(), saleRateDeltaToken1);
    }

    function test_conversionFromAndToDirtyBits(
        bytes32 numOrdersDirty,
        bytes32 saleRateDeltaToken0Dirty,
        bytes32 saleRateDeltaToken1Dirty
    ) public pure {
        uint32 numOrders;
        int112 saleRateDeltaToken0;
        int112 saleRateDeltaToken1;

        assembly ("memory-safe") {
            numOrders := numOrdersDirty
            saleRateDeltaToken0 := saleRateDeltaToken0Dirty
            saleRateDeltaToken1 := saleRateDeltaToken1Dirty
        }

        TimeInfo info = createTimeInfo({
            _numOrders: numOrders, _saleRateDeltaToken0: saleRateDeltaToken0, _saleRateDeltaToken1: saleRateDeltaToken1
        });
        assertEq(info.numOrders(), numOrders, "numOrders");
        assertEq(info.saleRateDeltaToken0(), saleRateDeltaToken0, "saleRateDeltaToken0");
        assertEq(info.saleRateDeltaToken1(), saleRateDeltaToken1, "saleRateDeltaToken1");
    }

    function test_parse(uint32 numOrders, int112 saleRateDeltaToken0, int112 saleRateDeltaToken1) public pure {
        TimeInfo info = createTimeInfo({
            _numOrders: numOrders, _saleRateDeltaToken0: saleRateDeltaToken0, _saleRateDeltaToken1: saleRateDeltaToken1
        });

        (uint32 n, int112 delta0, int112 delta1) = info.parse();
        assertEq(n, numOrders, "numOrders");
        assertEq(delta0, saleRateDeltaToken0, "saleRateDeltaToken0");
        assertEq(delta1, saleRateDeltaToken1, "saleRateDeltaToken1");
    }
}
