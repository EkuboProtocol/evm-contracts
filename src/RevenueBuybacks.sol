// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {nextValidTime} from "./math/time.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {ICore, UsesCore} from "./base/UsesCore.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

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
}

struct BuybacksState {
    // New orders will last the minimum duration greater than the target order duration
    uint32 targetOrderDuration;
    // New orders will be created when the existing order cannot be used for new sales
    uint32 minOrderDuration;
    // The fee of the pool on which the order is placed
    uint64 fee;
    // The parameters of the last order that has been created
    uint64 lastEndTime;
    uint64 lastFee;
}

/// @title Revenue Buybacks
/// @author Moody Salem <moody@ekubo.org>
/// @notice Creates revenue buyback orders regularly according to specified configurations
contract RevenueBuybacks is UsesCore, Ownable, Multicallable {
    using CoreLib for *;

    // Used to create and manage the orders
    IOrders public immutable orders;
    // The ID of the token with which all the orders are associated
    uint256 public immutable nftId;
    // The token that is repurchased with revenue
    address public immutable buyToken;

    // Emitted when a token is re-configured
    event Configured(address token, uint32 targetOrderDuration, uint32 minOrderDuration, uint64 fee);

    // The current state of each of the buybacks
    mapping(address token => BuybacksState state) public states;

    constructor(ICore core, address owner, IOrders _orders, address _buyToken) UsesCore(core) {
        _initializeOwner(owner);
        orders = _orders;
        buyToken = _buyToken;
        nftId = orders.mint();
    }

    // Must be called at least once for each token to allow this contract to create orders
    function approveMax(address token) external {
        SafeTransferLib.safeApproveWithRetry(token, address(orders), type(uint256).max);
    }

    // Takes any leftover tokens held by this contract, only callable by owner
    function take(address token, uint256 amount) external onlyOwner {
        // we transfer to msg.sender because only the owner can call this function
        SafeTransferLib.safeTransfer(token, msg.sender, amount);
    }

    // Collects any buyback proceeds that have not yet been collected.
    function collect(address token, uint256 endTime) external {}

    function roll(address token) public {
        unchecked {
            BuybacksState memory state = states[token];
            // targetOrderDuration = 0 indicates we do not want to continue to sell this revenue token
            if (state.targetOrderDuration != 0) {
                uint256 amountCollected = core.protocolFeesCollected(token);
                if (amountCollected != 0) core.withdrawProtocolFees(address(this), token, amountCollected);

                uint256 amountToSpend = SafeTransferLib.balanceOf(token, address(this));

                if (amountToSpend != 0) {
                    uint64 currentTime = uint64(block.timestamp);
                    if (state.fee == state.lastFee && state.lastEndTime - currentTime < state.minOrderDuration) {
                        orders.increaseSellAmount(
                            nftId,
                            OrderKey({
                                sellToken: token,
                                buyToken: buyToken,
                                fee: state.fee,
                                startTime: 0,
                                endTime: state.lastEndTime
                            }),
                            uint128(amountCollected),
                            type(uint112).max
                        );
                    } else {
                        uint256 nextEndTime =
                            nextValidTime(block.timestamp, block.timestamp + state.targetOrderDuration);

                        orders.increaseSellAmount(
                            nftId,
                            OrderKey({
                                sellToken: token,
                                buyToken: buyToken,
                                fee: state.fee,
                                startTime: 0,
                                endTime: nextEndTime
                            }),
                            uint128(amountToSpend),
                            type(uint112).max
                        );

                        states[token].lastEndTime = uint64(nextEndTime);
                        states[token].lastFee = state.fee;
                    }
                }
            }
        }
    }

    function configure(address token, uint32 targetOrderDuration, uint32 minOrderDuration, uint64 fee) external {
        roll(token);

        BuybacksState storage state = states[token];
        (state.targetOrderDuration, state.minOrderDuration, state.fee) = (targetOrderDuration, minOrderDuration, fee);

        emit Configured(token, targetOrderDuration, minOrderDuration, fee);
    }
}
