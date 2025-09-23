// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {IPositions} from "../src/interfaces/IPositions.sol";
import {IOrders} from "../src/interfaces/IOrders.sol";
import {RevenueBuybacks} from "../src/RevenueBuybacks.sol";
import {PositionsOwner} from "../src/PositionsOwner.sol";

contract DeployRevenueBuybacks is Script {
    error UnrecognizedChainId();

    function run() public {
        address owner = vm.getWallets()[0];
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));
        IPositions positions = IPositions(payable(vm.envAddress("POSITIONS_ADDRESS")));
        IOrders orders = IOrders(payable(vm.envAddress("ORDERS_ADDRESS")));

        address buyToken;
        if (block.chainid == 1) buyToken = 0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f;
        else if (block.chainid == 11155111) buyToken = 0x618C25b11a5e9B5Ad60B04bb64FcBdfBad7621d1;
        else revert UnrecognizedChainId();

        vm.startBroadcast();

        // Deploy the revenue buybacks contract
        RevenueBuybacks revenueBuybacks = new RevenueBuybacks{salt: salt}(owner, orders, buyToken);

        // Deploy the positions owner contract with the buybacks contract address
        PositionsOwner positionsOwner =
            new PositionsOwner{salt: keccak256(abi.encode(salt, "PositionsOwner"))}(owner, positions, revenueBuybacks);

        vm.stopBroadcast();
    }
}
