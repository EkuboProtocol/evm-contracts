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

/// @title DeployAll
/// @notice Deploys the Ekubo protocol core contracts
contract DeployAll is Script {
    Core public core;
    Oracle public oracle;
    TWAMM public twamm;
    BoostedFees public boostedFeesConcentrated;
    BoostedFees public boostedFeesStableswap;
    MEVCapture public mevCapture;
    Incentives public incentives;
    TokenWrapperFactory public tokenWrapperFactory;

    bytes32 constant DEPLOYMENT_SALT = 0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;
    bytes32 constant MEV_CAPTURE_ROUTER_DEPLOYMENT_SALT =
        0x38e2e731c4e6738213b17b239fe56c423f6bdc5b5969897c260d464c35a63982;

    error UnexpectedAddress(string name, address value);

    function run() public {
        vm.startBroadcast();

        console2.log("Deploying Core...");
        core = new Core{salt: DEPLOYMENT_SALT}();
        if (address(core) != 0x00000000000014aA86C5d3c41765bb24e11bd701) {
            revert UnexpectedAddress("Core", address(core));
        }
        console2.log("Core deployed at", address(core));

        console2.log("Deploying MEVCapture extension...");
        bytes32 mevCaptureInitCodeHash = keccak256(abi.encodePacked(type(MEVCapture).creationCode, abi.encode(core)));
        bytes32 mevCaptureSalt = findExtensionSalt(DEPLOYMENT_SALT, mevCaptureInitCodeHash, mevCaptureCallPoints());
        mevCapture = new MEVCapture{salt: mevCaptureSalt}(core);
        console2.log("MEVCapture deployed at", address(mevCapture));

        console2.log("Deploying Oracle extension...");
        bytes32 oracleInitCodeHash = keccak256(abi.encodePacked(type(Oracle).creationCode, abi.encode(core)));
        bytes32 oracleSalt = findExtensionSalt(DEPLOYMENT_SALT, oracleInitCodeHash, oracleCallPoints());
        oracle = new Oracle{salt: oracleSalt}(core);
        console2.log("Oracle deployed at", address(oracle));

        console2.log("Deploying TWAMM extension...");
        bytes32 twammInitCodeHash = keccak256(abi.encodePacked(type(TWAMM).creationCode, abi.encode(core)));
        bytes32 twammSalt = findExtensionSalt(DEPLOYMENT_SALT, twammInitCodeHash, twammCallPoints());
        twamm = new TWAMM{salt: twammSalt}(core);
        console2.log("TWAMM deployed at", address(twamm));

        console2.log("Deploying Incentives...");
        incentives = new Incentives{salt: DEPLOYMENT_SALT}();
        console2.log("Incentives deployed at", address(incentives));

        console2.log("Deploying TokenWrapperFactory...");
        tokenWrapperFactory = new TokenWrapperFactory{salt: DEPLOYMENT_SALT}(core);
        console2.log("TokenWrapperFactory deployed at", address(tokenWrapperFactory));

        console2.log("Deployed CoreDataFetcher", address(new CoreDataFetcher{salt: DEPLOYMENT_SALT}(core)));
        console2.log("Deployed QuoteDataFetcher", address(new QuoteDataFetcher{salt: DEPLOYMENT_SALT}(core)));
        console2.log("Deployed TWAMMDataFetcher", address(new TWAMMDataFetcher{salt: DEPLOYMENT_SALT}(core, twamm)));
        console2.log(
            "Deployed IncentivesDataFetcher", address(new IncentivesDataFetcher{salt: DEPLOYMENT_SALT}(incentives))
        );
        console2.log("Deployed PriceFetcher", address(new PriceFetcher{salt: DEPLOYMENT_SALT}(oracle)));
        console2.log("Deployed TokenDataFetcher", address(new TokenDataFetcher{salt: DEPLOYMENT_SALT}()));
        MEVCaptureRouter mevCaptureRouter =
            new MEVCaptureRouter{salt: MEV_CAPTURE_ROUTER_DEPLOYMENT_SALT}(core, address(mevCapture));
        if (address(mevCaptureRouter) != address(0xd26f20001a72a18C002b00e6710000d68700ce00)) {
            revert UnexpectedAddress("MEVCaptureRouter", address(mevCaptureRouter));
        }
        console2.log("Deployed MEVCaptureRouter", address(mevCaptureRouter));

        console2.log("Deploying BoostedFees(concentrated) extension...");
        bytes32 boostedFeesConcentratedInitCodeHash =
            keccak256(abi.encodePacked(type(BoostedFees).creationCode, abi.encode(core, true)));
        bytes32 boostedFeesConcentratedSalt =
            findExtensionSalt(DEPLOYMENT_SALT, boostedFeesConcentratedInitCodeHash, boostedFeesCallPoints(true));
        boostedFeesConcentrated = new BoostedFees{salt: boostedFeesConcentratedSalt}(core, true);
        console2.log("BoostedFees(concentrated) deployed at", address(boostedFeesConcentrated));

        console2.log("Deploying BoostedFees(stableswap) extension...");
        bytes32 boostedFeesStableswapInitCodeHash =
            keccak256(abi.encodePacked(type(BoostedFees).creationCode, abi.encode(core, true)));
        bytes32 boostedFeesStableswapSalt =
            findExtensionSalt(DEPLOYMENT_SALT, boostedFeesStableswapInitCodeHash, boostedFeesCallPoints(true));
        boostedFeesStableswap = new BoostedFees{salt: boostedFeesStableswapSalt}(core, false);
        console2.log("BoostedFees(concentrated) deployed at", address(boostedFeesStableswap));

        console2.log("Deployed ManualPoolBooster", address(new ManualPoolBooster{salt: DEPLOYMENT_SALT}(core)));
        console2.log(
            "Deployed BoostedFeesDataFetcher", address(new BoostedFeesDataFetcher{salt: DEPLOYMENT_SALT}(core))
        );

        vm.stopBroadcast();
    }
}
