// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Router} from "../src/Router.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";
import {ScheduledLaunch, scheduledLaunchCallPoints} from "../src/extensions/ScheduledLaunch.sol";
import {deployExtension, deployIfNeeded} from "./DeployAll.s.sol";

/// @notice Deploys ScheduledLaunch, its LockedLaunchLiquidity and LaunchRouter onto a local fork of a chain
/// with Ekubo Core and TWAMM, and writes launchpad-manifest.json. Run through script/launchpad-local.sh.
/// @dev Local forks only. FORK_BLOCK and GIT_REVISION come from the wrapper.
contract DeployLaunchpadLocal is Script {
    bytes32 internal constant SALT = keccak256("ekubo launchpad local");

    error MissingDeployment(string name, address expected);

    function run() public {
        require(block.chainid != 0, "chain id");
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", address(0x00000000000014aA86C5d3c41765bb24e11bd701))));
        address twamm = vm.envOr("TWAMM_ADDRESS", address(0xd47f1B1eDCfEaBb08F6eBd8FC337c27E636C75BA));
        address mevCapture = vm.envOr("MEV_CAPTURE_ADDRESS", address(0x5555fF9Ff2757500BF4EE020DcfD0210CFfa41Be));
        if (address(core).code.length == 0) revert MissingDeployment("Core", address(core));
        if (twamm.code.length == 0) revert MissingDeployment("TWAMM", twamm);

        vm.startBroadcast();
        address router = vm.envOr("ROUTER_ADDRESS", address(0));
        if (router == address(0)) {
            (router,) = deployIfNeeded(
                abi.encodePacked(type(Router).creationCode, abi.encode(core, mevCapture, address(0))),
                SALT,
                address(0),
                "Router"
            );
        }
        (address extension,) = deployExtension(
            abi.encodePacked(type(ScheduledLaunch).creationCode, abi.encode(core, twamm)),
            SALT,
            scheduledLaunchCallPoints(),
            address(0),
            "ScheduledLaunch"
        );
        (address launchRouter,) = deployIfNeeded(
            abi.encodePacked(type(LaunchRouter).creationCode, abi.encode(core, extension)),
            SALT,
            address(0),
            "LaunchRouter"
        );
        vm.stopBroadcast();

        address liquidity = address(ScheduledLaunch(extension).LIQUIDITY());
        string memory contracts = "contracts";
        _entry(contracts, "core", address(core));
        _entry(contracts, "twamm", twamm);
        _entry(contracts, "scheduled_launch", extension);
        _entry(contracts, "locked_launch_liquidity", liquidity);
        _entry(contracts, "launch_router", launchRouter);
        contracts = _entry(contracts, "router", router);

        string memory manifest = "manifest";
        vm.serializeUint(manifest, "chain_id", block.chainid);
        vm.serializeUint(manifest, "fork_block", vm.envUint("FORK_BLOCK"));
        vm.serializeString(manifest, "git_revision", vm.envString("GIT_REVISION"));
        vm.serializeString(manifest, "abis", vm.envOr("ABI_DIR", string("launchpad-abis")));
        manifest = vm.serializeString(manifest, "contracts", contracts);
        vm.writeJson(manifest, vm.envOr("MANIFEST_PATH", string("launchpad-manifest.json")));
    }

    function _entry(string memory parent, string memory name, address target) internal returns (string memory) {
        vm.serializeAddress(name, "address", target);
        string memory entry = vm.serializeBytes32(name, "code_hash", target.codehash);
        return vm.serializeString(parent, name, entry);
    }
}
