// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {LiquidationInfo, createLiquidationInfo} from "../../src/types/liquidationInfo.sol";

contract LiquidationInfoTest is Test {
    function test_conversionToAndFrom(LiquidationInfo info) public pure {
        LiquidationInfo roundtrip = createLiquidationInfo({_startTime: info.startTime(), _duration: info.duration()});
        assertEq(roundtrip.startTime(), info.startTime());
        assertEq(roundtrip.duration(), info.duration());
    }

    function test_conversionFromAndTo(uint64 _startTime, uint32 _duration) public pure {
        LiquidationInfo info = createLiquidationInfo({_startTime: _startTime, _duration: _duration});
        assertEq(info.startTime(), _startTime);
        assertEq(info.duration(), _duration);
    }

    function test_parse(uint64 _startTime, uint32 _duration) public pure {
        LiquidationInfo info = createLiquidationInfo({_startTime: _startTime, _duration: _duration});
        (uint64 parsedStartTime, uint32 parsedDuration) = info.parse();
        assertEq(parsedStartTime, _startTime);
        assertEq(parsedDuration, _duration);
    }

    function test_endTime(uint64 _startTime, uint32 _duration) public pure {
        if (_startTime > type(uint64).max - _duration) return;
        LiquidationInfo info = createLiquidationInfo({_startTime: _startTime, _duration: _duration});
        assertEq(info.endTime(), _startTime + uint64(_duration));
    }

    function test_active() public pure {
        assertFalse(createLiquidationInfo({_startTime: 123, _duration: 0}).active());
        assertTrue(createLiquidationInfo({_startTime: 123, _duration: 1}).active());
    }
}
