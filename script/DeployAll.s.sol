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
import {BoostedFeesDataFetcher} from "../src/lens/BoostedFeesDataFetcher.sol";
import {ManualPoolBooster} from "../src/ManualPoolBooster.sol";
import {PoolKeyIndex} from "../src/PoolKeyIndex.sol";

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
    returns (address deployed, bool didDeploy)
{
    bytes32 initCodeHash = keccak256(initCode);
    address expected = getCreate2Address(salt, initCodeHash);

    if (expectedAddress != address(0) && expected != expectedAddress) {
        revert UnexpectedAddress(name, expectedAddress, expected);
    }

    if (expected.code.length != 0) {
        console2.log(name, "already deployed at", expected);
        return (expected, false);
    }

    (bool success,) = DETERMINISTIC_DEPLOYER.call(abi.encodePacked(salt, initCode));
    if (!success || expected.code.length == 0) {
        revert DeploymentFailed(name, expected);
    }

    console2.log(name, "deployed at", expected);
    return (expected, true);
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
    (deployed,) = deployIfNeeded(initCode, salt, expectedAddress, name);
}

/// @title DeployAll
/// @notice Deploys the Ekubo protocol core contracts
contract DeployAll is Script {
    // Expected addresses below are derived from the pinned Solar toolchain.
    // Rebuilding with a different compiler must fail rather than deploy elsewhere.
    bytes32 constant DEPLOYMENT_SALT = 0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;

    function run() public {
        vm.startBroadcast();

        address coreAddress;
        (coreAddress,) = deployIfNeeded(
            type(Core).creationCode, DEPLOYMENT_SALT, 0x4Abd7F3FfFC1cA0007cCC9063E46B5998782b0Fb, "Core"
        );
        Core core = Core(payable(coreAddress));

        deployExtension(
            abi.encodePacked(type(MEVCapture).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            mevCaptureCallPoints(),
            0x55DE9Eee17a1CC6c94A560702456223aCbD129eE,
            "MEVCapture"
        );

        (address oracleAddress,) = deployExtension(
            abi.encodePacked(type(Oracle).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            oracleCallPoints(),
            0x51A2542f6269eDBCc07B7520b87D98089922f580,
            "Oracle"
        );
        Oracle oracle = Oracle(oracleAddress);

        (address twammAddress,) = deployExtension(
            abi.encodePacked(type(TWAMM).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            twammCallPoints(),
            0xD4B2b422fA56a7A44ED90F08b2bA147D09Db30cF,
            "TWAMM"
        );
        TWAMM twamm = TWAMM(twammAddress);

        address incentivesAddress;
        (incentivesAddress,) = deployIfNeeded(
            type(Incentives).creationCode, DEPLOYMENT_SALT, 0xc257D6E24Db3fb785150371222597F7a83FCaE84, "Incentives"
        );
        Incentives incentives = Incentives(incentivesAddress);

        deployIfNeeded(
            abi.encodePacked(type(TokenWrapperFactory).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0x14075ED29A811Cd2e7192787D66B3b4DceF1C1ac,
            "TokenWrapperFactory"
        );

        deployIfNeeded(
            abi.encodePacked(type(CoreDataFetcher).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0xfAD909208dfF32139C17F028db762BcE651997B6,
            "CoreDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(PoolKeyIndex).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0x6F514a9c2978315E797c7e09583fDdFdE51A6c66,
            "PoolKeyIndex"
        );
        deployIfNeeded(
            abi.encodePacked(type(QuoteDataFetcher).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0x97C37EE9809ac94A052CC24140Cc13F1EB3973d6,
            "QuoteDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(TWAMMDataFetcher).creationCode, abi.encode(core, twamm)),
            DEPLOYMENT_SALT,
            0x6Ce66dA033042FFB44DC04666bE0C769b9DBf82F,
            "TWAMMDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(IncentivesDataFetcher).creationCode, abi.encode(incentives)),
            DEPLOYMENT_SALT,
            0xf77AC7d0BEc8E680fbc3BdD7eD0ab8369b3A8e09,
            "IncentivesDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(PriceFetcher).creationCode, abi.encode(oracle)),
            DEPLOYMENT_SALT,
            0x1b097AA9119ADD4acB08810DFE789362f14Ce635,
            "PriceFetcher"
        );
        deployIfNeeded(
            type(TokenDataFetcher).creationCode,
            DEPLOYMENT_SALT,
            0x1108d189E4a8663132044D9A65d0022D9c8b048a,
            "TokenDataFetcher"
        );
        deployExtension(
            abi.encodePacked(type(BoostedFees).creationCode, abi.encode(core, true)),
            DEPLOYMENT_SALT,
            boostedFeesCallPoints(true),
            0xd4474B117f70009AfC4F776cAFDeD7f83eFcEACC,
            "BoostedFees(concentrated)"
        );
        deployExtension(
            abi.encodePacked(type(BoostedFees).creationCode, abi.encode(core, false)),
            DEPLOYMENT_SALT,
            boostedFeesCallPoints(false),
            0x94Ac937Da78fB3A65048f6Bfde7ec465986fc008,
            "BoostedFees(stableswap)"
        );
        deployIfNeeded(
            abi.encodePacked(type(ManualPoolBooster).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0xE688B297cf3c2A368e6e1dd8223A982E7609BD66,
            "ManualPoolBooster"
        );
        deployIfNeeded(
            abi.encodePacked(type(BoostedFeesDataFetcher).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0x995865041eAF3c7A8455f0A916437678543ef524,
            "BoostedFeesDataFetcher"
        );

        vm.stopBroadcast();
    }
}
