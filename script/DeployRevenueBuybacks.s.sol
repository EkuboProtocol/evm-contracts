// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {IPositions} from "../src/interfaces/IPositions.sol";
import {IOrders} from "../src/interfaces/IOrders.sol";
import {PositionsRevenueBuybacks} from "../src/PositionsRevenueBuybacks.sol";

contract DeployRevenueBuybacks is Script {
    error UnrecognizedChainId();

    address internal constant DEFAULT_POSITIONS = 0x02D9876A21AF7545f8632C3af76eC90b5ad4b66D;
    address internal constant DEFAULT_ORDERS = 0xfF6cF0Ca6d7a30a60539AcD4bB20B3df84EA0644;

    function run() public {
        address owner = vm.envOr("OWNER_ADDRESS", vm.getWallets()[0]);
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));
        IPositions positions = IPositions(payable(vm.envOr("POSITIONS_ADDRESS", payable(DEFAULT_POSITIONS))));
        IOrders orders = IOrders(payable(vm.envOr("ORDERS_ADDRESS", payable(DEFAULT_ORDERS))));
        address buyToken = vm.envAddress("BUY_TOKEN");

        vm.startBroadcast();
        new PositionsRevenueBuybacks{salt: salt}(owner, positions, orders, buyToken);
        vm.stopBroadcast();
    }
}
