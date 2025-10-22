// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Script} from "forge-std/Script.sol";
import {Core} from "../src/Core.sol";
import {TWAMM, twammCallPoints} from "../src/extensions/TWAMM.sol";
import {Orders} from "../src/Orders.sol";
import {findExtensionSalt} from "./DeployCore.s.sol";

contract DeployTWAMMStatefulScript is Script {
    error UnrecognizedChainId(uint256 chainId);

    function run() public {
        address owner = vm.getWallets()[0];

        string memory ordersBaseUrl;
        if (block.chainid == 1) {
            ordersBaseUrl = vm.envOr("BASE_URL", string("https://eth-mainnet-api.ekubo.org/orders/nft/"));
        } else if (block.chainid == 11155111) {
            ordersBaseUrl = vm.envOr("BASE_URL", string("https://eth-sepolia-api.ekubo.org/orders/nft/"));
        } else {
            revert UnrecognizedChainId(block.chainid);
        }

        bytes32 salt = vm.envOr("SALT", bytes32(0x0));
        Core core = Core(payable(vm.envAddress("CORE_ADDRESS")));

        vm.startBroadcast();

        TWAMM twamm = new TWAMM{
            salt: findExtensionSalt(
                salt, keccak256(abi.encodePacked(type(TWAMM).creationCode, abi.encode(core))), twammCallPoints()
            )
        }(
            core
        );

        Orders orders = new Orders{salt: salt}(core, twamm, owner);
        orders.setMetadata(
            vm.envOr("ORDERS_CONTRACT_NAME", string("Ekubo DCA Orders")),
            vm.envOr("ORDERS_CONTRACT_SYMBOL", string("ekuOrd")),
            ordersBaseUrl
        );

        vm.stopBroadcast();
    }
}
