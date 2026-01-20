// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
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

function deployIfNeeded(bytes memory initCode, bytes32 salt, string memory name) returns (address deployed) {
    bytes32 initCodeHash = keccak256(initCode);
    address expected = getCreate2Address(salt, initCodeHash);

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

function deployExtension(bytes memory initCode, bytes32 startingSalt, CallPoints memory callPoints, string memory name)
    returns (address deployed, bytes32 salt)
{
    uint8 requiredPrefix = callPoints.toUint8();

    bytes32 initCodeHash = keccak256(initCode);
    salt = findExtensionSalt(startingSalt, initCodeHash, callPoints);
    deployed = deployIfNeeded(initCode, salt, name);
}

/// @title DeployAll
/// @notice Deploys the Ekubo protocol core contracts
contract DeployAll is Script {
    bytes32 constant DEPLOYMENT_SALT = 0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;
    bytes32 constant MEV_CAPTURE_ROUTER_DEPLOYMENT_SALT =
        0x38e2e731c4e6738213b17b239fe56c423f6bdc5b5969897c260d464c35a63982;

    error UnexpectedAddress(string name, address value);

    function run() public {
        vm.startBroadcast();

        Core core = Core(payable(deployIfNeeded(type(Core).creationCode, DEPLOYMENT_SALT, "Core")));
        if (address(core) != 0x00000000000014aA86C5d3c41765bb24e11bd701) {
            revert UnexpectedAddress("Core", address(core));
        }

        (address mevCaptureAddress,) = deployExtension(
            abi.encodePacked(type(MEVCapture).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            mevCaptureCallPoints(),
            "MEVCapture"
        );
        MEVCapture mevCapture = MEVCapture(mevCaptureAddress);

        (address oracleAddress,) = deployExtension(
            abi.encodePacked(type(Oracle).creationCode, abi.encode(core)), DEPLOYMENT_SALT, oracleCallPoints(), "Oracle"
        );
        Oracle oracle = Oracle(oracleAddress);

        (address twammAddress,) = deployExtension(
            abi.encodePacked(type(TWAMM).creationCode, abi.encode(core)), DEPLOYMENT_SALT, twammCallPoints(), "TWAMM"
        );
        TWAMM twamm = TWAMM(twammAddress);

        Incentives incentives = Incentives(deployIfNeeded(type(Incentives).creationCode, DEPLOYMENT_SALT, "Incentives"));

        deployIfNeeded(
            abi.encodePacked(type(TokenWrapperFactory).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            "TokenWrapperFactory"
        );

        deployIfNeeded(
            abi.encodePacked(type(CoreDataFetcher).creationCode, abi.encode(core)), DEPLOYMENT_SALT, "CoreDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(QuoteDataFetcher).creationCode, abi.encode(core)), DEPLOYMENT_SALT, "QuoteDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(TWAMMDataFetcher).creationCode, abi.encode(core, twamm)),
            DEPLOYMENT_SALT,
            "TWAMMDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(IncentivesDataFetcher).creationCode, abi.encode(incentives)),
            DEPLOYMENT_SALT,
            "IncentivesDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(PriceFetcher).creationCode, abi.encode(oracle)), DEPLOYMENT_SALT, "PriceFetcher"
        );
        deployIfNeeded(type(TokenDataFetcher).creationCode, DEPLOYMENT_SALT, "TokenDataFetcher");
        address mevCaptureRouter = deployIfNeeded(
            abi.encodePacked(type(MEVCaptureRouter).creationCode, abi.encode(core, address(mevCapture))),
            MEV_CAPTURE_ROUTER_DEPLOYMENT_SALT,
            "MEVCaptureRouter"
        );
        if (mevCaptureRouter != address(0xd26f20001a72a18C002b00e6710000d68700ce00)) {
            revert UnexpectedAddress("MEVCaptureRouter", address(mevCaptureRouter));
        }

        deployExtension(
            abi.encodePacked(type(BoostedFees).creationCode, abi.encode(core, true)),
            DEPLOYMENT_SALT,
            boostedFeesCallPoints(true),
            "BoostedFees(concentrated)"
        );

        deployExtension(
            abi.encodePacked(type(BoostedFees).creationCode, abi.encode(core, false)),
            DEPLOYMENT_SALT,
            boostedFeesCallPoints(false),
            "BoostedFees(stableswap)"
        );

        deployIfNeeded(
            abi.encodePacked(type(ManualPoolBooster).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            "ManualPoolBooster"
        );
        deployIfNeeded(
            abi.encodePacked(type(BoostedFeesDataFetcher).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            "BoostedFeesDataFetcher"
        );

        vm.stopBroadcast();
    }
}
