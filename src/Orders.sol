// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IOrders} from "./interfaces/IOrders.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {TWAMMLib} from "./libraries/TWAMMLib.sol";
import {ITWAMM} from "./interfaces/extensions/ITWAMM.sol";
import {OrderKey} from "./types/orderKey.sol";
import {computeSaleRate} from "./math/twamm.sol";
import {BaseNonfungibleToken} from "./base/BaseNonfungibleToken.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
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

    uint256 private constant CALL_TYPE_CHANGE_SALE_RATE = 0;
    uint256 private constant CALL_TYPE_COLLECT_PROCEEDS = 1;

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
        uint256 realStart = FixedPointMathLib.max(block.timestamp, orderKey.config.startTime());

        unchecked {
            if (orderKey.config.endTime() <= realStart) {
                revert OrderAlreadyEnded();
            }

            saleRate = uint112(computeSaleRate(amount, uint32(orderKey.config.endTime() - realStart)));

            if (saleRate > maxSaleRate) {
                revert MaxSaleRateExceeded();
            }
        }

        lock(abi.encode(CALL_TYPE_CHANGE_SALE_RATE, msg.sender, id, orderKey, saleRate));
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
                    lock(
                        abi.encode(
                            CALL_TYPE_CHANGE_SALE_RATE, recipient, id, orderKey, -int256(uint256(saleRateDecrease))
                        )
                    ),
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
        proceeds = abi.decode(lock(abi.encode(CALL_TYPE_COLLECT_PROCEEDS, id, orderKey, recipient)), (uint128));
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
        (saleRate, amountSold, remainingSellAmount, purchasedAmount) =
            TWAMM_EXTENSION.executeVirtualOrdersAndGetCurrentOrderInfo(address(this), bytes32(id), orderKey);
    }

    /// @notice Handles lock callback data for order operations
    /// @dev Internal function that processes different types of order operations
    /// @param data Encoded operation data
    /// @return result Encoded result data
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_CHANGE_SALE_RATE) {
            (, address recipientOrPayer, uint256 id, OrderKey memory orderKey, int256 saleRateDelta) =
                abi.decode(data, (uint256, address, uint256, OrderKey, int256));

            int256 amount =
                CORE.updateSaleRate(TWAMM_EXTENSION, bytes32(id), orderKey, SafeCastLib.toInt112(saleRateDelta));

            if (amount != 0) {
                address sellToken = orderKey.sellToken();
                if (saleRateDelta > 0) {
                    if (sellToken == NATIVE_TOKEN_ADDRESS) {
                        SafeTransferLib.safeTransferETH(address(ACCOUNTANT), uint256(amount));
                    } else {
                        ACCOUNTANT.payFrom(recipientOrPayer, sellToken, uint256(amount));
                    }
                } else {
                    unchecked {
                        // we know amount will never exceed the uint128 type because of limitations on sale rate (fixed point 80.32) and duration (uint32)
                        ACCOUNTANT.withdraw(sellToken, recipientOrPayer, uint128(uint256(-amount)));
                    }
                }
            }

            result = abi.encode(amount);
        } else if (callType == CALL_TYPE_COLLECT_PROCEEDS) {
            (, uint256 id, OrderKey memory orderKey, address recipient) =
                abi.decode(data, (uint256, uint256, OrderKey, address));

            uint128 proceeds = CORE.collectProceeds(TWAMM_EXTENSION, bytes32(id), orderKey);

            if (proceeds != 0) {
                ACCOUNTANT.withdraw(orderKey.buyToken(), recipient, proceeds);
            }

            result = abi.encode(proceeds);
        } else {
            revert();
        }
    }
}
