// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

import {Ownable} from "solady/auth/Ownable.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {nextValidTime} from "./math/time.sol";
import {IOrders} from "./interfaces/IOrders.sol";
import {IRevenueBuybacks} from "./interfaces/IRevenueBuybacks.sol";
import {BuybacksState, createBuybacksState} from "./types/buybacksState.sol";
import {OrderKey} from "./types/orderKey.sol";
import {createOrderConfig} from "./types/orderConfig.sol";
import {ExposedStorage} from "./base/ExposedStorage.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";

/// @title Revenue Buybacks
/// @author Moody Salem <moody@ekubo.org>
/// @notice Creates automated revenue buyback orders using TWAMM (Time-Weighted Average Market Maker)
/// @dev Final contract that manages the creation and execution of buyback orders for protocol revenue
/// This contract automatically creates TWAMM orders to buy back a specified token using collected revenue
contract RevenueBuybacks is IRevenueBuybacks, ExposedStorage, Ownable, Multicallable {
    /// @notice The Orders contract used to create and manage TWAMM orders
    /// @dev All buyback orders are created through this contract
    IOrders public immutable ORDERS;

    /// @notice The NFT token ID that represents all buyback orders created by this contract
    /// @dev A single NFT is minted and reused for all buyback orders to simplify management
    uint256 public immutable NFT_ID;

    /// @notice The token that is purchased with collected revenue
    /// @dev This is typically the protocol's governance or utility token
    address public immutable BUY_TOKEN;

    /// @notice Constructs the RevenueBuybacks contract
    /// @param owner The address that will own this contract and have administrative privileges
    /// @param _orders The Orders contract instance for creating TWAMM orders
    /// @param _buyToken The token that will be purchased with collected revenue
    constructor(address owner, IOrders _orders, address _buyToken) {
        _initializeOwner(owner);
        ORDERS = _orders;
        BUY_TOKEN = _buyToken;
        NFT_ID = ORDERS.mint();
    }

    /// @notice Approves the Orders contract to spend unlimited amounts of a token
    /// @dev Must be called at least once for each revenue token before creating buyback orders
    /// @param token The token to approve for spending by the Orders contract
    function approveMax(address token) external {
        SafeTransferLib.safeApproveWithRetry(token, address(ORDERS), type(uint256).max);
    }

    /// @notice Withdraws leftover tokens from the contract (only callable by owner)
    /// @dev Used to recover tokens that may be stuck in the contract
    /// @param token The address of the token to withdraw
    /// @param amount The amount of tokens to withdraw
    function take(address token, uint256 amount) external onlyOwner {
        // Transfer to msg.sender since only the owner can call this function
        SafeTransferLib.safeTransfer(token, msg.sender, amount);
    }

    /// @notice Withdraws native tokens held by this contract
    /// @dev Used to recover native tokens that may be stuck in the contract
    /// @param amount The amount of native tokens to withdraw
    function takeNative(uint256 amount) external onlyOwner {
        // Transfer to msg.sender since only the owner can call this function
        SafeTransferLib.safeTransferETH(msg.sender, amount);
    }

    /// @notice Collects the proceeds from a completed buyback order
    /// @dev Can be called by anyone at any time to collect proceeds from orders that have finished
    /// @param token The revenue token that was sold in the order
    /// @param fee The fee tier of the pool where the order was executed
    /// @param endTime The end time of the order to collect proceeds from
    /// @return proceeds The amount of buyToken received from the completed order
    function collect(address token, uint64 fee, uint64 endTime) external returns (uint128 proceeds) {
        proceeds = ORDERS.collectProceeds(NFT_ID, _createOrderKey(token, fee, 0, endTime), owner());
    }

    /// @notice Allows the contract to receive ETH revenue
    /// @dev Required to accept ETH payments when ETH is used as a revenue token
    receive() external payable {}

    /// @notice Creates a new buyback order or extends an existing one with available revenue
    /// @dev Can be called by anyone to trigger the creation of buyback orders using collected revenue
    /// This function will either extend the current order (if conditions are met) or create a new order
    /// @param token The revenue token to use for creating the buyback order, or NATIVE_TOKEN_ADDRESS
    /// @return endTime The end time of the order that was created or extended
    /// @return saleRate The sale rate of the order (amount of token sold per second)
    function roll(address token) public returns (uint64 endTime, uint112 saleRate) {
        unchecked {
            BuybacksState state;
            assembly ("memory-safe") {
                state := sload(token)
            }

            if (!state.isConfigured()) {
                revert TokenNotConfigured(token);
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
                    sstore(token, state)
                }
            }

            if (amountToSpend != 0) {
                saleRate = ORDERS.increaseSellAmount{value: isEth ? amountToSpend : 0}(
                    NFT_ID, _createOrderKey(token, state.fee(), 0, endTime), uint128(amountToSpend), type(uint112).max
                );
            }
        }
    }

    /// @notice Configures buyback parameters for a revenue token (only callable by owner)
    /// @dev Sets the timing and fee parameters for automated buyback order creation
    /// @param token The revenue token to configure
    /// @param targetOrderDuration The target duration for new orders (in seconds)
    /// @param minOrderDuration The minimum duration threshold for creating new orders (in seconds)
    /// @param fee The fee tier for the buyback pool
    function configure(address token, uint32 targetOrderDuration, uint32 minOrderDuration, uint64 fee)
        external
        onlyOwner
    {
        if (minOrderDuration > targetOrderDuration) revert MinOrderDurationGreaterThanTargetOrderDuration();
        if (minOrderDuration == 0 && targetOrderDuration != 0) {
            revert MinOrderDurationMustBeGreaterThanZero();
        }

        BuybacksState state;
        assembly ("memory-safe") {
            state := sload(token)
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
            sstore(token, state)
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
