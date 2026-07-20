// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {deployIfNeeded} from "./DeployAll.s.sol";

/// @title DeployMintableToken
/// @notice Deterministically deploys a mintable token owned by the broadcasting wallet.
contract DeployMintableToken is Script {
    bytes32 internal constant DEFAULT_DEPLOYMENT_SALT = bytes32(0);

    error InvalidTokenDecimals(uint256 decimals);

    function run() public returns (MintableERC20 token) {
        string memory name = vm.envString("TOKEN_NAME");
        string memory symbol = vm.envString("TOKEN_SYMBOL");
        uint256 configuredDecimals = vm.envOr("TOKEN_DECIMALS", uint256(18));
        if (configuredDecimals > type(uint8).max) revert InvalidTokenDecimals(configuredDecimals);
        uint8 decimals = uint8(configuredDecimals);
        bytes32 salt = vm.envOr("SALT", DEFAULT_DEPLOYMENT_SALT);
        address expectedAddress = vm.envOr("TOKEN_ADDRESS", address(0));
        address owner = vm.getWallets()[0];
        bytes memory initCode =
            abi.encodePacked(type(MintableERC20).creationCode, abi.encode(owner, name, symbol, decimals));

        console2.log("MintableERC20 init code hash:");
        console2.logBytes32(keccak256(initCode));

        vm.startBroadcast();

        (address tokenAddress,) = deployIfNeeded(initCode, salt, expectedAddress, symbol);
        token = MintableERC20(tokenAddress);

        vm.stopBroadcast();
    }
}
