// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {nextValidTime} from "../math/time.sol";
import {BaseOwnableExecutor} from "./BaseOwnableExecutor.sol";
import {IOrders} from "../interfaces/IOrders.sol";
import {IRevenueBuybacks} from "../interfaces/IRevenueBuybacks.sol";
import {RevenueBuybacksStorageLayout} from "../libraries/RevenueBuybacksStorageLayout.sol";
import {BuybacksState, createBuybacksState} from "../types/buybacksState.sol";
import {OrderKey} from "../types/orderKey.sol";
import {createOrderConfig} from "../types/orderConfig.sol";
import {ExposedStorage} from "./ExposedStorage.sol";
import {NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {StorageSlot} from "../types/storageSlot.sol";

/// @title Revenue Buybacks
/// @author Moody Salem <moody@ekubo.org>
/// @notice Creates revenue buyback orders using TWAMM (Time-Weighted Average Market Maker)
/// @dev Intended to be inherited by contracts that define how revenue is routed into this contract for buybacks
abstract contract RevenueBuybacks is IRevenueBuybacks, ExposedStorage, BaseOwnableExecutor {
    /// @inheritdoc IRevenueBuybacks
    IOrders public immutable ORDERS;

    /// @inheritdoc IRevenueBuybacks
    uint256 public immutable NFT_ID;

    /// @inheritdoc IRevenueBuybacks
    address public immutable BUY_TOKEN;

    /// @notice Constructs the RevenueBuybacks contract
    /// @param owner The address that will own this contract and have administrative privileges
    /// @param _orders The Orders contract instance for creating TWAMM orders
    /// @param _buyToken The token that will be purchased with collected revenue
    constructor(address owner, IOrders _orders, address _buyToken) BaseOwnableExecutor(owner) {
        ORDERS = _orders;
        BUY_TOKEN = _buyToken;
        NFT_ID = ORDERS.mint();
    }

    /// @inheritdoc IRevenueBuybacks
    function approveMax(address token) external {
        SafeTransferLib.safeApproveWithRetry(token, address(ORDERS), type(uint256).max);
    }

    /// @inheritdoc IRevenueBuybacks
    function collect(address token, uint64 fee, uint64 endTime) external returns (uint128 proceeds) {
        proceeds = ORDERS.collectProceeds(NFT_ID, _createOrderKey(token, fee, 0, endTime), owner());
    }

    /// @inheritdoc IRevenueBuybacks
    function roll(address token) external returns (uint64 endTime, uint112 saleRate) {
        // buy token cannot be configured for buybacks, so we short circuit to save an sload
        if (token == BUY_TOKEN) {
            return (0, 0);
        }

        unchecked {
            BuybacksState state;
            StorageSlot slot = RevenueBuybacksStorageLayout.stateSlot(token);
            assembly ("memory-safe") {
                state := sload(slot)
            }

            if (!state.isConfigured()) {
                return (0, 0);
            }

            // minOrderDuration == 0 indicates the token is not configured
            bool isEth = token == NATIVE_TOKEN_ADDRESS;
            uint256 amountToSpend = isEth ? address(this).balance : SafeTransferLib.balanceOf(token, address(this));

            uint32 timeRemaining = state.lastEndTime() - uint32(block.timestamp);
            // if the fee changed, or the amount of time exceeds the min order duration
            // note the time remaining can underflow if the last order has ended. in this case time remaining will be greater than min order duration,
            // but also greater than last order duration, so it will not be re-used.
            if (
                state.fee() == state.lastFee() && timeRemaining >= state.minOrderDuration()
                    && timeRemaining <= state.lastOrderDuration()
            ) {
                // handles overflow
                endTime = uint64(block.timestamp + timeRemaining);
            } else {
                endTime =
                    uint64(nextValidTime(block.timestamp, block.timestamp + uint256(state.targetOrderDuration()) - 1));

                state = createBuybacksState({
                    _targetOrderDuration: state.targetOrderDuration(),
                    _minOrderDuration: state.minOrderDuration(),
                    _fee: state.fee(),
                    _lastEndTime: uint32(endTime),
                    _lastOrderDuration: uint32(endTime - block.timestamp),
                    _lastFee: state.fee()
                });

                assembly ("memory-safe") {
                    sstore(slot, state)
                }
            }

            if (amountToSpend != 0) {
                saleRate = ORDERS.increaseSellAmount{value: isEth ? amountToSpend : 0}(
                    NFT_ID, _createOrderKey(token, state.fee(), 0, endTime), uint128(amountToSpend), type(uint112).max
                );
            }
        }
    }

    /// @inheritdoc IRevenueBuybacks
    function configure(address token, uint32 targetOrderDuration, uint32 minOrderDuration, uint64 fee)
        external
        onlySelf
    {
        if (token == BUY_TOKEN) revert CannotConfigureForBuyToken();
        if (minOrderDuration > targetOrderDuration) revert MinOrderDurationGreaterThanTargetOrderDuration();
        if (minOrderDuration == 0 && targetOrderDuration != 0) {
            revert MinOrderDurationMustBeGreaterThanZero();
        }

        BuybacksState state;
        StorageSlot slot = RevenueBuybacksStorageLayout.stateSlot(token);
        assembly ("memory-safe") {
            state := sload(slot)
        }
        state = createBuybacksState({
            _targetOrderDuration: targetOrderDuration,
            _minOrderDuration: minOrderDuration,
            _fee: fee,
            _lastEndTime: state.lastEndTime(),
            _lastOrderDuration: state.lastOrderDuration(),
            _lastFee: state.lastFee()
        });
        assembly ("memory-safe") {
            sstore(slot, state)
        }

        emit Configured(token, state);
    }

    function _createOrderKey(address token, uint64 fee, uint64 startTime, uint64 endTime)
        internal
        view
        returns (OrderKey memory key)
    {
        bool isToken1 = token > BUY_TOKEN;
        address buyToken = BUY_TOKEN;
        assembly ("memory-safe") {
            mstore(add(key, mul(isToken1, 32)), token)
            mstore(add(key, mul(iszero(isToken1), 32)), buyToken)
        }

        key.config = createOrderConfig({_fee: fee, _isToken1: isToken1, _startTime: startTime, _endTime: endTime});
    }
}
