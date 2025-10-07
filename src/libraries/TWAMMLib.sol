// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ITWAMM} from "../interfaces/extensions/ITWAMM.sol";
import {ICore} from "../interfaces/ICore.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {TWAMMStorageLayout} from "./TWAMMStorageLayout.sol";
import {FlashAccountantLib} from "./FlashAccountantLib.sol";
import {TwammPoolState} from "../types/twammPoolState.sol";
import {OrderState} from "../types/orderState.sol";
import {OrderKey} from "../types/orderKey.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";
import {OrderId} from "../types/orderId.sol";
import {computeAmountFromSaleRate, computeRewardAmount} from "../math/twamm.sol";
import {StorageSlot} from "../types/storageSlot.sol";

/// @title TWAMM Library
/// @notice Helper methods for interacting with the TWAMM extension
library TWAMMLib {
    using ExposedStorageLib for *;
    using FlashAccountantLib for *;

    function poolState(ITWAMM twamm, PoolId poolId) internal view returns (TwammPoolState twammPoolState) {
        twammPoolState =
            TwammPoolState.wrap(twamm.sload(StorageSlot.unwrap(TWAMMStorageLayout.twammPoolStateSlot(poolId))));
    }

    function orderState(ITWAMM twamm, address owner, bytes32 salt, OrderId orderId)
        internal
        view
        returns (OrderState state)
    {
        state = OrderState.wrap(
            twamm.sload(
                StorageSlot.unwrap(
                    TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner, salt, orderId)
                )
            )
        );
    }

    function rewardRateSnapshot(ITWAMM twamm, address owner, bytes32 salt, OrderId orderId)
        internal
        view
        returns (uint256)
    {
        return uint256(
            twamm.sload(
                StorageSlot.unwrap(
                    TWAMMStorageLayout.orderStateSlotFollowedByOrderRewardRateSnapshotSlot(owner, salt, orderId).next()
                )
            )
        );
    }

    function executeVirtualOrdersAndGetCurrentOrderInfo(
        ITWAMM twamm,
        address owner,
        bytes32 salt,
        OrderKey memory orderKey
    ) internal returns (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 purchasedAmount) {
        unchecked {
            PoolKey memory poolKey = orderKey.toPoolKey(address(twamm));
            twamm.lockAndExecuteVirtualOrders(poolKey);

            uint32 lastUpdateTime;
            OrderId orderId = orderKey.toOrderId();

            (lastUpdateTime, saleRate, amountSold) = orderState(twamm, owner, salt, orderId).parse();

            uint256 _rewardRateSnapshot = rewardRateSnapshot(twamm, owner, salt, orderId);

            if (saleRate != 0) {
                (uint64 startTime, uint64 endTime) = (orderKey.startTime(), orderKey.endTime());

                uint256 rewardRateInside =
                    twamm.getRewardRateInside(poolKey.toPoolId(), startTime, endTime, !orderKey.isToken1());

                purchasedAmount = computeRewardAmount(rewardRateInside - _rewardRateSnapshot, saleRate);

                if (block.timestamp > startTime) {
                    uint32 secondsSinceLastUpdate = uint32(block.timestamp) - lastUpdateTime;

                    uint32 secondsSinceOrderStart = uint32(uint64(block.timestamp) - startTime);

                    uint32 totalOrderDuration = uint32(endTime - startTime);

                    uint32 remainingTimeSinceLastUpdate = uint32(endTime) - lastUpdateTime;

                    uint32 saleDuration = uint32(
                        FixedPointMathLib.min(
                            remainingTimeSinceLastUpdate,
                            FixedPointMathLib.min(
                                FixedPointMathLib.min(secondsSinceLastUpdate, secondsSinceOrderStart),
                                totalOrderDuration
                            )
                        )
                    );

                    amountSold +=
                        computeAmountFromSaleRate({saleRate: saleRate, duration: saleDuration, roundUp: false});
                }
                if (block.timestamp < endTime) {
                    remainingSellAmount = computeAmountFromSaleRate({
                        saleRate: saleRate,
                        duration: uint32(endTime - FixedPointMathLib.max(startTime, block.timestamp)),
                        roundUp: true
                    });
                }
            }
        }
    }

    /// @notice Updates the sale rate for a TWAMM order using FlashAccountantLib.forward
    /// @dev Uses FlashAccountantLib.forward to make the necessary call to update the sale rate and parse the result
    /// @param core The core contract to forward through
    /// @param twamm The TWAMM extension contract
    /// @param salt Unique salt for the order
    /// @param orderKey Order key identifying the order
    /// @param saleRateDelta Change in sale rate (positive to increase, negative to decrease)
    /// @return amount The amount delta resulting from the sale rate update
    function updateSaleRate(ICore core, ITWAMM twamm, bytes32 salt, OrderKey memory orderKey, int112 saleRateDelta)
        internal
        returns (int256 amount)
    {
        amount =
            abi.decode(core.forward(address(twamm), abi.encode(uint256(0), salt, orderKey, saleRateDelta)), (int256));
    }

    /// @notice Collects proceeds from a TWAMM order using FlashAccountantLib.forward
    /// @dev Uses FlashAccountantLib.forward to make the necessary call to collect proceeds and parse the result
    /// @param core The core contract to forward through
    /// @param twamm The TWAMM extension contract
    /// @param salt Unique salt for the order
    /// @param orderKey Order key identifying the order
    /// @return proceeds The amount of proceeds collected
    function collectProceeds(ICore core, ITWAMM twamm, bytes32 salt, OrderKey memory orderKey)
        internal
        returns (uint128 proceeds)
    {
        proceeds = abi.decode(core.forward(address(twamm), abi.encode(uint256(1), salt, orderKey)), (uint128));
    }
}
