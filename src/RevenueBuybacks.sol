// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {nextValidTime} from "./math/time.sol";
import {Positions} from "./Positions.sol";

struct OrderKey {
    address sellToken;
    address buyToken;
    uint64 fee;
    uint256 startTime;
    uint256 endTime;
}

interface IOrders {
    function mint() external payable returns (uint256 id);

    function increaseSellAmount(uint256 id, OrderKey memory orderKey, uint128 amount, uint112 maxSaleRate)
        external
        payable
        returns (uint112 saleRate);

    function collectProceeds(uint256 id, OrderKey memory orderKey, address recipient)
        external
        payable
        returns (uint128 proceeds);
}

struct BuybacksState {
    // New orders will be placed for the minimum duration that is larger than the target order duration
    uint32 targetOrderDuration;
    // New orders will be created iff the last order that was created has a duration less than minOrderDuration
    uint32 minOrderDuration;
    // The fee of the pool on which the order is placed.
    uint64 fee;
    // The parameters of the last order that was created.
    uint32 lastEndTime;
    uint32 lastOrderDuration;
    uint64 lastFee;
}

/// @title Revenue Buybacks
/// @author Moody Salem <moody@ekubo.org>
/// @notice Creates revenue buyback orders regularly according to specified configurations
abstract contract RevenueBuybacks is Ownable, Multicallable {
    // Used to create and manage the orders
    IOrders public immutable orders;
    // The ID of the token with which all the orders are associated
    uint256 public immutable nftId;
    // The token that is repurchased with revenue
    address public immutable buyToken;

    // The minimum order duration cannot be greater than the target order duration since that would prevent orders from being created.
    error MinOrderDurationGreaterThanTargetOrderDuration();
    // The minimum order duration must be greater than zero because orders cannot have a zero duration.
    error MinOrderDurationMustBeGreaterThanZero();

    // Emitted when a token is re-configured
    event Configured(address token, uint32 targetOrderDuration, uint32 minOrderDuration, uint64 fee);

    // The current state of each of the buybacks
    mapping(address token => BuybacksState state) public states;

    constructor(address owner, IOrders _orders, address _buyToken) {
        _initializeOwner(owner);
        orders = _orders;
        buyToken = _buyToken;
        nftId = orders.mint();
    }

    // Must be called at least once for each token to allow this contract to create orders.
    function approveMax(address token) external {
        SafeTransferLib.safeApproveWithRetry(token, address(orders), type(uint256).max);
    }

    // Takes any leftover tokens held by this contract, only callable by owner
    function take(address token, uint256 amount) external onlyOwner {
        // we transfer to msg.sender because only the owner can call this function
        SafeTransferLib.safeTransfer(token, msg.sender, amount);
    }

    // Collects buyback proceeds for order ending at the given time.
    // This may be called by anyone at any time.
    function collect(address token, uint64 fee, uint256 endTime) external returns (uint128 proceeds) {
        proceeds = orders.collectProceeds(
            nftId, OrderKey({sellToken: token, buyToken: buyToken, fee: fee, startTime: 0, endTime: endTime}), owner()
        );
    }

    // Necessary to withdraw available tokens in ETH
    receive() external payable {}

    // Anyone can call this to move the collected proceeds into the current order,
    // or creates a new one if the current order has not collected proceeds.
    function roll(address token) public returns (uint256 endTime, uint112 saleRate) {
        unchecked {
            BuybacksState memory state = states[token];
            // minOrderDuration == 0 indicates the token is not configured
            if (state.minOrderDuration != 0) {
                bool isETH = token == address(0);
                uint256 amountToSpend = isETH ? address(this).balance : SafeTransferLib.balanceOf(token, address(this));

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
                    saleRate = orders.increaseSellAmount{value: isETH ? amountToSpend : 0}(
                        nftId,
                        OrderKey({sellToken: token, buyToken: buyToken, fee: state.fee, startTime: 0, endTime: endTime}),
                        uint128(amountToSpend),
                        type(uint112).max
                    );
                }
            }
        }
    }

    function configure(address token, uint32 targetOrderDuration, uint32 minOrderDuration, uint64 fee)
        external
        onlyOwner
    {
        if (minOrderDuration > targetOrderDuration) revert MinOrderDurationGreaterThanTargetOrderDuration();
        if (minOrderDuration == 0) revert MinOrderDurationMustBeGreaterThanZero();

        // we first run roll so that tokens accrued up until now are treated according to the old rules
        roll(token);

        // then we effect the configuration change
        BuybacksState storage state = states[token];
        (state.targetOrderDuration, state.minOrderDuration, state.fee) = (targetOrderDuration, minOrderDuration, fee);
        emit Configured(token, targetOrderDuration, minOrderDuration, fee);
    }
}

contract EkuboRevenueBuybacks is RevenueBuybacks {
    Positions public immutable positions;

    constructor(Positions _positions, address owner, IOrders orders, address buyToken)
        RevenueBuybacks(owner, orders, buyToken)
    {
        positions = _positions;
    }

    // Reclaims ownership of the Core contract that is meant to be owned by this one.
    function reclaim() external onlyOwner {
        Ownable(address(positions)).transferOwnership(msg.sender);
    }

    /// @notice Must be called before roll in order to collect revenue
    function withdrawAvailableTokens(address token0, address token1) external {
        (uint128 amount0, uint128 amount1) = positions.getProtocolFees(token0, token1);
        if (amount0 != 0 || amount1 != 0) {
            positions.withdrawProtocolFees(token0, token1, amount0, amount1, address(this));
        }
    }
}
