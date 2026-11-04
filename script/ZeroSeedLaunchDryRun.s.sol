// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IZeroSeedLaunch} from "../src/interfaces/extensions/IZeroSeedLaunch.sol";
import {IZeroSeedLaunchPeriphery} from "../src/interfaces/IZeroSeedLaunchPeriphery.sol";
import {ZeroSeedLaunch, zeroSeedLaunchCallPoints} from "../src/extensions/ZeroSeedLaunch.sol";
import {ZeroSeedLaunchPeriphery} from "../src/ZeroSeedLaunchPeriphery.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {CallPoints, addressToCallPoints} from "../src/types/callPoints.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PositionId} from "../src/types/positionId.sol";
import {PoolConfig} from "../src/types/poolConfig.sol";
import {PoolState} from "../src/types/poolState.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {liquidityDeltaToAmountDelta} from "../src/math/liquidity.sol";
import {decayedFee} from "../src/math/feeDecay.sol";
import {DETERMINISTIC_DEPLOYER, getCreate2Address, findExtensionSalt} from "./DeployAll.s.sol";

/// @title ZeroSeedLaunch native-ETH Base fork dry run
/// @notice Simulation only. Deploys `ZeroSeedLaunch(Core, address(0))` and `ZeroSeedLaunchPeriphery(Core, extension)`
/// on a pinned Base fork, then creates, buys, sells and claims through the production Yul router and the dry-run
/// periphery. It never starts a broadcast and never reads a signing key: every deployer, salt, owner, trader and
/// resulting address is a synthetic label-derived value. Whoever deploys an instance selects their own deployer,
/// funding and salts; only the init code, the Core address and the callpoint prefix are fixed by the source.
/// @dev Run from the repository root (the fork URL may be any Base archive node):
///   forge script --offline script/ZeroSeedLaunchDryRun.s.sol:ZeroSeedLaunchDryRun \
///     --fork-url https://mainnet.base.org --fork-block-number 52862800 -vvv
/// The script refuses any other chain, block or pinned dependency, and refuses a production source whose
/// immutable-free creation or runtime bytes differ from the frozen artifacts. Every `DRYRUN|key=value` line is an
/// input to the external verifier, which rebuilds the expected deployed runtimes from the compiler's
/// `immutableReferences` and compares them with the code hashes observed here. Nothing here hard-codes an
/// immutable offset: the in-EVM check scans the deployed runtime against the zero-immutable template and accepts a
/// difference only where the template holds a zero word and the deployment holds a known immutable value.
contract ZeroSeedLaunchDryRun is Script {
    using CoreLib for ICore;

    // Fork pin: Base block 52862800, its parent hash and the runtime hashes of the live dependencies at that block.
    uint256 constant FORK_BLOCK = 52862800;
    bytes32 constant FORK_PARENT_HASH = 0x849ba885211b7bc0eccb808b15e2c85103e819d45eca30dab81a13780dd78724;
    address payable constant CORE = payable(0x00000000000014aA86C5d3c41765bb24e11bd701);
    bytes32 constant CORE_CODEHASH = 0xc5f90c9d0dbc5037f8f9e248f4bb292e7c1824f584eb6550cb4cad525b38c71a;
    /// @dev Production Yul router on Base (v0.8 route encoding), used as-is from the fork state.
    address constant ROUTER = 0x03c8B90854b90AA22448b11e885F692972DA441C;
    bytes32 constant ROUTER_CODEHASH = 0x32ba8475c95ee5d9f7807f4ad9dce849929c992df9c68e9030e986d1854e726f;
    bytes32 constant DEPLOYER_CODEHASH = 0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;

    // Frozen production source identity: creation code without constructor arguments and runtime with every
    // immutable zeroed, as compiled from the frozen commit. Any production change fails here first.
    bytes32 constant EXTENSION_CREATION_HASH = 0x50dc9c4148f4c81f8f689a2b62ed70c9590366fdb963072b4f2b89361f1dcd7c;
    bytes32 constant EXTENSION_TEMPLATE_HASH = 0x25637ad2d1071b641f275d3b1037616b8836d2445501c05d38618764fa924167;
    bytes32 constant PERIPHERY_CREATION_HASH = 0x79a8ef83d84f8110f6fec96a2d964a39913f81ab23a304fb19fb577fe29ef56c;
    bytes32 constant PERIPHERY_TEMPLATE_HASH = 0x271683d2c3cf5e518fc5aa531f8568191b166a262a43e05d13325f0630dd5d7a;

    // Decided launch economics: 50% -> 0.3% over 3600 s on the 600 s half-life table, 18/18 reference geometry.
    uint64 constant INITIAL_FEE = 9223372036854775808;
    uint64 constant FINAL_FEE = 55340232221128654;
    uint32 constant FEE_DURATION = 3600;
    int32 constant ASK_TICK = -13815500;
    int32 constant UPPER_TICK = -9210300;
    uint32 constant TICK_SPACING = 100;
    uint128 constant REQUESTED_SUPPLY = 1_000_000_000e18;

    // Synthetic actors. Label-derived, never funded on a live chain, never a selection.
    address constant DEPLOYER_SENDER = address(uint160(uint256(keccak256("ZeroSeedLaunch dry-run synthetic sender"))));
    address constant OWNER = address(uint160(uint256(keccak256("ZeroSeedLaunch dry-run synthetic owner"))));
    address constant NEW_OWNER = address(uint160(uint256(keccak256("ZeroSeedLaunch dry-run synthetic new owner"))));
    address constant TRADER = address(uint160(uint256(keccak256("ZeroSeedLaunch dry-run synthetic trader"))));
    address constant RECIPIENT = address(uint160(uint256(keccak256("ZeroSeedLaunch dry-run synthetic recipient"))));
    bytes32 constant USER_SALT = keccak256("ZeroSeedLaunch dry-run synthetic launch salt");

    struct Deployed {
        address addr;
        bytes32 salt;
        bytes32 initCodeHash;
        uint256 executionGas;
        uint256 runtimeLength;
    }

    struct Swap {
        string label;
        int256 specified;
        int256 calculated;
        int128 delta0;
        int128 delta1;
        uint64 feeRate;
        uint128 feeAmount;
        bool feeIsToken1;
        uint256 gas;
    }

    ZeroSeedLaunch launch;
    ZeroSeedLaunchPeriphery periphery;
    IZeroSeedLaunch.Installation inst;
    PoolId poolId;
    /// @dev Pool-perspective totals of the fee-inclusive swap deltas, for the balance reconciliation.
    int256 sumDelta0;
    int256 sumDelta1;
    uint256 claimed0;
    uint256 claimed1;
    /// @dev Core's ETH balance before this launch traded; Core holds every other pool's ETH too.
    uint256 coreEthBaseline;

    function run() public {
        _checkFork();
        vm.label(CORE, "Core");
        vm.label(ROUTER, "YulRouter");
        vm.label(DEPLOYER_SENDER, "syntheticDeployer");
        vm.label(OWNER, "syntheticOwner");
        vm.label(NEW_OWNER, "syntheticNewOwner");
        vm.label(TRADER, "syntheticTrader");
        vm.label(RECIPIENT, "syntheticRecipient");

        _deployExtension();
        _deployPeriphery();
        _create();
        _trade();
        _claimAndTransfer();
        _reconcile();
        console2.log(
            "PASS: native two-contract deployment, immutables, registration, create, router buy/sell, claim and transfer on the fork; no broadcast, no key"
        );
    }

    function _checkFork() private view {
        require(block.chainid == 8453 && block.number == FORK_BLOCK, "wrong fork");
        require(blockhash(FORK_BLOCK - 1) == FORK_PARENT_HASH, "wrong fork parent");
        require(CORE.codehash == CORE_CODEHASH, "Core runtime");
        require(ROUTER.codehash == ROUTER_CODEHASH, "router runtime");
        require(DETERMINISTIC_DEPLOYER.codehash == DEPLOYER_CODEHASH, "deployer runtime");
        _log("fork.chainId", block.chainid);
        _log("fork.block", block.number);
        _log("fork.timestamp", block.timestamp);
        _log("fork.parentHash", FORK_PARENT_HASH);
        _log("core.address", CORE);
        _log("core.codehash", CORE_CODEHASH);
        _log("router.address", ROUTER);
        _log("router.codehash", ROUTER_CODEHASH);
        _log("deployer.address", DETERMINISTIC_DEPLOYER);
        _log("deployer.codehash", DEPLOYER_CODEHASH);
    }

    /// @dev `ZeroSeedLaunch(Core, address(0))`: a native-ETH instance. The salt is mined so the address carries the
    /// callpoint prefix, exactly as `DeployAll.deployExtension` does; the starting salt is synthetic.
    function _deployExtension() private {
        bytes memory creation = type(ZeroSeedLaunch).creationCode;
        require(keccak256(creation) == EXTENSION_CREATION_HASH, "extension creation code changed");
        bytes memory template = vm.getDeployedCode("ZeroSeedLaunch.sol:ZeroSeedLaunch");
        require(keccak256(template) == EXTENSION_TEMPLATE_HASH, "extension runtime template changed");
        bytes memory args = abi.encode(ICore(CORE), NATIVE_TOKEN_ADDRESS);
        bytes memory initCode = bytes.concat(creation, args);
        require(template.length <= 24576 && initCode.length <= 49152, "extension code size limit");

        CallPoints memory points = zeroSeedLaunchCallPoints();
        bytes32 startingSalt = keccak256("ZeroSeedLaunch Base dry-run: SYNTHETIC SALT, NOT FOR PRODUCTION");
        bytes32 salt = findExtensionSalt(startingSalt, keccak256(initCode), points);
        address predicted = getCreate2Address(salt, keccak256(initCode));
        require(predicted.code.length == 0 && !ICore(CORE).isExtensionRegistered(predicted), "already deployed");

        _log("extension.constructorArgs", args);
        _log("extension.creationCodeHash", keccak256(creation));
        _log("extension.creationCodeLength", creation.length);
        _log("extension.initCodeHash", keccak256(initCode));
        _log("extension.initCodeLength", initCode.length);
        _log("extension.runtimeTemplateHash", keccak256(template));
        _log("extension.runtimeLength", template.length);
        _log("extension.callPointsByte", uint256(points.toUint8()));
        _log("extension.syntheticStartingSalt", startingSalt);
        _log("extension.syntheticSalt", salt);
        _log("extension.syntheticAddress", predicted);

        Deployed memory d = _deploy(salt, initCode, predicted);
        launch = ZeroSeedLaunch(predicted);
        vm.label(predicted, "ZeroSeedLaunch(synthetic)");
        _log("extension.deployerCallExecutionGas", d.executionGas);
        _log("extension.deployedCodehash", predicted.codehash);

        // The quote immutable is the zero address, so its two sites are zero in both template and deployment and
        // cannot be told apart in the bytecode; `quoteToken()` is the check for them. Every other difference must
        // be a Core word.
        address[] memory values = new address[](1);
        values[0] = CORE;
        uint256[] memory counts = _checkImmutables(predicted.code, template, values);
        _log("extension.coreImmutableSites", counts[0]);
        require(launch.quoteToken() == NATIVE_TOKEN_ADDRESS, "quoteToken");
        require(ICore(CORE).isExtensionRegistered(predicted), "not registered");
        require(
            addressToCallPoints(predicted).eq(points) && uint8(uint160(predicted) >> 152) == points.toUint8(),
            "callpoints"
        );
        _log("extension.quoteToken", launch.quoteToken());
        _log("extension.registered", true);
    }

    /// @dev `ZeroSeedLaunchPeriphery(Core, extension)`: no address constraint, so any deployment route works; the
    /// dry run uses the same deterministic deployer with a synthetic salt so the address is reproducible.
    function _deployPeriphery() private {
        bytes memory creation = type(ZeroSeedLaunchPeriphery).creationCode;
        require(keccak256(creation) == PERIPHERY_CREATION_HASH, "periphery creation code changed");
        bytes memory template = vm.getDeployedCode("ZeroSeedLaunchPeriphery.sol:ZeroSeedLaunchPeriphery");
        require(keccak256(template) == PERIPHERY_TEMPLATE_HASH, "periphery runtime template changed");
        bytes memory args = abi.encode(ICore(CORE), IZeroSeedLaunch(address(launch)));
        bytes memory initCode = bytes.concat(creation, args);
        bytes32 salt = keccak256("ZeroSeedLaunchPeriphery Base dry-run: SYNTHETIC SALT, NOT FOR PRODUCTION");
        address predicted = getCreate2Address(salt, keccak256(initCode));
        require(predicted.code.length == 0, "already deployed");

        _log("periphery.constructorArgs", args);
        _log("periphery.creationCodeHash", keccak256(creation));
        _log("periphery.creationCodeLength", creation.length);
        _log("periphery.initCodeHash", keccak256(initCode));
        _log("periphery.initCodeLength", initCode.length);
        _log("periphery.runtimeTemplateHash", keccak256(template));
        _log("periphery.runtimeLength", template.length);
        _log("periphery.syntheticSalt", salt);
        _log("periphery.syntheticAddress", predicted);

        Deployed memory d = _deploy(salt, initCode, predicted);
        periphery = ZeroSeedLaunchPeriphery(predicted);
        vm.label(predicted, "ZeroSeedLaunchPeriphery(synthetic)");
        _log("periphery.deployerCallExecutionGas", d.executionGas);
        _log("periphery.deployedCodehash", predicted.codehash);

        address[] memory values = new address[](2);
        values[0] = CORE;
        values[1] = address(launch);
        uint256[] memory counts = _checkImmutables(predicted.code, template, values);
        _log("periphery.coreImmutableSites", counts[0]);
        _log("periphery.launchImmutableSites", counts[1]);
        require(address(periphery.LAUNCH()) == address(launch), "periphery LAUNCH");
        _log("periphery.LAUNCH", address(periphery.LAUNCH()));
    }

    function _deploy(bytes32 salt, bytes memory initCode, address predicted) private returns (Deployed memory d) {
        vm.startPrank(DEPLOYER_SENDER);
        uint256 gasBefore = gasleft();
        (bool success, bytes memory result) = DETERMINISTIC_DEPLOYER.call(abi.encodePacked(salt, initCode));
        d.executionGas = gasBefore - gasleft();
        vm.stopPrank();
        require(success && result.length == 20 && address(bytes20(result)) == predicted, "deployment failed");
        d.addr = predicted;
        d.salt = salt;
        d.initCodeHash = keccak256(initCode);
        d.runtimeLength = predicted.code.length;
    }

    /// @dev Accepts `deployed` only if it equals `template` everywhere except at 32-byte words that are zero in the
    /// template and hold one of `values` (left-padded) in the deployment; returns how many words held each value.
    function _checkImmutables(bytes memory deployed, bytes memory template, address[] memory values)
        private
        pure
        returns (uint256[] memory counts)
    {
        require(deployed.length == template.length, "runtime length");
        counts = new uint256[](values.length);
        uint256 i;
        while (i < deployed.length) {
            if (deployed[i] == template[i]) {
                i++;
                continue;
            }
            // The first differing byte is the first nonzero byte of an embedded value, so the word starts
            // 12 + (leading zero bytes of the address) earlier.
            bool matched;
            for (uint256 v; v < values.length && !matched; v++) {
                uint256 lead = 12 + _leadingZeroBytes(values[v]);
                if (i < lead || i - lead + 32 > deployed.length) continue;
                uint256 start = i - lead;
                if (
                    _word(deployed, start) == bytes32(uint256(uint160(values[v])))
                        && _word(template, start) == bytes32(0)
                ) {
                    counts[v]++;
                    i = start + 32;
                    matched = true;
                }
            }
            require(matched, "unexpected runtime difference");
        }
    }

    function _leadingZeroBytes(address value) private pure returns (uint256 n) {
        uint160 v = uint160(value);
        require(v != 0, "zero immutable is not detectable");
        while (v >> 152 == 0) {
            v <<= 8;
            n++;
        }
    }

    function _word(bytes memory data, uint256 offset) private pure returns (bytes32 w) {
        assembly ("memory-safe") {
            w := mload(add(add(data, 32), offset))
        }
    }

    /// @dev Preview through the periphery for the synthetic owner, bind supply and liquidity, create, and check the
    /// token address against the documented CREATE2 derivation, the events, the pool, the position and ownership.
    function _create() private {
        IZeroSeedLaunch.LaunchParameters memory p = IZeroSeedLaunch.LaunchParameters({
            name: "Dry Run",
            symbol: "DRY",
            decimals: 18,
            supply: REQUESTED_SUPPLY,
            liquidity: 0,
            askTick: ASK_TICK,
            upperTick: UPPER_TICK,
            tickSpacing: TICK_SPACING,
            tradingStart: uint64(block.timestamp + 300),
            feeDuration: FEE_DURATION,
            initialFee: INITIAL_FEE,
            finalFee: FINAL_FEE,
            salt: USER_SALT
        });
        IZeroSeedLaunch.Installation memory preview = periphery.previewInstallation(OWNER, p);
        require(
            preview.poolKey.config.extension() == address(launch) && preview.poolKey.config.fee() == 0, "pool config"
        );
        require(
            preview.poolKey.token0 == NATIVE_TOKEN_ADDRESS && preview.poolKey.token1 == preview.token, "native order"
        );
        p.liquidity = preview.liquidity;
        p.supply = preview.installedSupply;

        // Token address = CREATE2(extension, keccak256(abi.encode(periphery, keccak256(abi.encode(owner, salt)))),
        // keccak256(MintableERC20 creation ++ abi.encode(extension, name, symbol, decimals))).
        bytes32 tokenSalt = keccak256(abi.encode(address(periphery), keccak256(abi.encode(OWNER, USER_SALT))));
        bytes32 tokenInitHash = keccak256(
            bytes.concat(type(MintableERC20).creationCode, abi.encode(address(launch), p.name, p.symbol, p.decimals))
        );
        address derived = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(launch), tokenSalt, tokenInitHash))))
        );
        require(derived == preview.token, "token address derivation");

        vm.recordLogs();
        vm.prank(OWNER);
        uint256 gasBefore = gasleft();
        inst = periphery.create(p);
        uint256 createGas = gasBefore - gasleft();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        require(
            inst.token == preview.token && inst.liquidity == preview.liquidity
                && inst.installedSupply == preview.installedSupply && inst.initialTick == preview.initialTick,
            "preview binding"
        );
        poolId = inst.poolKey.toPoolId();
        require(MintableERC20(inst.token).totalSupply() == p.supply, "supply");
        require(MintableERC20(inst.token).balanceOf(CORE) == p.supply, "Core holds the supply");
        require(MintableERC20(inst.token).owner() == address(0), "minter not renounced");
        PoolState state = ICore(CORE).poolState(poolId);
        require(state.tick() == inst.initialTick && inst.initialTick == inst.positionId.tickUpper(), "initial tick");
        require(state.liquidity() == 0, "token1 launch starts above its range");
        require(
            ICore(CORE).poolPositions(poolId, address(launch), inst.positionId).liquidity == inst.liquidity, "position"
        );
        IZeroSeedLaunch.Launch memory stored = launch.getLaunch(poolId);
        require(stored.controller == address(periphery), "controller is the periphery");
        require(
            stored.tradingStart == p.tradingStart && stored.initialFee == INITIAL_FEE && stored.finalFee == FINAL_FEE,
            "schedule"
        );
        require(periphery.launchOwner(poolId) == OWNER, "owner of record");

        bool sawCreated;
        bool sawOwner;
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter == address(launch) && l.topics[0] == IZeroSeedLaunch.LaunchCreated.selector) {
                require(
                    l.topics[1] == PoolId.unwrap(poolId) && address(uint160(uint256(l.topics[2]))) == inst.token
                        && address(uint160(uint256(l.topics[3]))) == address(periphery),
                    "LaunchCreated topics"
                );
                sawCreated = true;
            }
            if (l.emitter == address(periphery) && l.topics[0] == IZeroSeedLaunchPeriphery.LaunchOwnerChanged.selector)
            {
                require(
                    l.topics[1] == PoolId.unwrap(poolId) && l.topics[2] == bytes32(0)
                        && address(uint160(uint256(l.topics[3]))) == OWNER,
                    "LaunchOwnerChanged topics"
                );
                sawOwner = true;
            }
        }
        require(sawCreated && sawOwner, "creation events");

        _log("launch.owner", OWNER);
        _log("launch.userSalt", USER_SALT);
        _log("launch.token", inst.token);
        _log("launch.poolId", PoolId.unwrap(poolId));
        _log("launch.poolKey.token0", inst.poolKey.token0);
        _log("launch.poolKey.token1", inst.poolKey.token1);
        _log("launch.poolKey.config", PoolConfig.unwrap(inst.poolKey.config));
        _log("launch.positionId", PositionId.unwrap(inst.positionId));
        _log("launch.initialTick", int256(inst.initialTick));
        _log("launch.liquidity", uint256(inst.liquidity));
        _log("launch.installedSupply", uint256(inst.installedSupply));
        _log("launch.tradingStart", uint256(p.tradingStart));
        _log("launch.createGas", createGas);
        _log("topic.LaunchCreated", IZeroSeedLaunch.LaunchCreated.selector);
        _log("topic.LaunchSwapped", IZeroSeedLaunch.LaunchSwapped.selector);
        _log("topic.CreatorFeesClaimed", IZeroSeedLaunch.CreatorFeesClaimed.selector);
        _log("topic.LaunchOwnerChanged", IZeroSeedLaunchPeriphery.LaunchOwnerChanged.selector);
        _log("topic.LaunchFeesClaimed", IZeroSeedLaunchPeriphery.LaunchFeesClaimed.selector);
    }

    /// @dev Trades through the production router from a synthetic trader: refused before the start, then an exact
    /// native input buy, an exact-output buy whose unspent value is refunded, an exact-input sell paid out in ETH,
    /// and a buy halfway through the window at the decayed rate.
    function _trade() private {
        vm.deal(TRADER, 100 ether);
        coreEthBaseline = CORE.balance;
        uint64 start = launch.getLaunch(poolId).tradingStart;
        PoolKey memory key = inst.poolKey;

        vm.startPrank(TRADER);
        MintableERC20(inst.token).approve(ROUTER, type(uint256).max);
        (bool early,) =
            ROUTER.call{value: 1 ether}(_route(key, NATIVE_TOKEN_ADDRESS, inst.token, 1 ether, 1, uint32(start)));
        require(!early, "buy before tradingStart must fail");
        vm.stopPrank();

        vm.warp(start);
        require(launch.feeAt(poolId, block.timestamp) == INITIAL_FEE, "initial rate at start");
        uint256 ethBefore = TRADER.balance;
        Swap memory s = _swap("buyExactIn", key, NATIVE_TOKEN_ADDRESS, inst.token, 1 ether, 1 ether);
        require(s.specified == 1 ether && ethBefore - TRADER.balance == 1 ether, "exact native input paid");
        require(uint256(s.calculated) == MintableERC20(inst.token).balanceOf(TRADER), "tokens received");
        require(s.feeRate == INITIAL_FEE && s.feeIsToken1 && s.delta0 == 1 ether, "fee on the launch token");
        require(CORE.balance - coreEthBaseline == 1 ether, "Core received the input");
        (uint128 f0, uint128 f1) = launch.creatorFees(key);
        require(f0 == 0 && f1 == s.feeAmount, "ledger after the first buy");
        _log("swap.buyExactIn.traderEthPaid", ethBefore - TRADER.balance);

        // Exact output: 10 ETH attached as the maximum input, the router refunds what the route does not spend.
        ethBefore = TRADER.balance;
        uint256 tokensBefore = MintableERC20(inst.token).balanceOf(TRADER);
        s = _swap("buyExactOut", key, inst.token, NATIVE_TOKEN_ADDRESS, -1e20, 10 ether);
        require(
            s.specified == -1e20 && MintableERC20(inst.token).balanceOf(TRADER) - tokensBefore == 1e20, "exact output"
        );
        // The router reports the calculated side from the trader's view: negative when paid.
        uint256 spent = uint256(-s.calculated);
        require(ethBefore - TRADER.balance == spent, "only the spent input leaves the trader");
        require(!s.feeIsToken1 && uint256(uint128(s.delta0)) == spent, "fee on the ETH input");
        _log("swap.buyExactOut.valueAttached", uint256(10 ether));
        _log("swap.buyExactOut.ethSpent", spent);
        _log("swap.buyExactOut.ethRefunded", 10 ether - spent);

        // Exact-input sell of half the holdings: ETH is paid to the trader, the fee is taken from that ETH.
        int128 sellAmount = int128(uint128(MintableERC20(inst.token).balanceOf(TRADER) / 2));
        ethBefore = TRADER.balance;
        s = _swap("sellExactIn", key, inst.token, NATIVE_TOKEN_ADDRESS, sellAmount, 0);
        require(s.specified == sellAmount && TRADER.balance - ethBefore == uint256(s.calculated), "ETH paid out");
        require(!s.feeIsToken1 && s.delta1 == sellAmount, "fee on the ETH output");
        _log("swap.sellExactIn.ethReceived", TRADER.balance - ethBefore);

        // Halfway through the window the rate follows the table; the event rate must equal `feeAt`.
        vm.warp(start + FEE_DURATION / 2);
        uint64 expected = decayedFee(INITIAL_FEE, FINAL_FEE, FEE_DURATION, FEE_DURATION / 2);
        require(launch.feeAt(poolId, block.timestamp) == expected, "feeAt halfway");
        s = _swap("buyExactInHalfway", key, NATIVE_TOKEN_ADDRESS, inst.token, 1 ether, 1 ether);
        require(s.feeRate == expected && s.feeIsToken1, "decayed rate applied");
        _log("fee.rateAtHalfway", uint256(expected));
        _log("fee.rateAtEnd", uint256(launch.feeAt(poolId, start + FEE_DURATION)));
        require(launch.feeAt(poolId, start + FEE_DURATION) == FINAL_FEE, "final rate");
    }

    /// @dev One router call with the route quoted first; records the `LaunchSwapped` event and the settled amounts.
    function _swap(
        string memory label,
        PoolKey memory key,
        address specified,
        address calculated,
        int128 amount,
        uint256 value
    ) private returns (Swap memory s) {
        s.label = label;
        uint32 deadline = uint32(block.timestamp);
        int256 quoted =
            _quote(_route(key, specified, calculated, amount, amount < 0 ? type(int128).min : int128(1), deadline));
        int128 minOut = amount < 0 ? type(int128).min : int128(quoted);
        bytes memory route = _route(key, specified, calculated, amount, minOut, deadline);
        vm.recordLogs();
        vm.startPrank(TRADER);
        uint256 gasBefore = gasleft();
        (bool ok, bytes memory result) = ROUTER.call{value: value}(route);
        s.gas = gasBefore - gasleft();
        vm.stopPrank();
        require(ok, label);
        (,, s.specified, s.calculated) = abi.decode(result, (address, address, int256, int256));
        require(s.calculated == quoted, "router quote == execution");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(launch) || l.topics[0] != IZeroSeedLaunch.LaunchSwapped.selector) continue;
            require(!seen, "one LaunchSwapped per swap");
            require(
                l.topics[1] == PoolId.unwrap(poolId) && address(uint160(uint256(l.topics[2]))) == ROUTER, "swap topics"
            );
            (s.delta0, s.delta1, s.feeRate, s.feeAmount, s.feeIsToken1) =
                abi.decode(l.data, (int128, int128, uint64, uint128, bool));
            seen = true;
        }
        require(seen, "LaunchSwapped emitted");
        sumDelta0 += s.delta0;
        sumDelta1 += s.delta1;
        string memory prefix = string.concat("swap.", label, ".");
        _log(string.concat(prefix, "timestamp"), block.timestamp);
        _log(string.concat(prefix, "specified"), s.specified);
        _log(string.concat(prefix, "calculated"), s.calculated);
        _log(string.concat(prefix, "delta0"), int256(s.delta0));
        _log(string.concat(prefix, "delta1"), int256(s.delta1));
        _log(string.concat(prefix, "feeRate"), uint256(s.feeRate));
        _log(string.concat(prefix, "feeAmount"), uint256(s.feeAmount));
        _log(string.concat(prefix, "feeIsToken1"), s.feeIsToken1);
        _log(string.concat(prefix, "routerCallGas"), s.gas);
    }

    /// @dev Owner claims to a recipient, both assets in one payout and one event from each contract; a non-owner
    /// is refused; after a transfer the new owner claims and the original owner is refused.
    function _claimAndTransfer() private {
        PoolKey memory key = inst.poolKey;
        (uint128 l0, uint128 l1) = launch.creatorFees(key);
        require(l0 != 0 && l1 != 0, "both ledgers funded");
        _log("claim1.ledger0", uint256(l0));
        _log("claim1.ledger1", uint256(l1));

        vm.prank(TRADER);
        (bool notOwner,) = address(periphery).call(abi.encodeCall(periphery.claimFees, (key, TRADER)));
        require(!notOwner, "non-owner claim must fail");

        uint256 ethBefore = RECIPIENT.balance;
        vm.recordLogs();
        vm.prank(OWNER);
        uint256 gasBefore = gasleft();
        (uint128 a0, uint128 a1) = periphery.claimFees(key, RECIPIENT);
        uint256 claimGas = gasBefore - gasleft();
        require(a0 == l0 && a1 == l1, "whole ledger");
        require(RECIPIENT.balance - ethBefore == a0, "ETH paid to the recipient");
        require(MintableERC20(inst.token).balanceOf(RECIPIENT) == a1, "tokens paid to the recipient");
        (uint128 z0, uint128 z1) = launch.creatorFees(key);
        require(z0 == 0 && z1 == 0, "ledger emptied");
        _checkClaimEvents(vm.getRecordedLogs(), OWNER, RECIPIENT, a0, a1);
        claimed0 += a0;
        claimed1 += a1;
        _log("claim1.amount0", uint256(a0));
        _log("claim1.amount1", uint256(a1));
        _log("claim1.recipient", RECIPIENT);
        _log("claim1.gas", claimGas);

        // Ownership moves with its future fees; the initial creator stays in the first LaunchOwnerChanged.
        vm.recordLogs();
        vm.prank(OWNER);
        periphery.transferLaunch(poolId, NEW_OWNER);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        require(
            logs.length == 1 && logs[0].topics[0] == IZeroSeedLaunchPeriphery.LaunchOwnerChanged.selector
                && address(uint160(uint256(logs[0].topics[2]))) == OWNER
                && address(uint160(uint256(logs[0].topics[3]))) == NEW_OWNER,
            "transfer event"
        );
        require(periphery.launchOwner(poolId) == NEW_OWNER, "new owner of record");
        require(launch.getLaunch(poolId).controller == address(periphery), "controller unchanged by transfer");

        _swap("buyExactInAfterTransfer", inst.poolKey, NATIVE_TOKEN_ADDRESS, inst.token, 1 ether, 1 ether);
        vm.prank(OWNER);
        (bool oldOwner,) = address(periphery).call(abi.encodeCall(periphery.claimFees, (key, OWNER)));
        require(!oldOwner, "previous owner refused after transfer");
        (l0, l1) = launch.creatorFees(key);
        vm.recordLogs();
        vm.prank(NEW_OWNER);
        (a0, a1) = periphery.claimFees(key, NEW_OWNER);
        require(a0 == l0 && a1 == l1 && a1 != 0, "new owner claims the fees since the transfer");
        _checkClaimEvents(vm.getRecordedLogs(), NEW_OWNER, NEW_OWNER, a0, a1);
        claimed0 += a0;
        claimed1 += a1;
        _log("claim2.owner", NEW_OWNER);
        _log("claim2.amount0", uint256(a0));
        _log("claim2.amount1", uint256(a1));
    }

    /// @dev A claim emits exactly one `CreatorFeesClaimed` (extension ledger, controller = periphery) and one
    /// `LaunchFeesClaimed` (periphery payout, owner and recipient) with the same amounts: one payout, two records.
    function _checkClaimEvents(Vm.Log[] memory logs, address owner, address recipient, uint128 a0, uint128 a1)
        private
        view
    {
        uint256 ledgerEvents;
        uint256 payoutEvents;
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter == address(launch) && l.topics[0] == IZeroSeedLaunch.CreatorFeesClaimed.selector) {
                (uint128 e0, uint128 e1) = abi.decode(l.data, (uint128, uint128));
                require(
                    address(uint160(uint256(l.topics[2]))) == address(periphery) && e0 == a0 && e1 == a1,
                    "CreatorFeesClaimed"
                );
                ledgerEvents++;
            }
            if (l.emitter == address(periphery) && l.topics[0] == IZeroSeedLaunchPeriphery.LaunchFeesClaimed.selector) {
                (uint128 e0, uint128 e1) = abi.decode(l.data, (uint128, uint128));
                require(
                    address(uint160(uint256(l.topics[2]))) == owner
                        && address(uint160(uint256(l.topics[3]))) == recipient && e0 == a0 && e1 == a1,
                    "LaunchFeesClaimed"
                );
                payoutEvents++;
            }
        }
        require(ledgerEvents == 1 && payoutEvents == 1, "one ledger event and one payout event per claim");
    }

    /// @dev Core's balance movement for this launch equals the fee-inclusive swap deltas less the claims, and covers
    /// the live principal plus the open ledger; the remainder is unowned rounding dust.
    function _reconcile() private view {
        PoolKey memory key = inst.poolKey;
        uint128 liquidity = ICore(CORE).poolPositions(poolId, address(launch), inst.positionId).liquidity;
        require(liquidity == inst.liquidity, "principal liquidity unchanged");
        (int128 d0, int128 d1) = liquidityDeltaToAmountDelta(
            ICore(CORE).poolState(poolId).sqrtRatio(),
            -int128(liquidity),
            tickToSqrtRatio(inst.positionId.tickLower()),
            tickToSqrtRatio(inst.positionId.tickUpper())
        );
        uint256 principal0 = uint256(uint128(-d0));
        uint256 principal1 = uint256(uint128(-d1));
        (uint128 l0, uint128 l1) = launch.creatorFees(key);

        // Core's ETH balance is shared with every other pool; only this launch's movement is attributable.
        uint256 coreEth = CORE.balance - coreEthBaseline;
        uint256 coreToken = MintableERC20(inst.token).balanceOf(CORE);
        require(int256(coreEth) == sumDelta0 - int256(claimed0), "ETH movement == swap deltas - claims");
        require(
            int256(coreToken) == int256(uint256(inst.installedSupply)) + sumDelta1 - int256(claimed1), "token balance"
        );
        require(coreEth >= principal0 + l0 && coreToken >= principal1 + l1, "solvent");
        require(
            address(launch).balance == 0 && address(periphery).balance == 0 && ROUTER.balance == 0, "no stranded ETH"
        );
        require(
            MintableERC20(inst.token).balanceOf(address(launch)) == 0
                && MintableERC20(inst.token).balanceOf(address(periphery)) == 0
                && MintableERC20(inst.token).balanceOf(ROUTER) == 0,
            "no stranded tokens"
        );
        _log("reconcile.coreEthMovement", coreEth);
        _log("reconcile.coreTokenBalance", coreToken);
        _log("reconcile.principal0", principal0);
        _log("reconcile.principal1", principal1);
        _log("reconcile.openLedger0", uint256(l0));
        _log("reconcile.openLedger1", uint256(l1));
        _log("reconcile.claimed0", claimed0);
        _log("reconcile.claimed1", claimed1);
        _log("reconcile.dust0", coreEth - principal0 - l0);
        _log("reconcile.dust1", coreToken - principal1 - l1);
        _log("reconcile.poolTick", int256(ICore(CORE).poolState(poolId).tick()));
    }

    /// @dev yul-router v0.8 route: flags bit0 recipient, bit1 inclusive uint32 deadline; one forwarded hop to the
    /// extension (the same encoding the repository's router tests use).
    function _route(
        PoolKey memory key,
        address specified,
        address calculated,
        int128 amount,
        int128 minOut,
        uint32 deadline
    ) private pure returns (bytes memory) {
        return bytes.concat(
            bytes1(uint8(3)),
            bytes1(uint8(0)),
            bytes20(specified),
            bytes20(calculated),
            bytes16(uint128(minOut)),
            bytes20(TRADER),
            bytes4(deadline),
            bytes16(uint128(amount)),
            bytes1(uint8(0)),
            bytes1(uint8(1)),
            bytes20(key.config.extension()),
            bytes20(key.token0),
            bytes20(key.token1),
            bytes32(PoolConfig.unwrap(key.config)),
            bytes12(uint96(0)),
            bytes4(uint32(0))
        );
    }

    function _quote(bytes memory route) private returns (int256 calculated) {
        (bool ok, bytes memory result) = ROUTER.call(abi.encodeWithSignature("quote(bytes)", route));
        require(ok, "quote");
        (,,, calculated) = abi.decode(result, (address, address, int256, int256));
    }

    function _log(string memory key, uint256 value) private pure {
        console2.log(string.concat("DRYRUN|", key, "=", vm.toString(value)));
    }

    function _log(string memory key, int256 value) private pure {
        console2.log(string.concat("DRYRUN|", key, "=", vm.toString(value)));
    }

    function _log(string memory key, address value) private pure {
        console2.log(string.concat("DRYRUN|", key, "=", vm.toString(value)));
    }

    function _log(string memory key, bytes32 value) private pure {
        console2.log(string.concat("DRYRUN|", key, "=", vm.toString(value)));
    }

    function _log(string memory key, bytes memory value) private pure {
        console2.log(string.concat("DRYRUN|", key, "=", vm.toString(value)));
    }

    function _log(string memory key, bool value) private pure {
        console2.log(string.concat("DRYRUN|", key, "=", value ? "true" : "false"));
    }
}
