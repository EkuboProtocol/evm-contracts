// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Positions} from "../src/Positions.sol";

contract DeployStatefulScript is Script {
    error UnrecognizedChainId(uint256 chainId);

    function run() public {
        address owner = vm.getWallets()[0];

        string memory baseUrl;
        if (block.chainid == 1) {
            baseUrl = vm.envOr("BASE_URL", string("https://eth-mainnet-api.ekubo.org/positions/nft/"));
        } else if (block.chainid == 11155111) {
            baseUrl = vm.envOr("BASE_URL", string("https://eth-sepolia-api.ekubo.org/positions/nft/"));
        } else {
            revert UnrecognizedChainId(block.chainid);
        }

        bytes32 salt = vm.envOr("SALT", bytes32(0x0));
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));

        vm.startBroadcast();

        Positions positions = new Positions{salt: salt}(core, owner, 0, 1);
        positions.setMetadata(
            vm.envOr("POSITIONS_CONTRACT_NAME", string("Ekubo Positions")),
            vm.envOr("POSITIONS_CONTRACT_SYMBOL", string("ekuPo")),
            baseUrl
        );

        vm.stopBroadcast();
    }
}
