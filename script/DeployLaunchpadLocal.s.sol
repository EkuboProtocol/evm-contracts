// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "../src/interfaces/ICore.sol";
import {ScheduledLaunch} from "../src/extensions/ScheduledLaunch.sol";
import {DeployScheduledLaunch} from "./DeployScheduledLaunch.s.sol";

/// @notice Deploys ScheduledLaunch, its LockedLaunchLiquidity and the LaunchRouter periphery onto a local fork
/// of a chain with Ekubo Core, TWAMM and the Yul router, and writes launchpad-manifest.json. Run through
/// script/launchpad-local.sh.
/// @dev Local forks only. FORK_BLOCK and GIT_REVISION come from the wrapper. Launch pools trade through the
/// production router's forwarded hop; LaunchRouter only creates, funds and claims fees.
contract DeployLaunchpadLocal is DeployScheduledLaunch {
    bytes32 internal constant SALT = keccak256("ekubo launchpad local");

    function run() public override returns (ScheduledLaunch extension) {
        require(block.chainid != 0, "chain id");
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", address(0x00000000000014aA86C5d3c41765bb24e11bd701))));
        address twamm = vm.envOr("TWAMM_ADDRESS", address(0xd47f1B1eDCfEaBb08F6eBd8FC337c27E636C75BA));
        address router = vm.envOr("ROUTER_ADDRESS", address(0x7B2aA7Ecc0B5936b7C52E6259A19C3BA557d0748));
        if (router.code.length == 0) revert MissingDeployment("Router", router);

        vm.startBroadcast();
        extension = _deploy(core, twamm, SALT, address(0));
        address launchRouter = address(_deployRouter(core, extension, SALT, address(0)));
        vm.stopBroadcast();

        string memory contracts = "contracts";
        _entry(contracts, "core", address(core));
        _entry(contracts, "twamm", twamm);
        _entry(contracts, "scheduled_launch", address(extension));
        _entry(contracts, "locked_launch_liquidity", address(extension.LIQUIDITY()));
        _entry(contracts, "launch_router", launchRouter);
        contracts = _entry(contracts, "router", router);

        string memory manifest = "manifest";
        vm.serializeUint(manifest, "chain_id", block.chainid);
        vm.serializeUint(manifest, "fork_block", vm.envUint("FORK_BLOCK"));
        vm.serializeString(manifest, "git_revision", vm.envString("GIT_REVISION"));
        // _deploy reverts unless the extension's TWAMM is the manifest's and Core has it registered.
        vm.serializeBool(manifest, "twamm_registered", true);
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
