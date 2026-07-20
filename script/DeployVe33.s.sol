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
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {deployExtension, deployIfNeeded} from "./DeployAll.s.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

struct Ve33DeploymentParams {
    // Stake-token metadata used by VeTokenMetadata.
    address stakeToken;
    string stakeTokenName;
    string stakeTokenSymbol;
    uint8 stakeTokenDecimals;

    // ERC721 collection metadata.
    string veTokenName;
    string veTokenSymbol;
    string positionsName;
    string positionsSymbol;
    string positionsBaseUrl;
    address positionsOwner;

    // Optional deterministic-address assertions.
    address expectedVe33;
    address expectedVeToken;
    address expectedVe33Positions;
    address expectedVe33Periphery;
    address expectedVe33DataFetcher;
}

/// @title DeployVe33
/// @notice Deploys the Ve33 extension, VeToken ERC721 wrapper, Ve33Positions, Ve33Periphery, and Ve33DataFetcher.
contract DeployVe33 is Script {
    address internal constant DEFAULT_CORE_ADDRESS = 0x00000000000014aA86C5d3c41765bb24e11bd701;
    bytes32 internal constant DEFAULT_DEPLOYMENT_SALT =
        0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;

    function run()
        public
        returns (
            Ve33 ve33,
            VeToken veToken,
            Ve33Positions positions,
            Ve33Periphery periphery,
            Ve33DataFetcher dataFetcher
        )
    {
        bytes32 salt = vm.envOr("SALT", DEFAULT_DEPLOYMENT_SALT);
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(DEFAULT_CORE_ADDRESS))));
        address stakeToken = vm.envAddress("STAKE_TOKEN");
        address positionsOwner = vm.envOr("OWNER_ADDRESS", vm.getWallets()[0]);
        Ve33DeploymentParams memory params = _deploymentParams(stakeToken, positionsOwner);

        vm.startBroadcast();

        (ve33, veToken, positions, periphery, dataFetcher) = _deployVe33(core, params, salt);

        vm.stopBroadcast();
    }

    function _deploymentParams(address stakeToken, address positionsOwner)
        internal
        returns (Ve33DeploymentParams memory params)
    {
        string memory stakeTokenName = _stakeTokenName(stakeToken);
        string memory stakeTokenSymbol = _stakeTokenSymbol(stakeToken);

        params = Ve33DeploymentParams({
            stakeToken: stakeToken,
            stakeTokenName: stakeTokenName,
            stakeTokenSymbol: stakeTokenSymbol,
            stakeTokenDecimals: stakeToken == NATIVE_TOKEN_ADDRESS ? 18 : IERC20(stakeToken).decimals(),
            veTokenName: _envStringOr("VE_TOKEN_NAME", _defaultVeTokenName(stakeTokenName)),
            veTokenSymbol: _envStringOr("VE_TOKEN_SYMBOL", _defaultVeTokenSymbol(stakeTokenSymbol)),
            positionsName: _envStringOr("VE33_POSITIONS_NAME", _defaultPositionsName()),
            positionsSymbol: _envStringOr("VE33_POSITIONS_SYMBOL", _defaultPositionsSymbol()),
            positionsBaseUrl: _envStringOr("VE33_POSITIONS_BASE_URL", "https://prod-api.ekubo.org/positions/"),
            positionsOwner: positionsOwner,
            expectedVe33: vm.envOr("VE33_ADDRESS", address(0)),
            expectedVeToken: vm.envOr("VE_TOKEN_ADDRESS", address(0)),
            expectedVe33Positions: vm.envOr("VE33_POSITIONS_ADDRESS", address(0)),
            expectedVe33Periphery: vm.envOr("VE33_PERIPHERY_ADDRESS", address(0)),
            expectedVe33DataFetcher: vm.envOr("VE33_DATA_FETCHER_ADDRESS", address(0))
        });
    }

    function _deployVe33(ICore core, Ve33DeploymentParams memory params, bytes32 salt)
        internal
        returns (
            Ve33 ve33,
            VeToken veToken,
            Ve33Positions positions,
            Ve33Periphery periphery,
            Ve33DataFetcher dataFetcher
        )
    {
        (address ve33Address,) = deployExtension(
            abi.encodePacked(type(Ve33).creationCode, abi.encode(core, params.stakeToken)),
            salt,
            ve33CallPoints(),
            params.expectedVe33,
            "Ve33"
        );

        ve33 = Ve33(payable(ve33Address));

        veToken = _deployVeToken(core, ve33, params, salt);
        positions = _deployPositions(core, ve33, params, salt);
        (periphery, dataFetcher) =
            _deployVe33Support(core, ve33, params.expectedVe33Periphery, params.expectedVe33DataFetcher, salt);
    }

    function _deployVeToken(ICore core, Ve33 ve33, Ve33DeploymentParams memory params, bytes32 salt)
        internal
        returns (VeToken veToken)
    {
        (address veTokenMetadata,) = deployIfNeeded(
            abi.encodePacked(
                type(VeTokenMetadata).creationCode,
                abi.encode(params.stakeTokenName, params.stakeTokenSymbol, params.stakeTokenDecimals, params.stakeToken)
            ),
            salt,
            address(0),
            "VeTokenMetadata"
        );

        (address veTokenAddress,) = deployIfNeeded(
            abi.encodePacked(
                type(VeToken).creationCode,
                abi.encode(core, ve33, VeTokenMetadata(veTokenMetadata), params.veTokenName, params.veTokenSymbol)
            ),
            salt,
            params.expectedVeToken,
            "VeToken"
        );
        veToken = VeToken(payable(veTokenAddress));
    }

    function _deployPositions(ICore core, Ve33 ve33, Ve33DeploymentParams memory params, bytes32 salt)
        internal
        returns (Ve33Positions positions)
    {
        (address positionsAddress, bool deployedPositions) = deployIfNeeded(
            abi.encodePacked(type(Ve33Positions).creationCode, abi.encode(core, ve33, params.positionsOwner)),
            salt,
            params.expectedVe33Positions,
            "Ve33Positions"
        );

        if (deployedPositions) {
            positions = Ve33Positions(payable(positionsAddress));
            positions.setMetadata({
                newName: params.positionsName, newSymbol: params.positionsSymbol, newBaseUrl: params.positionsBaseUrl
            });
            console2.log("Set Ve33 positions metadata");
        } else {
            positions = Ve33Positions(payable(positionsAddress));
        }
    }

    function _deployVe33Support(
        ICore core,
        Ve33 ve33,
        address expectedPeriphery,
        address expectedDataFetcher,
        bytes32 salt
    ) internal returns (Ve33Periphery periphery, Ve33DataFetcher dataFetcher) {
        periphery = _deployVe33Periphery(core, ve33, expectedPeriphery, salt);
        dataFetcher = _deployVe33DataFetcher(ve33, expectedDataFetcher, salt);
    }

    function _deployVe33Periphery(ICore core, Ve33 ve33, address expectedAddress, bytes32 salt)
        internal
        returns (Ve33Periphery periphery)
    {
        (address peripheryAddress,) = deployIfNeeded(
            abi.encodePacked(type(Ve33Periphery).creationCode, abi.encode(core, ve33)),
            salt,
            expectedAddress,
            "Ve33Periphery"
        );
        periphery = Ve33Periphery(payable(peripheryAddress));
    }

    function _deployVe33DataFetcher(Ve33 ve33, address expectedAddress, bytes32 salt)
        internal
        returns (Ve33DataFetcher dataFetcher)
    {
        (address dataFetcherAddress,) = deployIfNeeded(
            abi.encodePacked(type(Ve33DataFetcher).creationCode, abi.encode(ve33)),
            salt,
            expectedAddress,
            "Ve33DataFetcher"
        );
        dataFetcher = Ve33DataFetcher(dataFetcherAddress);
    }

    function _defaultPositionsName() internal pure returns (string memory) {
        return "Ekubo Ve33 Positions";
    }

    function _defaultPositionsSymbol() internal pure returns (string memory) {
        return "ekuVe33Po";
    }

    function _defaultVeTokenName(string memory stakeTokenName) internal pure returns (string memory) {
        return string.concat("Vote-Escrow ", stakeTokenName);
    }

    function _defaultVeTokenSymbol(string memory stakeTokenSymbol) internal pure returns (string memory) {
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
