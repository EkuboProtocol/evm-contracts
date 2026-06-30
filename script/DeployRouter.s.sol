// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Router} from "../src/Router.sol";
import {deployIfNeeded} from "./DeployAll.s.sol";

/// @title DeployRouter
/// @notice Deploys the router with optional MEVCapture and Ve33 extension support.
contract DeployRouter is Script {
    address internal constant DEFAULT_CORE_ADDRESS = 0x00000000000014aA86C5d3c41765bb24e11bd701;
    address internal constant DEFAULT_MEV_CAPTURE_ADDRESS = 0x5555fF9Ff2757500BF4EE020DcfD0210CFfa41Be;
    bytes32 internal constant DEFAULT_DEPLOYMENT_SALT =
        0x38e2e731c4e6738213b17b239fe56c423f6bdc5b5969897c260d464c35a63982;

    function run() public {
        bytes32 salt = vm.envOr("SALT", DEFAULT_DEPLOYMENT_SALT);
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(DEFAULT_CORE_ADDRESS))));
        address mevCapture = vm.envOr("MEV_CAPTURE_ADDRESS", DEFAULT_MEV_CAPTURE_ADDRESS);
        address ve33 = vm.envOr("VE33_ADDRESS", address(0));
        address expectedRouter = vm.envOr("ROUTER_ADDRESS", address(0));

        vm.startBroadcast();

        deployIfNeeded(
            abi.encodePacked(type(Router).creationCode, abi.encode(core, mevCapture, ve33)),
            salt,
            expectedRouter,
            "Router"
        );

        vm.stopBroadcast();
    }
}
