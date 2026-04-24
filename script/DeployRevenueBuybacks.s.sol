// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {IPositions} from "../src/interfaces/IPositions.sol";
import {IOrders} from "../src/interfaces/IOrders.sol";
import {PositionsRevenueBuybacks} from "../src/PositionsRevenueBuybacks.sol";

contract DeployRevenueBuybacks is Script {
    error UnrecognizedChainId();

    function run() public {
        address owner = vm.envOr("OWNER_ADDRESS", vm.getWallets()[0]);
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));
        IPositions positions = IPositions(payable(vm.envAddress("POSITIONS_ADDRESS")));
        IOrders orders = IOrders(payable(vm.envAddress("ORDERS_ADDRESS")));
        address buyToken = vm.envAddress("BUY_TOKEN");

        vm.startBroadcast();
        new PositionsRevenueBuybacks{salt: salt}(owner, positions, orders, buyToken);
        vm.stopBroadcast();
    }
}
