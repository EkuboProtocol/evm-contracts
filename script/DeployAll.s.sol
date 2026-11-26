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
            type(Core).creationCode, DEPLOYMENT_SALT, 0xFD2a569C4591F5c9E3f3Db5978D3b6827E09DDE3, "Core"
        );
        Core core = Core(payable(coreAddress));

        deployExtension(
            abi.encodePacked(type(MEVCapture).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            mevCaptureCallPoints(),
            0x553359E7B7b239C2Ee6BD11Cd648B154c854d4eA,
            "MEVCapture"
        );

        (address oracleAddress,) = deployExtension(
            abi.encodePacked(type(Oracle).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            oracleCallPoints(),
            0x51120C5fA594695299D6fF9EEE6951857CC5Ca18,
            "Oracle"
        );
        Oracle oracle = Oracle(oracleAddress);

        (address twammAddress,) = deployExtension(
            abi.encodePacked(type(TWAMM).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            twammCallPoints(),
            0xD49a61Cc57a02B00760AF2F2870a79901031f4df,
            "TWAMM"
        );
        TWAMM twamm = TWAMM(twammAddress);

        address incentivesAddress;
        (incentivesAddress,) = deployIfNeeded(
            type(Incentives).creationCode, DEPLOYMENT_SALT, 0x5b87cF457b47dde79bF886f42BB4c6ff5FCfCeA9, "Incentives"
        );
        Incentives incentives = Incentives(incentivesAddress);

        deployIfNeeded(
            abi.encodePacked(type(TokenWrapperFactory).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0x07b99AF660eE4754Ee0B9719c5dfB23573C6dF1D,
            "TokenWrapperFactory"
        );

        deployIfNeeded(
            abi.encodePacked(type(CoreDataFetcher).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0xE8829945664c59140Dd54656e9c588D3322214C1,
            "CoreDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(PoolKeyIndex).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0x6073Bd57346a09a755FF1F3B8Ee6871A291ac9B8,
            "PoolKeyIndex"
        );
        deployIfNeeded(
            abi.encodePacked(type(QuoteDataFetcher).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0x6e1898C01099F8142E9955fC39adAB2A123C4f42,
            "QuoteDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(TWAMMDataFetcher).creationCode, abi.encode(core, twamm)),
            DEPLOYMENT_SALT,
            0xB608DAB1cFdd363087f42A500F5D5e531878aE09,
            "TWAMMDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(IncentivesDataFetcher).creationCode, abi.encode(incentives)),
            DEPLOYMENT_SALT,
            0xcbA1Ab99443f94feeDd9dc9145cf67A83361aE3b,
            "IncentivesDataFetcher"
        );
        deployIfNeeded(
            abi.encodePacked(type(PriceFetcher).creationCode, abi.encode(oracle)),
            DEPLOYMENT_SALT,
            0x07B93CDDAeA873Ecead3D04fbBf4bC44A0601Bb8,
            "PriceFetcher"
        );
        deployIfNeeded(
            type(TokenDataFetcher).creationCode,
            DEPLOYMENT_SALT,
            0x119F0EE114B3A8886cdD0C75DFa30DA330C4AF77,
            "TokenDataFetcher"
        );
        deployExtension(
            abi.encodePacked(type(BoostedFees).creationCode, abi.encode(core, true)),
            DEPLOYMENT_SALT,
            boostedFeesCallPoints(true),
            0xD49854c071fd2F81A44e49570e8c221318687f92,
            "BoostedFees(concentrated)"
        );
        deployExtension(
            abi.encodePacked(type(BoostedFees).creationCode, abi.encode(core, false)),
            DEPLOYMENT_SALT,
            boostedFeesCallPoints(false),
            0x94B56C4BC995cAad4b4Ef14ef4951aacc416B296,
            "BoostedFees(stableswap)"
        );
        deployIfNeeded(
            abi.encodePacked(type(ManualPoolBooster).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0x52E722b525570D90588FC85F51581B8D6F4020A0,
            "ManualPoolBooster"
        );
        deployIfNeeded(
            abi.encodePacked(type(BoostedFeesDataFetcher).creationCode, abi.encode(core)),
            DEPLOYMENT_SALT,
            0xe3739F738D80413e24BAbC2C5715fF26062663d1,
            "BoostedFeesDataFetcher"
        );

        vm.stopBroadcast();
    }
}
