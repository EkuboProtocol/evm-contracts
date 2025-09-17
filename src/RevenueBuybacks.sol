// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {nextValidTime} from "./math/time.sol";
import {IOrders} from "./interfaces/IOrders.sol";
import {IPositions} from "./interfaces/IPositions.sol";
import {OrderKey} from "./interfaces/extensions/ITWAMM.sol";

/// @notice Configuration and state for revenue buyback orders for a specific token
/// @dev Tracks the parameters and timing for automated buyback order creation
struct BuybacksState {
    /// @notice Target duration for new orders (in seconds)
    /// @dev New orders will be placed for the minimum duration that is larger than this target
    uint32 targetOrderDuration;
    /// @notice Minimum duration threshold for order creation (in seconds)
    /// @dev New orders will be created only if the last order duration is less than this threshold
    uint32 minOrderDuration;
    /// @notice Fee tier of the pool on which orders are placed
    /// @dev Expressed as a fraction where higher values represent higher fees
    uint64 fee;
    /// @notice End time of the last order that was created (timestamp)
    uint32 lastEndTime;
    /// @notice Duration of the last order that was created (in seconds)
    uint32 lastOrderDuration;
    /// @notice Fee tier of the last order that was created
    uint64 lastFee;
}

/// @title Revenue Buybacks
/// @author Moody Salem <moody@ekubo.org>
/// @notice Creates automated revenue buyback orders using TWAMM (Time-Weighted Average Market Maker)
/// @dev Abstract contract that manages the creation and execution of buyback orders for protocol revenue
/// This contract automatically creates TWAMM orders to buy back a specified token using collected revenue
abstract contract RevenueBuybacks is Ownable, Multicallable {
    /// @notice The Orders contract used to create and manage TWAMM orders
    /// @dev All buyback orders are created through this contract
    IOrders public immutable ORDERS;

    /// @notice The NFT token ID that represents all buyback orders created by this contract
    /// @dev A single NFT is minted and reused for all buyback orders to simplify management
    uint256 public immutable NFT_ID;

    /// @notice The token that is purchased with collected revenue
    /// @dev This is typically the protocol's governance or utility token
    address public immutable BUY_TOKEN;

    /// @notice Thrown when minimum order duration exceeds target order duration
    /// @dev This would prevent orders from being created since the condition would never be met
    error MinOrderDurationGreaterThanTargetOrderDuration();

    /// @notice Thrown when minimum order duration is set to zero
    /// @dev Orders cannot have zero duration, so this prevents invalid configurations
    error MinOrderDurationMustBeGreaterThanZero();

    /// @notice Emitted when a token's buyback configuration is updated
    /// @param token The token being configured for buybacks
    /// @param targetOrderDuration The target duration for new orders
    /// @param minOrderDuration The minimum duration threshold for creating new orders
    /// @param fee The fee tier for the buyback pool
    event Configured(address token, uint32 targetOrderDuration, uint32 minOrderDuration, uint64 fee);

    /// @notice Maps each revenue token to its buyback configuration and state
    /// @dev Tracks the parameters and timing for automated buyback order creation
    mapping(address token => BuybacksState state) public states;

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
    /// @dev Used to recover tokens that may be stuck in the contract or to withdraw excess funds
    /// @param token The address of the token to withdraw
    /// @param amount The amount of tokens to withdraw
    function take(address token, uint256 amount) external onlyOwner {
        // Transfer to msg.sender since only the owner can call this function
        SafeTransferLib.safeTransfer(token, msg.sender, amount);
    }

    /// @notice Collects the proceeds from a completed buyback order
    /// @dev Can be called by anyone at any time to collect proceeds from orders that have finished
    /// @param token The revenue token that was sold in the order
    /// @param fee The fee tier of the pool where the order was executed
    /// @param endTime The end time of the order to collect proceeds from
    /// @return proceeds The amount of buyToken received from the completed order
    function collect(address token, uint64 fee, uint256 endTime) external returns (uint128 proceeds) {
        proceeds = ORDERS.collectProceeds(
            NFT_ID, OrderKey({sellToken: token, buyToken: BUY_TOKEN, fee: fee, startTime: 0, endTime: endTime}), owner()
        );
    }

    /// @notice Allows the contract to receive ETH revenue
    /// @dev Required to accept ETH payments when ETH is used as a revenue token
    receive() external payable {}

    /// @notice Creates a new buyback order or extends an existing one with available revenue
    /// @dev Can be called by anyone to trigger the creation of buyback orders using collected revenue
    /// This function will either extend the current order (if conditions are met) or create a new order
    /// @param token The revenue token to use for creating the buyback order
    /// @return endTime The end time of the order that was created or extended
    /// @return saleRate The sale rate of the order (amount of token sold per second)
    function roll(address token) public returns (uint256 endTime, uint112 saleRate) {
        unchecked {
            BuybacksState memory state = states[token];
            // minOrderDuration == 0 indicates the token is not configured
            if (state.minOrderDuration != 0) {
                bool isEth = token == address(0);
                uint256 amountToSpend = isEth ? address(this).balance : SafeTransferLib.balanceOf(token, address(this));

                uint32 timeRemaining = state.lastEndTime - uint32(block.timestamp);
                // if the fee changed, or the amount of time exceeds the min order duration
                // note the time remaining can underflow if the last order has ended. in this case time remaining will be greater than min order duration,
                // but also greater than last order duration, so it will not be re-used.
                if (
                    state.fee == state.lastFee && timeRemaining >= state.minOrderDuration
                        && timeRemaining <= state.lastOrderDuration
                ) {
                    // handles overflow
                    endTime = block.timestamp + uint256(timeRemaining);
                } else {
                    endTime = nextValidTime(block.timestamp, block.timestamp + uint256(state.targetOrderDuration) - 1);

                    states[token].lastEndTime = uint32(endTime);
                    states[token].lastOrderDuration = uint32(endTime - block.timestamp);
                    states[token].lastFee = state.fee;
                }

                if (amountToSpend != 0) {
                    saleRate = ORDERS.increaseSellAmount{value: isEth ? amountToSpend : 0}(
                        NFT_ID,
                        OrderKey({sellToken: token, buyToken: BUY_TOKEN, fee: state.fee, startTime: 0, endTime: endTime}),
                        uint128(amountToSpend),
                        type(uint112).max
                    );
                }
            }
        }
    }

    /// @notice Checks if a token has been configured for buybacks
    /// @dev A token is considered configured if its minOrderDuration is non-zero
    /// @param token The token to check configuration for
    /// @return True if the token is configured for buybacks, false otherwise
    function isConfigured(address token) internal view returns (bool) {
        return states[token].minOrderDuration != 0;
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
        if (minOrderDuration == 0) revert MinOrderDurationMustBeGreaterThanZero();

        // First run roll so that tokens accrued up until now are treated according to the old rules
        roll(token);

        // Then apply the configuration change
        BuybacksState storage state = states[token];
        (state.targetOrderDuration, state.minOrderDuration, state.fee) = (targetOrderDuration, minOrderDuration, fee);
        emit Configured(token, targetOrderDuration, minOrderDuration, fee);
    }
}

