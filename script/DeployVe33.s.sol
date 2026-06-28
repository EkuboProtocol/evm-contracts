// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {Ve33, ve33CallPoints} from "../src/extensions/Ve33.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Ve33Periphery} from "../src/Ve33Periphery.sol";
import {Ve33Positions} from "../src/Ve33Positions.sol";
import {VeToken} from "../src/VeToken.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {deployExtension, deployIfNeeded} from "./DeployAll.s.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @title DeployVe33
/// @notice Deploys the Ve33 extension, VeToken ERC721 wrapper, Ve33Positions, and Ve33Periphery.
contract DeployVe33 is Script {
    address internal constant DEFAULT_CORE_ADDRESS = 0x00000000000014aA86C5d3c41765bb24e11bd701;
    bytes32 internal constant DEFAULT_DEPLOYMENT_SALT =
        0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;

    error StakeTokenDecimalsTooLarge();

    function run() public {
        bytes32 salt = vm.envOr("SALT", DEFAULT_DEPLOYMENT_SALT);
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(DEFAULT_CORE_ADDRESS))));
        address stakeToken = vm.envAddress("STAKE_TOKEN");
        address positionsOwner = vm.envOr("VE33_POSITIONS_OWNER", msg.sender);
        uint64 rewardProtocolFeeX64 = uint64(vm.envOr("VE33_POSITIONS_REWARD_PROTOCOL_FEE_X64", uint256(0)));
        address expectedVe33 = vm.envOr("VE33_ADDRESS", address(0));
        address expectedVeToken = vm.envOr("VE_TOKEN_ADDRESS", address(0));
        address expectedPositions = vm.envOr("VE33_POSITIONS_ADDRESS", address(0));
        address expectedPeriphery = vm.envOr("VE33_PERIPHERY_ADDRESS", address(0));

        vm.startBroadcast();

        (address ve33Address,) = deployExtension(
            abi.encodePacked(type(Ve33).creationCode, abi.encode(core, stakeToken)),
            salt,
            ve33CallPoints(),
            expectedVe33,
            "Ve33"
        );

        Ve33 ve33 = Ve33(payable(ve33Address));

        string memory stakeTokenName = _stakeTokenName(stakeToken);
        string memory stakeTokenSymbol = _stakeTokenSymbol(stakeToken);
        uint8 stakeTokenDecimals = _stakeTokenDecimals(stakeToken);
        string memory veTokenName = _envStringOr("VE_TOKEN_NAME", string.concat("Vote-Escrow ", stakeTokenName));
        string memory veTokenSymbol = _envStringOr("VE_TOKEN_SYMBOL", string.concat("ve", stakeTokenSymbol));

        deployIfNeeded(
            abi.encodePacked(
                type(VeToken).creationCode,
                abi.encode(core, ve33, veTokenName, veTokenSymbol, stakeTokenName, stakeTokenSymbol, stakeTokenDecimals)
            ),
            salt,
            expectedVeToken,
            "VeToken"
        );
        deployIfNeeded(
            abi.encodePacked(
                type(Ve33Positions).creationCode, abi.encode(core, ve33, positionsOwner, rewardProtocolFeeX64)
            ),
            salt,
            expectedPositions,
            "Ve33Positions"
        );
        deployIfNeeded(
            abi.encodePacked(type(Ve33Periphery).creationCode, abi.encode(core, ve33)),
            salt,
            expectedPeriphery,
            "Ve33Periphery"
        );
        vm.stopBroadcast();
    }

    function _stakeTokenName(address stakeToken) internal returns (string memory) {
        try vm.envString("STAKE_TOKEN_NAME") returns (string memory value) {
            return value;
        } catch {
            return stakeToken == NATIVE_TOKEN_ADDRESS ? "Ether" : IERC20(stakeToken).name();
        }
    }

    function _stakeTokenSymbol(address stakeToken) internal returns (string memory) {
        try vm.envString("STAKE_TOKEN_SYMBOL") returns (string memory value) {
            return value;
        } catch {
            return stakeToken == NATIVE_TOKEN_ADDRESS ? "ETH" : IERC20(stakeToken).symbol();
        }
    }

    function _stakeTokenDecimals(address stakeToken) internal returns (uint8) {
        try vm.envUint("STAKE_TOKEN_DECIMALS") returns (uint256 value) {
            if (value > type(uint8).max) revert StakeTokenDecimalsTooLarge();
            return uint8(value);
        } catch {
            return stakeToken == NATIVE_TOKEN_ADDRESS ? 18 : IERC20(stakeToken).decimals();
        }
    }

    function _envStringOr(string memory key, string memory defaultValue) internal returns (string memory value) {
        try vm.envString(key) returns (string memory envValue) {
            value = envValue;
        } catch {
            value = defaultValue;
        }
    }
}
