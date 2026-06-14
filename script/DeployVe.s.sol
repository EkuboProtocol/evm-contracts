// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ICore} from "../src/interfaces/ICore.sol";
import {SingleTokenRewards, singleTokenRewardsCallPoints} from "../src/extensions/SingleTokenRewards.sol";
import {VeGauge} from "../src/VeGauge.sol";
import {VePositions} from "../src/VePositions.sol";
import {deployExtension, deployIfNeeded} from "./DeployAll.s.sol";

/// @title DeployVe
/// @notice Deploys the ve position manager, ve gauge, and restricted SingleTokenRewards extension.
contract DeployVe is Script {
    VePositions public positions;
    VeGauge public gauge;
    SingleTokenRewards public rewards;

    function run() public {
        address deployer = vm.envOr("OWNER_ADDRESS", vm.getWallets()[0]);
        bytes32 salt = vm.envOr("SALT", bytes32(0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd));
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(0x00000000000014aA86C5d3c41765bb24e11bd701))));
        address stakeToken = vm.envAddress("STAKE_TOKEN");

        uint64 swapProtocolFeeX64 = uint64(vm.envOr("SWAP_PROTOCOL_FEE_X64", uint256(0)));
        uint64 withdrawalProtocolFeeDenominator = uint64(vm.envOr("WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR", uint256(0)));

        string memory positionsBaseUrl =
            _envStringOr("VE_POSITIONS_BASE_URL", "https://prod-api.ekubo.org/ve/positions/");
        string memory gaugeBaseUrl = _envStringOr("VE_GAUGE_BASE_URL", "https://prod-api.ekubo.org/ve/locks/");

        vm.startBroadcast();

        (address positionsAddress, bool deployedPositions) = deployIfNeeded(
            abi.encodePacked(
                type(VePositions).creationCode,
                abi.encode(core, deployer, address(0), swapProtocolFeeX64, withdrawalProtocolFeeDenominator)
            ),
            salt,
            address(0),
            "VePositions"
        );
        positions = VePositions(payable(positionsAddress));

        (address gaugeAddress, bool deployedGauge) = deployIfNeeded(
            abi.encodePacked(type(VeGauge).creationCode, abi.encode(core, deployer, positionsAddress, stakeToken)),
            salt,
            address(0),
            "VeGauge"
        );
        gauge = VeGauge(payable(gaugeAddress));

        if (positions.feeReceiver() != gaugeAddress) {
            positions.setFeeReceiver(gaugeAddress);
            console2.log("Set VePositions fee receiver", gaugeAddress);
        }

        if (deployedPositions) {
            positions.setMetadata({newName: "Ekubo ve Positions", newSymbol: "ekuVeP", newBaseUrl: positionsBaseUrl});
            console2.log("Set VePositions metadata");
        }

        if (deployedGauge) {
            gauge.setMetadata({newName: "Ekubo ve Locks", newSymbol: "ekuVe", newBaseUrl: gaugeBaseUrl});
            console2.log("Set VeGauge metadata");
        }

        (address rewardsAddress,) = deployExtension(
            abi.encodePacked(type(SingleTokenRewards).creationCode, abi.encode(core, stakeToken, positionsAddress)),
            salt,
            singleTokenRewardsCallPoints(),
            address(0),
            "SingleTokenRewards(ve)"
        );
        rewards = SingleTokenRewards(rewardsAddress);

        vm.stopBroadcast();
    }

    function _envStringOr(string memory key, string memory defaultValue) internal returns (string memory value) {
        try vm.envString(key) returns (string memory envValue) {
            value = envValue;
        } catch {
            value = defaultValue;
        }
    }
}
