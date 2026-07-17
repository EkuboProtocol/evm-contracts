// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Ve33, ve33CallPoints} from "../src/extensions/Ve33.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Ve33Periphery} from "../src/Ve33Periphery.sol";
import {Ve33Positions} from "../src/Ve33Positions.sol";
import {VeToken} from "../src/VeToken.sol";
import {VeTokenMetadata} from "../src/VeTokenMetadata.sol";
import {Ve33DataFetcher} from "../src/lens/Ve33DataFetcher.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {deployExtension, deployIfNeeded} from "./DeployAll.s.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

struct Ve33Deployment {
    address stakeToken;
    Ve33 ve33;
    VeToken veToken;
    Ve33Positions positions;
}

/// @title DeployVe33
/// @notice Deploys the Ve33 extension, VeToken ERC721 wrapper, Ve33Positions, Ve33Periphery, and Ve33DataFetcher.
contract DeployVe33 is Script {
    address internal constant DEFAULT_CORE_ADDRESS = 0x00000000000014aA86C5d3c41765bb24e11bd701;
    bytes32 internal constant DEFAULT_DEPLOYMENT_SALT =
        0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;

    function run() public virtual {
        bytes32 salt = vm.envOr("SALT", DEFAULT_DEPLOYMENT_SALT);
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(DEFAULT_CORE_ADDRESS))));
        address deployer = vm.envOr("OWNER_ADDRESS", vm.getWallets()[0]);

        vm.startBroadcast();

        _deployVe33(core, deployer, salt);

        vm.stopBroadcast();
    }

    function _deployVe33(ICore core, address deployer, bytes32 salt)
        internal
        returns (Ve33Deployment memory deployment)
    {
        address stakeTokenAddress;
        string memory stakeTokenName;
        string memory stakeTokenSymbol;
        uint8 stakeTokenDecimals;

        (stakeTokenAddress, stakeTokenName, stakeTokenSymbol, stakeTokenDecimals) = _stakeToken(deployer, salt);
        deployment.stakeToken = stakeTokenAddress;

        (address ve33Address,) = deployExtension(
            abi.encodePacked(type(Ve33).creationCode, abi.encode(core, stakeTokenAddress)),
            salt,
            ve33CallPoints(),
            address(0),
            "Ve33"
        );

        deployment.ve33 = Ve33(payable(ve33Address));

        deployment.veToken = _deployVeToken(
            core, deployment.ve33, stakeTokenAddress, stakeTokenName, stakeTokenSymbol, stakeTokenDecimals, salt
        );
        deployment.positions = _deployPositions(core, deployment.ve33, deployer, salt);
        _deployVe33Support(core, deployment.ve33, salt);
    }

    function _deployVeToken(
        ICore core,
        Ve33 ve33,
        address stakeToken,
        string memory stakeTokenName,
        string memory stakeTokenSymbol,
        uint8 stakeTokenDecimals,
        bytes32 salt
    ) internal returns (VeToken veToken) {
        (address veTokenMetadata,) = deployIfNeeded(
            abi.encodePacked(
                type(VeTokenMetadata).creationCode,
                abi.encode(stakeTokenName, stakeTokenSymbol, stakeTokenDecimals, stakeToken)
            ),
            salt,
            address(0),
            "VeTokenMetadata"
        );

        string memory veTokenName = _envStringOr("VE_TOKEN_NAME", _defaultVeTokenName(stakeTokenName));
        string memory veTokenSymbol = _envStringOr("VE_TOKEN_SYMBOL", _defaultVeTokenSymbol(stakeTokenSymbol));

        (address veTokenAddress,) = deployIfNeeded(
            abi.encodePacked(
                type(VeToken).creationCode,
                abi.encode(core, ve33, VeTokenMetadata(veTokenMetadata), veTokenName, veTokenSymbol)
            ),
            salt,
            address(0),
            "VeToken"
        );
        veToken = VeToken(payable(veTokenAddress));
    }

    function _deployPositions(ICore core, Ve33 ve33, address deployer, bytes32 salt)
        internal
        returns (Ve33Positions positions)
    {
        string memory positionsName = _envStringOr("VE33_POSITIONS_NAME", _defaultPositionsName());
        string memory positionsSymbol = _envStringOr("VE33_POSITIONS_SYMBOL", _defaultPositionsSymbol());
        string memory positionsBaseUrl =
            _envStringOr("VE33_POSITIONS_BASE_URL", "https://prod-api.ekubo.org/positions/");

        (address positionsAddress, bool deployedPositions) = deployIfNeeded(
            abi.encodePacked(type(Ve33Positions).creationCode, abi.encode(core, ve33, deployer)),
            salt,
            address(0),
            "Ve33Positions"
        );

        if (deployedPositions) {
            positions = Ve33Positions(payable(positionsAddress));
            positions.setMetadata({newName: positionsName, newSymbol: positionsSymbol, newBaseUrl: positionsBaseUrl});
            console2.log("Set Ve33 positions metadata");
        } else {
            positions = Ve33Positions(payable(positionsAddress));
        }
    }

    function _deployVe33Support(ICore core, Ve33 ve33, bytes32 salt) internal {
        deployIfNeeded(
            abi.encodePacked(type(Ve33Periphery).creationCode, abi.encode(core, ve33)),
            salt,
            address(0),
            "Ve33Periphery"
        );

        deployIfNeeded(
            abi.encodePacked(type(Ve33DataFetcher).creationCode, abi.encode(ve33)), salt, address(0), "Ve33DataFetcher"
        );
    }

    function _stakeToken(address owner, bytes32 salt)
        internal
        virtual
        returns (
            address stakeToken,
            string memory stakeTokenName,
            string memory stakeTokenSymbol,
            uint8 stakeTokenDecimals
        )
    {
        try vm.envAddress("STAKE_TOKEN") returns (address envStakeToken) {
            stakeToken = envStakeToken;
            stakeTokenName = _stakeTokenName(stakeToken);
            stakeTokenSymbol = _stakeTokenSymbol(stakeToken);
            stakeTokenDecimals = 18;
        } catch {
            stakeTokenName = vm.envString("STAKE_TOKEN_NAME");
            stakeTokenSymbol = vm.envString("STAKE_TOKEN_SYMBOL");
            stakeTokenDecimals = 18;
            (stakeToken,) = deployIfNeeded(
                abi.encodePacked(type(MintableERC20).creationCode, abi.encode(owner, stakeTokenName, stakeTokenSymbol)),
                salt,
                address(0),
                "MintableERC20"
            );
        }
    }

    function _defaultPositionsName() internal pure virtual returns (string memory) {
        return "Ekubo Ve33 Positions";
    }

    function _defaultPositionsSymbol() internal pure virtual returns (string memory) {
        return "ekuVe33Po";
    }

    function _defaultVeTokenName(string memory stakeTokenName) internal pure virtual returns (string memory) {
        return string.concat("Vote-Escrow ", stakeTokenName);
    }

    function _defaultVeTokenSymbol(string memory stakeTokenSymbol) internal pure virtual returns (string memory) {
        return string.concat("ve", stakeTokenSymbol);
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

    function _envStringOr(string memory key, string memory defaultValue) internal returns (string memory value) {
        try vm.envString(key) returns (string memory envValue) {
            value = envValue;
        } catch {
            value = defaultValue;
        }
    }
}
