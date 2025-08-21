// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IOrders, EkuboRevenueBuybacks} from "../src/RevenueBuybacks.sol";

contract DeployRevenueBuybacks is Script {
    error UnrecognizedChainId();

    function run() public {
        address owner = vm.getWallets()[0];
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));
        IOrders orders = IOrders(payable(vm.envAddress("ORDERS_ADDRESS")));

        address buyToken;
        if (block.chainid == 1) buyToken = 0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f;
        else if (block.chainid == 11155111) buyToken = 0x618C25b11a5e9B5Ad60B04bb64FcBdfBad7621d1;
        else revert UnrecognizedChainId();

        vm.startBroadcast();

        new EkuboRevenueBuybacks{salt: salt}(core, owner, orders, buyToken);

        vm.stopBroadcast();
    }
}
