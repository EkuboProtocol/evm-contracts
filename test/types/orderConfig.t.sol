// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {OrderConfig, createOrderConfig} from "../../src/types/orderConfig.sol";

contract OrderConfigTest is Test {
    function test_conversionToAndFrom(OrderConfig config) public pure {
        OrderConfig recreated = createOrderConfig({
            _fee: config.fee(),
            _isToken1: config.isToken1(),
            _startTime: config.startTime(),
            _endTime: config.endTime()
        });

        // Compare the extracted values rather than raw bytes, since padding and isToken1 byte can vary
        assertEq(recreated.fee(), config.fee(), "fee");
        assertEq(recreated.isToken1(), config.isToken1(), "isToken1");
        assertEq(recreated.startTime(), config.startTime(), "startTime");
        assertEq(recreated.endTime(), config.endTime(), "endTime");
    }

    function test_conversionFromAndTo(uint64 fee, bool isToken1, uint64 startTime, uint64 endTime) public pure {
        OrderConfig config =
            createOrderConfig({_fee: fee, _isToken1: isToken1, _startTime: startTime, _endTime: endTime});
        assertEq(config.fee(), fee);
        assertEq(config.isToken1(), isToken1);
        assertEq(config.startTime(), startTime);
        assertEq(config.endTime(), endTime);
    }

    function test_conversionFromAndToDirtyBits(
        bytes32 feeDirty,
        bytes32 isToken1Dirty,
        bytes32 startTimeDirty,
        bytes32 endTimeDirty
    ) public pure {
        uint64 fee;
        bool isToken1;
        uint64 startTime;
        uint64 endTime;

        assembly ("memory-safe") {
            fee := feeDirty
            isToken1 := isToken1Dirty
            startTime := startTimeDirty
            endTime := endTimeDirty
        }

        OrderConfig config =
            createOrderConfig({_fee: fee, _isToken1: isToken1, _startTime: startTime, _endTime: endTime});
        assertEq(config.fee(), fee, "fee");
        assertEq(config.isToken1(), isToken1, "isToken1");
        assertEq(config.startTime(), startTime, "startTime");
        assertEq(config.endTime(), endTime, "endTime");
    }
}
