// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";

interface IOrders {
    function mint() external payable returns (uint256 id);
}

struct Config {
    address buyToken;
    uint32 minOrderDuration;
    uint32 targetOrderDuration;
    uint64 fee;
}

/// @title Revenue Buybacks
/// @author Moody Salem <moody@ekubo.org>
/// @notice Creates revenue buyback orders regularly according to specified configurations
contract RevenueBuybacks is Ownable {
    IOrders public immutable orders;
    uint256 public immutable nftId;

    event Configured(address revenueToken, Config config);

    mapping(address revenueToken => Config config) public configs;

    struct State {
        uint64 startTime;
        uint64 endTime;
    }

    mapping(address revenueToken => State state) public state;

    constructor(IOrders _orders, address owner) {
        _initializeOwner(owner);
        orders = _orders;
        nftId = orders.mint();
    }

    function push(address revenueToken) public {
        Config memory c = configs[revenueToken];
        if (c.targetOrderDuration != 0) {}
    }

    function configure(address revenueToken, Config config) external {
        push(revenueToken);

        config[revenueToken] = config;

        emit Configured(revenueToken, config);
    }
}
