// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IOrders, EkuboRevenueBuybacks} from "../src/RevenueBuybacks.sol";

contract DeployRevenueBuybacks is Script {
    function run() public {
        address owner = vm.getWallets()[0];
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));
        IOrders orders = IOrders(payable(vm.envAddress("ORDERS_ADDRESS")));
        address buyToken = vm.envOr("BUY_TOKEN", address(0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f));

        vm.startBroadcast();

        new EkuboRevenueBuybacks{salt: salt}(core, owner, orders, buyToken);

        vm.stopBroadcast();
    }
}
