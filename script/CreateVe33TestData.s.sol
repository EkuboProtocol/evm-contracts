// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Core} from "../src/Core.sol";
import {FreeVe33Positions} from "../src/FreeVe33Positions.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {Ve33EmissionRateScheduler} from "../src/Ve33EmissionRateScheduler.sol";
import {Ve33Periphery} from "../src/Ve33Periphery.sol";
import {VeToken} from "../src/VeToken.sol";
import {Ve33, ve33CallPoints} from "../src/extensions/Ve33.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IMintableERC20} from "../src/interfaces/IMintableERC20.sol";
import {deployExtension, deployIfNeeded} from "./DeployAll.s.sol";

/// @title CreateVe33TestData
/// @notice Deploys or reuses a Ve33 test stack, then creates scheduler emissions and ve stake data.
contract CreateVe33TestData is Script {
    bytes32 internal constant DEFAULT_DEPLOYMENT_SALT =
        0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;

    function run() public {
        address deployer = vm.envOr("OWNER_ADDRESS", vm.getWallets()[0]);
        bytes32 salt = vm.envOr("SALT", DEFAULT_DEPLOYMENT_SALT);
        uint160 targetRate = uint160(vm.envOr("TARGET_RATE_Q32", uint256(1e12) << 32));
        uint32 scheduleDuration = uint32(vm.envOr("SCHEDULE_DURATION", uint256(1 weeks)));
        uint128 stakeAmount0 = uint128(vm.envOr("STAKE_AMOUNT_0", uint256(1_000_000e18)));
        uint128 stakeAmount1 = uint128(vm.envOr("STAKE_AMOUNT_1", uint256(500_000e18)));
        uint64 stakeDuration0 = uint64(vm.envOr("STAKE_DURATION_0", uint256(4 * 365 days)));
        uint64 stakeDuration1 = uint64(vm.envOr("STAKE_DURATION_1", uint256(365 days)));

        vm.startBroadcast();

        ICore core = _core();
        MintableERC20 stakeToken = _stakeToken(deployer, salt);
        Ve33 ve33 = _ve33(core, address(stakeToken), salt);
        VeToken veToken = _veToken(core, ve33, salt);
        _positions(core, ve33, deployer, salt);
        _periphery(core, ve33, salt);
        Ve33EmissionRateScheduler scheduler = _scheduler(core, ve33, stakeToken, deployer, salt);

        uint256 totalStakeAmount = uint256(stakeAmount0) + stakeAmount1;
        if (totalStakeAmount != 0) {
            stakeToken.mint(deployer, totalStakeAmount);
            IERC20(address(stakeToken)).approve(address(veToken), totalStakeAmount);
        }

        if (stakeAmount0 != 0) {
            uint256 veId0 = veToken.createStake(stakeAmount0, uint64(block.timestamp) + stakeDuration0);
            console2.log("Created ve stake 0", veId0);
        }

        if (stakeAmount1 != 0) {
            uint256 veId1 = veToken.createStake(stakeAmount1, uint64(block.timestamp) + stakeDuration1);
            console2.log("Created ve stake 1", veId1);
        }

        scheduler.setConfig(targetRate, scheduleDuration);
        stakeToken.transferOwnership(address(scheduler));
        uint128 scheduledAmount = scheduler.mintAndSchedule();

        console2.log("Core", address(core));
        console2.log("Stake token", address(stakeToken));
        console2.log("Ve33", address(ve33));
        console2.log("VeToken", address(veToken));
        console2.log("Scheduler", address(scheduler));
        console2.log("Scheduled amount", scheduledAmount);

        vm.stopBroadcast();
    }

    function _core() private returns (ICore core) {
        address coreAddress = vm.envOr("CORE_ADDRESS", address(0));
        if (coreAddress == address(0)) {
            core = new Core();
            console2.log("Core deployed at", address(core));
        } else {
            core = ICore(payable(coreAddress));
            console2.log("Using Core at", address(core));
        }
    }

    function _stakeToken(address owner, bytes32 salt) private returns (MintableERC20 stakeToken) {
        address stakeTokenAddress = vm.envOr("STAKE_TOKEN", address(0));
        if (stakeTokenAddress == address(0)) {
            (stakeTokenAddress,) = deployIfNeeded(
                abi.encodePacked(
                    type(MintableERC20).creationCode, abi.encode(owner, "Ve33 Test Token", "veTEST", uint8(18))
                ),
                salt,
                vm.envOr("STAKE_TOKEN_ADDRESS", address(0)),
                "MintableERC20"
            );
        }
        stakeToken = MintableERC20(stakeTokenAddress);
        console2.log("Stake token", address(stakeToken));
    }

    function _ve33(ICore core, address stakeToken, bytes32 salt) private returns (Ve33 ve33) {
        address ve33Address = vm.envOr("VE33_ADDRESS", address(0));
        if (ve33Address == address(0)) {
            (ve33Address,) = deployExtension(
                abi.encodePacked(type(Ve33).creationCode, abi.encode(core, stakeToken)),
                salt,
                ve33CallPoints(),
                address(0),
                "Ve33"
            );
        }
        ve33 = Ve33(payable(ve33Address));
    }

    function _veToken(ICore core, Ve33 ve33, bytes32 salt) private returns (VeToken veToken) {
        address veTokenAddress = vm.envOr("VE_TOKEN_ADDRESS", address(0));
        if (veTokenAddress == address(0)) {
            (veTokenAddress,) = deployIfNeeded(
                abi.encodePacked(
                    type(VeToken).creationCode,
                    abi.encode(core, ve33, "Vote Escrow Ve33 Test Token", "veTEST", "Ve33 Test Token", "veTEST", 18)
                ),
                salt,
                address(0),
                "VeToken"
            );
        }
        veToken = VeToken(payable(veTokenAddress));
    }

    function _positions(ICore core, Ve33 ve33, address owner, bytes32 salt)
        private
        returns (FreeVe33Positions positions)
    {
        address positionsAddress = vm.envOr("VE33_POSITIONS_ADDRESS", address(0));
        if (positionsAddress == address(0)) {
            (positionsAddress,) = deployIfNeeded(
                abi.encodePacked(type(FreeVe33Positions).creationCode, abi.encode(core, ve33, owner)),
                salt,
                address(0),
                "FreeVe33Positions"
            );
        }
        positions = FreeVe33Positions(payable(positionsAddress));
    }

    function _periphery(ICore core, Ve33 ve33, bytes32 salt) private returns (Ve33Periphery periphery) {
        address peripheryAddress = vm.envOr("VE33_PERIPHERY_ADDRESS", address(0));
        if (peripheryAddress == address(0)) {
            (peripheryAddress,) = deployIfNeeded(
                abi.encodePacked(type(Ve33Periphery).creationCode, abi.encode(core, ve33)),
                salt,
                address(0),
                "Ve33Periphery"
            );
        }
        periphery = Ve33Periphery(payable(peripheryAddress));
    }

    function _scheduler(ICore core, Ve33 ve33, MintableERC20 stakeToken, address owner, bytes32 salt)
        private
        returns (Ve33EmissionRateScheduler scheduler)
    {
        address schedulerAddress = vm.envOr("VE33_EMISSION_RATE_SCHEDULER_ADDRESS", address(0));
        if (schedulerAddress == address(0)) {
            (schedulerAddress,) = deployIfNeeded(
                abi.encodePacked(
                    type(Ve33EmissionRateScheduler).creationCode,
                    abi.encode(owner, core, ve33, IMintableERC20(address(stakeToken)))
                ),
                salt,
                address(0),
                "Ve33EmissionRateScheduler"
            );
        }
        scheduler = Ve33EmissionRateScheduler(payable(schedulerAddress));
    }
}
