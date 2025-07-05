// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";

interface IOrders {
    function mint() public payable returns (uint256 id);
}

/// @title Revenue Buybacks
/// @author Moody Salem <moody@ekubo.org>
/// @notice Creates revenue buyback orders regularly according to specified configurations
contract RevenueBuybacks is Ownable {
    IOrders public immutable orders;

    constructor(IOrders _orders) {
        orders = _orders;
    }
}
