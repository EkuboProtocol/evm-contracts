// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Core} from "../src/Core.sol";
import {CallPoints} from "../src/types/callPoints.sol";
import {Oracle, oracleCallPoints} from "../src/extensions/Oracle.sol";
import {TWAMM, twammCallPoints} from "../src/extensions/TWAMM.sol";
import {BoostedFees, boostedFeesCallPoints} from "../src/extensions/BoostedFees.sol";
import {MEVCapture, mevCaptureCallPoints} from "../src/extensions/MEVCapture.sol";
import {Incentives} from "../src/Incentives.sol";
import {TokenWrapperFactory} from "../src/TokenWrapperFactory.sol";
import {CoreDataFetcher} from "../src/lens/CoreDataFetcher.sol";
import {IncentivesDataFetcher} from "../src/lens/IncentivesDataFetcher.sol";
import {QuoteDataFetcher} from "../src/lens/QuoteDataFetcher.sol";
import {TWAMMDataFetcher} from "../src/lens/TWAMMDataFetcher.sol";
import {PriceFetcher} from "../src/lens/PriceFetcher.sol";
import {TokenDataFetcher} from "../src/lens/TokenDataFetcher.sol";
import {MEVCaptureRouter} from "../src/MEVCaptureRouter.sol";
import {BoostedFeesDataFetcher} from "../src/lens/BoostedFeesDataFetcher.sol";
import {ManualPoolBooster} from "../src/ManualPoolBooster.sol";

address constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

function getCreate2Address(bytes32 salt, bytes32 initCodeHash) pure returns (address) {
    return
        address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), DETERMINISTIC_DEPLOYER, salt, initCodeHash)))));
}

function findExtensionSalt(bytes32 startingSalt, bytes32 initCodeHash, CallPoints memory callPoints)
    pure
    returns (bytes32 salt)
{
    salt = startingSalt;
    uint8 startingByte = callPoints.toUint8();

    unchecked {
        while (true) {
            uint8 predictedStartingByte = uint8(uint160(getCreate2Address(salt, initCodeHash)) >> 152);

            if (predictedStartingByte == startingByte) {
                break;
            }

            salt = bytes32(uint256(salt) + 1);
        }
    }
}

error DeploymentFailed(string name, address expected);
error UnexpectedAddress(string name, address expected, address actual);

function deployIfNeeded(bytes memory initCode, bytes32 salt, address expectedAddress, string memory name)
    returns (address deployed)
{
    bytes32 initCodeHash = keccak256(initCode);
    address expected = getCreate2Address(salt, initCodeHash);

    if (expectedAddress != address(0) && expected != expectedAddress) {
        revert UnexpectedAddress(name, expectedAddress, expected);
    }

    if (expected.code.length != 0) {
        console2.log(name, "already deployed at", expected);
        return expected;
    }

    (bool success,) = DETERMINISTIC_DEPLOYER.call(abi.encodePacked(salt, initCode));
    if (!success || expected.code.length == 0) {
        revert DeploymentFailed(name, expected);
    }

    console2.log(name, "deployed at", expected);
    return expected;
}

function deployExtension(
    bytes memory initCode,
    bytes32 startingSalt,
    CallPoints memory callPoints,
    address expectedAddress,
    string memory name
) returns (address deployed, bytes32 salt) {
    uint8 requiredPrefix = callPoints.toUint8();

    bytes32 initCodeHash = keccak256(initCode);
    salt = findExtensionSalt(startingSalt, initCodeHash, callPoints);
    deployed = deployIfNeeded(initCode, salt, expectedAddress, name);
}