/// @title Ekubo Revenue Buybacks
/// @notice Concrete implementation of RevenueBuybacks for the Ekubo Protocol
/// @dev Integrates with the Positions contract to collect protocol fees and create buyback orders
contract EkuboRevenueBuybacks is RevenueBuybacks {
    /// @notice Thrown when attempting to withdraw tokens that are not configured for buybacks
    /// @dev At least one of the tokens in a pair must be configured to allow withdrawal
    error RevenueTokenNotConfigured();

    /// @notice The Positions contract used to collect protocol fees
    /// @dev Protocol fees are collected from this contract and used to fund buyback orders
    IPositions public immutable POSITIONS;

    /// @notice Constructs the EkuboRevenueBuybacks contract
    /// @param _positions The Positions contract instance for collecting protocol fees
    /// @param owner The address that will own this contract
    /// @param orders The Orders contract instance for creating TWAMM orders
    /// @param buyToken The token that will be purchased with collected revenue
    constructor(IPositions _positions, address owner, IOrders orders, address buyToken)
        RevenueBuybacks(owner, orders, buyToken)
    {
        POSITIONS = _positions;
    }

    /// @notice Reclaims ownership of the Positions contract
    /// @dev Transfers ownership of the Positions contract to the caller (must be owner)
    /// This is used when the Positions contract should be owned by this buybacks contract
    function reclaim() external onlyOwner {
        Ownable(address(POSITIONS)).transferOwnership(msg.sender);
    }

    /// @notice Withdraws available protocol fees from the Positions contract
    /// @dev Must be called before roll() to collect revenue tokens that can be used for buybacks
    /// At least one of the tokens must be configured for buybacks
    /// @param token0 The first token of the pair to withdraw fees for
    /// @param token1 The second token of the pair to withdraw fees for
    function withdrawAvailableTokens(address token0, address token1) external {
        if (!isConfigured(token0) && !isConfigured(token1)) revert RevenueTokenNotConfigured();

        (uint128 amount0, uint128 amount1) = POSITIONS.getProtocolFees(token0, token1);
        if (amount0 != 0 || amount1 != 0) {
            POSITIONS.withdrawProtocolFees(token0, token1, amount0, amount1, address(this));
        }
    }
}
