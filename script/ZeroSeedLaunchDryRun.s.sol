// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IZeroSeedLaunch} from "../src/interfaces/extensions/IZeroSeedLaunch.sol";
import {ZeroSeedLaunch, zeroSeedLaunchCallPoints} from "../src/extensions/ZeroSeedLaunch.sol";
import {CallPoints, addressToCallPoints} from "../src/types/callPoints.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolState} from "../src/types/poolState.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {DETERMINISTIC_DEPLOYER, getCreate2Address, findExtensionSalt} from "./DeployAll.s.sol";

/// @title ZeroSeedLaunch Base fork dry run
/// @notice Simulation only: this script never starts a broadcast and never reads a signing key.
/// Its sender, salt and resulting address are synthetic, not a live deployment selection.
/// @dev Run: forge script --offline script/ZeroSeedLaunchDryRun.s.sol:ZeroSeedLaunchDryRun \
///   --fork-url https://mainnet.base.org --fork-block-number 52848400 -vvv
contract ZeroSeedLaunchDryRun is Script {
    using CoreLib for ICore;

    address payable constant CORE = payable(0x00000000000014aA86C5d3c41765bb24e11bd701);
    address constant WETH9 = 0x4200000000000000000000000000000000000006;
    bytes32 constant EXPECTED_INIT_HASH = 0xc7b9eea33efa88d712d9f8ecd176f5ba278b0f1428411b8311c4ccfc4b71253c;
    bytes32 constant EXPECTED_TEMPLATE_HASH = 0x4d44a77f7e4fcc5f7a321475c1dbfd1e0812ebbe8fc46a5e1973373fb6a9bf87;
    bytes32 constant EXPECTED_RUNTIME_HASH = 0x544ca86215569ce719087f6945fa603294c2e678ab73539dd57057a6bbe6aec6;

    function run() public {
        require(block.chainid == 8453 && block.number == 52848400, "wrong fork");
        require(
            blockhash(52848399) == 0x1e64e704c2178e5fd7d9fd894731f57c71a089d1d77ed3403ef7a0755cfa7086,
            "wrong fork parent"
        );
        require(CORE.codehash == 0xc5f90c9d0dbc5037f8f9e248f4bb292e7c1824f584eb6550cb4cad525b38c71a, "Core runtime");
        require(WETH9.codehash == 0x8a3a1f6a9f9dce633117adee5b458245835a8645a8c8726a26382a4622508b1c, "WETH runtime");
        require(
            DETERMINISTIC_DEPLOYER.codehash == 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989,
            "deployer runtime"
        );
        bytes memory initCode = abi.encodePacked(type(ZeroSeedLaunch).creationCode, abi.encode(ICore(CORE), WETH9));
        require(keccak256(initCode) == EXPECTED_INIT_HASH, "init code changed");
        bytes memory runtime = vm.getDeployedCode("ZeroSeedLaunch.sol:ZeroSeedLaunch");
        require(keccak256(runtime) == EXPECTED_TEMPLATE_HASH, "runtime template changed");
        // solc 0.8.33 immutableReferences for the pinned template: 13 Core sites, 2 quote sites.
        uint256[13] memory coreOffsets =
            [uint256(1526), 2745, 4167, 7351, 9488, 9750, 10093, 10262, 10462, 3974, 5314, 7820, 14163];
        for (uint256 i; i < coreOffsets.length; i++) {
            _fill(runtime, coreOffsets[i], CORE);
        }
        _fill(runtime, 3612, WETH9);
        _fill(runtime, 11471, WETH9);
        require(keccak256(runtime) == EXPECTED_RUNTIME_HASH, "embedded runtime changed");
        require(runtime.length <= 24576 && initCode.length <= 49152, "code size limit");

        CallPoints memory points = zeroSeedLaunchCallPoints();
        bytes32 startingSalt = keccak256("ZeroSeedLaunch Base dry-run: SYNTHETIC SALT, NOT FOR PRODUCTION");
        bytes32 salt = findExtensionSalt(startingSalt, keccak256(initCode), points);
        address predicted = getCreate2Address(salt, keccak256(initCode));
        require(predicted.code.length == 0 && !ICore(CORE).isExtensionRegistered(predicted), "already deployed");
        console2.log("synthetic address (not live)", predicted);
        console2.log("synthetic salt");
        console2.logBytes32(salt);
        console2.log("init-code hash");
        console2.logBytes32(keccak256(initCode));
        console2.log("runtime hash (immutables zeroed)");
        console2.logBytes32(EXPECTED_TEMPLATE_HASH);
        console2.log("runtime hash (Core and WETH embedded)");
        console2.logBytes32(EXPECTED_RUNTIME_HASH);
        address sender = address(uint160(uint256(keccak256("ZeroSeedLaunch dry-run synthetic sender"))));
        vm.startPrank(sender);
        uint256 gasBefore = gasleft();
        (bool success, bytes memory result) = DETERMINISTIC_DEPLOYER.call(abi.encodePacked(salt, initCode));
        uint256 executionGas = gasBefore - gasleft();
        vm.stopPrank();
        require(success && result.length == 20 && address(bytes20(result)) == predicted, "deployment failed");
        console2.log("deployer call execution gas (excludes intrinsic and calldata)", executionGas);
        require(keccak256(predicted.code) == keccak256(runtime), "runtime byte mismatch");
        ZeroSeedLaunch launch = ZeroSeedLaunch(predicted);
        require(launch.quoteToken() == WETH9, "quoteToken");
        require(ICore(CORE).isExtensionRegistered(predicted), "not registered");
        require(addressToCallPoints(predicted).eq(points) && uint8(uint160(predicted) >> 152) == 0x51, "callpoints");
        _checkCreate(launch, predicted);
        console2.log("PASS: runtime, embedded Core, quote, registration, preview and create; no broadcast");
    }

    function _checkCreate(ZeroSeedLaunch launch, address predicted) private {
        IZeroSeedLaunch.LaunchParameters memory p = IZeroSeedLaunch.LaunchParameters({
            quoteToken: WETH9,
            name: "Dry Run",
            symbol: "DRY",
            decimals: 18,
            supply: 1_000_000_000e18,
            liquidity: 0,
            askTick: -13815500,
            upperTick: -9210300,
            tickSpacing: 100,
            tradingStart: uint64(block.timestamp + 1 days),
            feeDuration: 3600,
            initialFee: 9223372036854775808,
            finalFee: 55340232221128654,
            decayFactor: 18425445863997925462,
            salt: keccak256("ZeroSeedLaunch dry-run synthetic launch salt")
        });
        address creator = address(uint160(uint256(keccak256("ZeroSeedLaunch dry-run synthetic creator"))));
        IZeroSeedLaunch.Installation memory preview = launch.previewInstallation(creator, p);
        require(preview.poolKey.config.extension() == predicted && preview.poolKey.config.fee() == 0, "pool config");
        console2.log("preview token", preview.token);
        console2.log("preview liquidity", preview.liquidity);
        console2.log("preview installed supply", preview.installedSupply);
        p.liquidity = preview.liquidity;
        p.supply = preview.installedSupply;
        vm.prank(creator);
        IZeroSeedLaunch.Installation memory created = launch.create(p);
        require(created.token == preview.token && created.liquidity == preview.liquidity, "preview binding");
        require(MintableERC20(created.token).totalSupply() == p.supply, "supply");
        require(MintableERC20(created.token).balanceOf(CORE) == p.supply, "Core balance");
        require(MintableERC20(created.token).owner() == address(0), "minter not renounced");
        PoolId poolId = created.poolKey.toPoolId();
        PoolState state = ICore(CORE).poolState(poolId);
        require(state.tick() == created.initialTick, "pool tick");
        require(
            state.liquidity() == (created.poolKey.token0 == created.token ? created.liquidity : 0), "active liquidity"
        );
        require(
            ICore(CORE).poolPositions(poolId, predicted, created.positionId).liquidity == created.liquidity, "position"
        );
        require(launch.getLaunch(poolId).creator == creator, "creator");
    }

    function _fill(bytes memory code, uint256 offset, address value) private pure {
        require(offset + 32 <= code.length, "immutable offset");
        for (uint256 i; i < 32; i++) {
            require(code[offset + i] == 0, "immutable not zero");
        }
        // The bounds check above proves the entire write is inside the allocated bytes buffer.
        assembly ("memory-safe") {
            mstore(add(add(code, 32), offset), value)
        }
    }
}
