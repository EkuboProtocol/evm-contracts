// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IOrders} from "./interfaces/IOrders.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {TWAMMLib} from "./libraries/TWAMMLib.sol";
import {ITWAMM} from "./interfaces/extensions/ITWAMM.sol";
import {OrderKey} from "./types/orderKey.sol";
import {computeSaleRate, computeAmountFromSaleRate, computeRewardAmount} from "./math/twamm.sol";
import {BaseNonfungibleToken} from "./base/BaseNonfungibleToken.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";

/// @title Ekubo Protocol Orders
/// @author Moody Salem <moody@ekubo.org>
/// @notice Tracks TWAMM (Time-Weighted Average Market Maker) orders in Ekubo Protocol as NFTs
/// @dev Manages long-term orders that execute over time through the TWAMM extension
contract Orders is IOrders, UsesCore, PayableMulticallable, BaseLocker, BaseNonfungibleToken {
    using TWAMMLib for *;
    using FlashAccountantLib for *;

    /// @notice The TWAMM extension contract that handles order execution
    ITWAMM public immutable TWAMM_EXTENSION;

    /// @notice Constructs the Orders contract
    /// @param core The core contract instance
    /// @param _twamm The TWAMM extension contract
    /// @param owner The owner of the contract (for access control)
    constructor(ICore core, ITWAMM _twamm, address owner) BaseNonfungibleToken(owner) BaseLocker(core) UsesCore(core) {
        TWAMM_EXTENSION = _twamm;
    }

    /// @inheritdoc IOrders
    function mintAndIncreaseSellAmount(OrderKey memory orderKey, uint112 amount, uint112 maxSaleRate)
        public
        payable
        returns (uint256 id, uint112 saleRate)
    {
        id = mint();
        saleRate = increaseSellAmount(id, orderKey, amount, maxSaleRate);
    }

    /// @inheritdoc IOrders
    function increaseSellAmount(uint256 id, OrderKey memory orderKey, uint128 amount, uint112 maxSaleRate)
        public
        payable
        authorizedForNft(id)
        returns (uint112 saleRate)
    {
        uint256 realStart = FixedPointMathLib.max(block.timestamp, orderKey.startTime);

        unchecked {
            if (orderKey.endTime <= realStart) {
                revert OrderAlreadyEnded();
            }

            saleRate = uint112(computeSaleRate(amount, uint32(orderKey.endTime - realStart)));

            if (saleRate > maxSaleRate) {
                revert MaxSaleRateExceeded();
            }
        }

        lock(abi.encode(bytes1(0xdd), msg.sender, id, orderKey, saleRate));
    }

    /// @inheritdoc IOrders
    function decreaseSaleRate(uint256 id, OrderKey memory orderKey, uint112 saleRateDecrease, address recipient)
        public
        payable
        authorizedForNft(id)
        returns (uint112 refund)
    {
        refund = uint112(
            uint256(
                -abi.decode(
                    lock(abi.encode(bytes1(0xdd), recipient, id, orderKey, -int256(uint256(saleRateDecrease)))),
                    (int256)
                )
            )
        );
    }

    /// @inheritdoc IOrders
    function decreaseSaleRate(uint256 id, OrderKey memory orderKey, uint112 saleRateDecrease)
        external
        payable
        returns (uint112 refund)
    {
        refund = decreaseSaleRate(id, orderKey, saleRateDecrease, msg.sender);
    }

    /// @inheritdoc IOrders
    function collectProceeds(uint256 id, OrderKey memory orderKey, address recipient)
        public
        payable
        authorizedForNft(id)
        returns (uint128 proceeds)
    {
        proceeds = abi.decode(lock(abi.encode(bytes1(0xff), id, orderKey, recipient)), (uint128));
    }

    /// @inheritdoc IOrders
    function collectProceeds(uint256 id, OrderKey memory orderKey) external payable returns (uint128 proceeds) {
        proceeds = collectProceeds(id, orderKey, msg.sender);
    }

    /// @inheritdoc IOrders
    function executeVirtualOrdersAndGetCurrentOrderInfo(uint256 id, OrderKey memory orderKey)
        external
        returns (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 purchasedAmount)
    {
        unchecked {
            PoolKey memory poolKey = orderKey.toPoolKey(address(TWAMM_EXTENSION));
            TWAMM_EXTENSION.lockAndExecuteVirtualOrders(poolKey);

            uint32 lastUpdateTime;
            bytes32 orderId = orderKey.toOrderId();

            (lastUpdateTime, saleRate, amountSold) =
                TWAMM_EXTENSION.orderState(address(this), bytes32(id), orderId).parse();

            uint256 rewardRateSnapshot = TWAMM_EXTENSION.rewardRateSnapshot(address(this), bytes32(id), orderId);

            if (saleRate != 0) {
                uint256 rewardRateInside = TWAMM_EXTENSION.getRewardRateInside(
                    poolKey.toPoolId(), orderKey.startTime, orderKey.endTime, orderKey.sellToken < orderKey.buyToken
                );

                purchasedAmount = computeRewardAmount(rewardRateInside - rewardRateSnapshot, saleRate);

                if (block.timestamp > orderKey.startTime) {
                    uint32 secondsSinceLastUpdate = uint32(block.timestamp) - lastUpdateTime;

                    uint32 secondsSinceOrderStart = uint32(block.timestamp - orderKey.startTime);

                    uint32 totalOrderDuration = uint32(orderKey.endTime - orderKey.startTime);

                    uint32 remainingTimeSinceLastUpdate = uint32(orderKey.endTime) - lastUpdateTime;

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
                if (block.timestamp < orderKey.endTime) {
                    remainingSellAmount = computeAmountFromSaleRate({
                        saleRate: saleRate,
                        duration: uint32(orderKey.endTime - FixedPointMathLib.max(orderKey.startTime, block.timestamp)),
                        roundUp: true
                    });
                }
            }
        }
    }

    /// @notice Handles lock callback data for order operations
    /// @dev Internal function that processes different types of order operations
    /// @param data Encoded operation data
    /// @return result Encoded result data
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        bytes1 callType = data[0];
        if (callType == 0xdd) {
            (, address recipientOrPayer, uint256 id, OrderKey memory orderKey, int256 saleRateDelta) =
                abi.decode(data, (bytes1, address, uint256, OrderKey, int256));

            int256 amount = abi.decode(
                forward(
                    address(TWAMM_EXTENSION),
                    abi.encode(
                        uint256(0),
                        ITWAMM.UpdateSaleRateParams({
                            salt: bytes32(id),
                            orderKey: orderKey,
                            saleRateDelta: int112(saleRateDelta)
                        })
                    )
                ),
                (int256)
            );

            if (amount != 0) {
                if (saleRateDelta > 0) {
                    if (orderKey.sellToken == NATIVE_TOKEN_ADDRESS) {
                        SafeTransferLib.safeTransferETH(address(ACCOUNTANT), uint256(amount));
                    } else {
                        ACCOUNTANT.payFrom(recipientOrPayer, orderKey.sellToken, uint256(amount));
                    }
                } else {
                    unchecked {
                        // we know amount will never exceed the uint128 type because of limitations on sale rate (fixed point 80.32) and duration (uint32)
                        ACCOUNTANT.withdraw(orderKey.sellToken, recipientOrPayer, uint128(uint256(-amount)));
                    }
                }
            }

            result = abi.encode(amount);
        } else if (callType == 0xff) {
            (, uint256 id, OrderKey memory orderKey, address recipient) =
                abi.decode(data, (bytes1, uint256, OrderKey, address));

            uint128 proceeds = abi.decode(
                forward(
                    address(TWAMM_EXTENSION),
                    abi.encode(uint256(1), ITWAMM.CollectProceedsParams({salt: bytes32(id), orderKey: orderKey}))
                ),
                (uint128)
            );

            if (proceeds != 0) {
                ACCOUNTANT.withdraw(orderKey.buyToken, recipient, proceeds);
            }

            result = abi.encode(proceeds);
        } else {
            revert UnexpectedCallTypeByte(callType);
        }
    }
}
