// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {deployIfNeeded} from "./DeployAll.s.sol";
import {TWAMMJITCancel} from "../src/TWAMMJITCancel.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IOrders} from "../src/interfaces/IOrders.sol";
import {ITWAMM} from "../src/interfaces/extensions/ITWAMM.sol";

bytes32 constant TWAMM_JIT_CANCEL_DEPLOYMENT_SALT = 0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;

/// @notice Deploys TWAMMJITCancel for v3.1.0 TWAMM order cancellation.
contract DeployTWAMMJITCancel is Script {
    function run() public {
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(0x00000000000014aA86C5d3c41765bb24e11bd701))));
        IOrders orders = IOrders(vm.envOr("ORDERS_ADDRESS", address(0xfF6cF0Ca6d7a30a60539AcD4bB20B3df84EA0644)));
        ITWAMM twamm = ITWAMM(vm.envOr("TWAMM_ADDRESS", address(0xd4F1060cB9c1A13e1d2d20379b8aa2cF7541eD9b)));

        address expectedAddress = vm.envOr("EXPECTED_ADDRESS", address(0));

        vm.startBroadcast();

        deployIfNeeded(
            abi.encodePacked(type(TWAMMJITCancel).creationCode, abi.encode(core, orders, twamm)),
            TWAMM_JIT_CANCEL_DEPLOYMENT_SALT,
            expectedAddress,
            "TWAMMJITCancel"
        );

        vm.stopBroadcast();
    }
}
