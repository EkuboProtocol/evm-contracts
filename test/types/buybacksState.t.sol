// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {BuybacksState, createBuybacksState} from "../../src/types/buybacksState.sol";

contract BuybacksStateTest is Test {
    function test_conversionToAndFrom(BuybacksState state) public pure {
        assertEq(
            BuybacksState.unwrap(
                createBuybacksState({
                    _targetOrderDuration: state.targetOrderDuration(),
                    _minOrderDuration: state.minOrderDuration(),
                    _fee: state.fee(),
                    _lastEndTime: state.lastEndTime(),
                    _lastOrderDuration: state.lastOrderDuration(),
                    _lastFee: state.lastFee()
                })
            ),
            BuybacksState.unwrap(state)
        );
    }

    function test_conversionFromAndTo(
        uint32 targetOrderDuration,
        uint32 minOrderDuration,
        uint64 fee,
        uint32 lastEndTime,
        uint32 lastOrderDuration,
        uint64 lastFee
    ) public pure {
        BuybacksState state = createBuybacksState({
            _targetOrderDuration: targetOrderDuration,
            _minOrderDuration: minOrderDuration,
            _fee: fee,
            _lastEndTime: lastEndTime,
            _lastOrderDuration: lastOrderDuration,
            _lastFee: lastFee
        });

        assertEq(state.targetOrderDuration(), targetOrderDuration);
        assertEq(state.minOrderDuration(), minOrderDuration);
        assertEq(state.fee(), fee);
        assertEq(state.lastEndTime(), lastEndTime);
        assertEq(state.lastOrderDuration(), lastOrderDuration);
        assertEq(state.lastFee(), lastFee);
    }

    function test_parse(
        uint32 targetOrderDuration,
        uint32 minOrderDuration,
        uint64 fee,
        uint32 lastEndTime,
        uint32 lastOrderDuration,
        uint64 lastFee
    ) public pure {
        BuybacksState state = createBuybacksState({
            _targetOrderDuration: targetOrderDuration,
            _minOrderDuration: minOrderDuration,
            _fee: fee,
            _lastEndTime: lastEndTime,
            _lastOrderDuration: lastOrderDuration,
            _lastFee: lastFee
        });

        (
            uint32 parsedTargetOrderDuration,
            uint32 parsedMinOrderDuration,
            uint64 parsedFee,
            uint32 parsedLastEndTime,
            uint32 parsedLastOrderDuration,
            uint64 parsedLastFee
        ) = state.parse();

        assertEq(parsedTargetOrderDuration, targetOrderDuration);
        assertEq(parsedMinOrderDuration, minOrderDuration);
        assertEq(parsedFee, fee);
        assertEq(parsedLastEndTime, lastEndTime);
        assertEq(parsedLastOrderDuration, lastOrderDuration);
        assertEq(parsedLastFee, lastFee);
    }

    function test_conversionFromAndToDirtyBits(
        bytes32 targetOrderDurationDirty,
        bytes32 minOrderDurationDirty,
        bytes32 feeDirty,
        bytes32 lastEndTimeDirty,
        bytes32 lastOrderDurationDirty,
        bytes32 lastFeeDirty
    ) public pure {
        uint32 targetOrderDuration;
        uint32 minOrderDuration;
        uint64 fee;
        uint32 lastEndTime;
        uint32 lastOrderDuration;
        uint64 lastFee;

        assembly ("memory-safe") {
            targetOrderDuration := targetOrderDurationDirty
            minOrderDuration := minOrderDurationDirty
            fee := feeDirty
            lastEndTime := lastEndTimeDirty
            lastOrderDuration := lastOrderDurationDirty
            lastFee := lastFeeDirty
        }

        BuybacksState state = createBuybacksState({
            _targetOrderDuration: targetOrderDuration,
            _minOrderDuration: minOrderDuration,
            _fee: fee,
            _lastEndTime: lastEndTime,
            _lastOrderDuration: lastOrderDuration,
            _lastFee: lastFee
        });

        assertEq(state.targetOrderDuration(), targetOrderDuration, "targetOrderDuration");
        assertEq(state.minOrderDuration(), minOrderDuration, "minOrderDuration");
        assertEq(state.fee(), fee, "fee");
        assertEq(state.lastEndTime(), lastEndTime, "lastEndTime");
        assertEq(state.lastOrderDuration(), lastOrderDuration, "lastOrderDuration");
        assertEq(state.lastFee(), lastFee, "lastFee");
    }
}