/// @title DeployAll
/// @notice Deploys the Ekubo protocol core contracts
contract DeployAll is Script {
    bytes32 constant DEPLOYMENT_SALT = 0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;
    bytes32 constant MEV_CAPTURE_ROUTER_DEPLOYMENT_SALT =
        0x38e2e731c4e6738213b17b239fe56c423f6bdc5b5969897c260d464c35a63982;

    function run() public {
        vm.startBroadcast();

        Core core = Core(
            payable(deployIfNeeded(
                    type(Core).creationCode, DEPLOYMENT_SALT, 0x00000000000014aA86C5d3c41765bb24e11bd701, "Core"
                ))
        );

        (address mevCaptureAddress,) = deployExtension(
            abi.encodePacked(type(MEVCapture).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            mevCaptureCallPoints(),
            0x5555fF9Ff2757500BF4EE020DcfD0210CFfa41Be,
            "MEVCapture"
        );
        MEVCapture mevCapture = MEVCapture(mevCaptureAddress);

        (address oracleAddress,) = deployExtension(
            abi.encodePacked(type(Oracle).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            oracleCallPoints(),
            0x517E506700271AEa091b02f42756F5E174Af5230,
            "Oracle"
        );
        Oracle oracle = Oracle(oracleAddress);

        (address twammAddress,) = deployExtension(
            abi.encodePacked(type(TWAMM).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            twammCallPoints(),
            0xd4F1060cB9c1A13e1d2d20379b8aa2cF7541eD9b,
            "TWAMM"
        );
        TWAMM twamm = TWAMM(twammAddress);

        Incentives incentives = Incentives(
            deployIfNeeded(
                type(Incentives).creationCode, DEPLOYMENT_SALT, 0xC52D2656cb8C634263E6A15469588beB9C3Bb738, "Incentives"
            )
        );

        deployIfNeeded(
            abi.encodePacked(type(TokenWrapperFactory).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0xAA166592922C4020cEfA23448054AD070211790a,
            "TokenWrapperFactory"
        );

        deployIfNeeded(
            abi.encodePacked(type(CoreDataFetcher).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0xF68F25CA6C817733b7B15a42191AE72A34d56a2B,
            "CoreDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(QuoteDataFetcher).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0x5a3F0F1dA4Ac0c4b937d5685f330704c8e8303f1,
            "QuoteDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(TWAMMDataFetcher).creationCode, abi.encode(core, twamm)),
            DEPLOYMENT_SALT,
            0xc07E5B80750247C8b5d7234a9C79dFC58785392b,
            "TWAMMDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(IncentivesDataFetcher).creationCode, abi.encode(incentives)),
            DEPLOYMENT_SALT,
            0x69F9eCfa84CF0C41bE9F68b557b07b6b89d71eD0,
            "IncentivesDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(PriceFetcher).creationCode, abi.encode(oracle)),
            DEPLOYMENT_SALT,
            0xFE0Aa09c1CC2bA299b3AaFA52716bE00f40F1D6d,
            "PriceFetcher"
        );
        deployIfNeeded(
            type(TokenDataFetcher).creationCode,
            DEPLOYMENT_SALT,
            0x305Cf9A34dCb265522780D1D64544d3f7C450407,
            "TokenDataFetcher"
        );
        address mevCaptureRouter = deployIfNeeded(
            abi.encodePacked(type(MEVCaptureRouter).creationCode, abi.encode(core, address(mevCapture))),
            MEV_CAPTURE_ROUTER_DEPLOYMENT_SALT,
            0xd26f20001a72a18C002b00e6710000d68700ce00,
            "MEVCaptureRouter"
        );

        deployExtension(
            abi.encodePacked(type(BoostedFees).creationCode, abi.encode(core, true)),
            DEPLOYMENT_SALT,
            boostedFeesCallPoints(true),
            0xd4B54d0ca6979Da05F25895E6e269E678ba00f9e,
            "BoostedFees(concentrated)"
        );
        deployExtension(
            abi.encodePacked(type(BoostedFees).creationCode, abi.encode(core, false)),
            DEPLOYMENT_SALT,
            boostedFeesCallPoints(false),
            0x948b9C2C99718034954110cB61a6e08e107745f9,
            "BoostedFees(stableswap)"
        );
        deployIfNeeded(
            abi.encodePacked(type(ManualPoolBooster).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0xddb1758118F65e13a91497015B8cB26801402761,
            "ManualPoolBooster"
        );
        deployIfNeeded(
            abi.encodePacked(type(BoostedFeesDataFetcher).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0x7A2fF5819Dc71Bb99133a97c38dA512E60c30475,
            "BoostedFeesDataFetcher"
        );

        vm.stopBroadcast();
    }
}
