// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IZeroSeedLaunch} from "../../src/interfaces/extensions/IZeroSeedLaunch.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IZeroSeedLaunchPeriphery} from "../../src/interfaces/IZeroSeedLaunchPeriphery.sol";
import {CoreStorageLayout} from "../../src/libraries/CoreStorageLayout.sol";
import {StorageSlot} from "../../src/types/storageSlot.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {LaunchTestRouter} from "../LaunchTestRouter.sol";
import {ZeroSeedLaunchBase} from "./ZeroSeedLaunch.t.sol";

contract ZeroSeedLaunchFreezeTest is ZeroSeedLaunchBase {
    using CoreLib for ICore;

    function test_unsignedPacket_localFactory_runtimeAndGas() public {
        address factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        uint256 base = 0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;
        vm.etch(
            factory,
            hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3"
        );
        bytes memory init = bytes.concat(vm.getCode("ZeroSeedLaunch.sol:ZeroSeedLaunch"), abi.encode(CORE));
        uint256 salt = base;
        address extension;
        while (true) {
            extension = computeCreate2Address(bytes32(salt), keccak256(init), factory);
            if (uint160(extension) >> 152 == 0x51) break;
            salt++;
        }
        assertEq(extension, 0x517621Ea1bf51F31826819b118fa4dfEb4D198D2, "unsigned packet extension");
        vm.cool(CORE);
        vm.coolSlot(CORE, StorageSlot.unwrap(CoreStorageLayout.isExtensionRegisteredSlot(extension)));
        vm.cool(factory);
        uint256 start = gasleft();
        (bool ok,) = factory.call{gas: 6_000_000}(bytes.concat(bytes32(salt), init));
        uint256 extensionGas = start - gasleft();
        assertTrue(ok, "local extension constructor and registration");
        assertEq(extension.codehash, 0xa66e365089d80b017edeb98237831260bf9e1b7d5f3965d42be5672de6b0d70e);
        assertEq(uint256(vm.load(CORE, StorageSlot.unwrap(CoreStorageLayout.isExtensionRegisteredSlot(extension)))), 1);
        init = bytes.concat(
            vm.getCode("ZeroSeedLaunchPeriphery.sol:ZeroSeedLaunchPeriphery"), abi.encode(CORE, extension)
        );
        address per = computeCreate2Address(bytes32(base), keccak256(init), factory);
        assertEq(per, 0x52378E3Cf26554bc83bBA4fa9ADe6d70Cfa23921, "unsigned packet periphery");
        vm.cool(factory);
        start = gasleft();
        (ok,) = factory.call{gas: 2_000_000}(bytes.concat(bytes32(base), init));
        uint256 peripheryGas = start - gasleft();
        assertTrue(ok, "local periphery constructor");
        assertEq(per.codehash, 0x171cccc4d1e60be2d8ad9ebb5bc43da0fbf49ba21b67a32cedbaf7ca474d8c55);
        assertEq(address(IZeroSeedLaunchPeriphery(per).LAUNCH()), extension);
        console2.log("PACKET|extensionExecutionGas", extensionGas);
        console2.log("PACKET|peripheryExecutionGas", peripheryGas);
    }

    function _receipt(address token, bool[7] memory seen) internal {
        bytes32[7] memory topics = [
            keccak256(
                "LaunchCreated(bytes32,address,address,(address,address,bytes32),bytes32,uint128,(bytes32,bytes32,uint128,address,int32,int32,uint64,uint64,uint64,uint64,bytes32),string)"
            ),
            keccak256("LaunchSwapped(bytes32,address,int128,int128,uint64,uint128,bool)"),
            keccak256("CreatorFeesClaimed(bytes32,address,uint128,uint128)"),
            keccak256("LaunchOwnerChanged(bytes32,address,address)"),
            keccak256("LaunchFeesClaimed(bytes32,address,address,uint128,uint128)"),
            keccak256("Transfer(address,address,uint256)"),
            keccak256("Approval(address,address,uint256)")
        ];
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(launch) && logs[i].emitter != address(periphery) && logs[i].emitter != token)
            {
                continue;
            }
            for (uint256 j; j < topics.length; j++) {
                if (logs[i].topics[0] == topics[j]) seen[j] = true;
            }
            console2.log(
                string.concat(
                    "ALL_EVENT|emitter=",
                    vm.toString(logs[i].emitter),
                    "|topics=",
                    vm.toString(abi.encode(logs[i].topics)),
                    "|data=",
                    vm.toString(logs[i].data)
                )
            );
        }
    }

    function test_allEvents_receiptFixtures() public {
        bool[7] memory seen;
        vm.recordLogs();
        (IZeroSeedLaunch.Installation memory inst,) = _create(false, 18, DECAY_RATE);
        _receipt(inst.token, seen);
        vm.recordLogs();
        vm.warp(START);
        _buy(inst.poolKey, inst.token, 1e18, false);
        vm.prank(creator);
        periphery.claimFees(inst.poolKey, creator);
        vm.prank(creator);
        periphery.transferLaunch(inst.poolKey.toPoolId(), address(0xbeef));
        _receipt(inst.token, seen);
        for (uint256 i; i < seen.length; i++) {
            assertTrue(seen[i], "every extension/periphery/token event covered");
        }
    }

    function test_logo_eventOnly_previewAndAddressUnchanged() public {
        _quote(false, 18);
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(ASK_18_18, REQUESTED_SUPPLY, DECAY_RATE);
        IZeroSeedLaunch.Installation memory preview = periphery.previewInstallation(creator, p);
        uint256 snapshot = vm.snapshotState();
        bytes32 topic = keccak256(
            "LaunchCreated(bytes32,address,address,(address,address,bytes32),bytes32,uint128,(bytes32,bytes32,uint128,address,int32,int32,uint64,uint64,uint64,uint64,bytes32),string)"
        );
        bytes32[] memory emptyWrites;
        for (uint256 i; i < 2; i++) {
            string memory logo = i == 0 ? "" : "https://example.invalid/logo.svg";
            vm.record();
            vm.recordLogs();
            vm.prank(creator);
            IZeroSeedLaunch.Installation memory actual = periphery.create(p, logo);
            assertEq(abi.encode(actual), abi.encode(preview), "logo never changes installation");
            (, bytes32[] memory writes) = vm.accesses(address(launch));
            if (i == 0) emptyWrites = writes;
            else assertEq(abi.encode(writes), abi.encode(emptyWrites), "identical extension storage writes");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bool found;
            IZeroSeedLaunch.LaunchParameters memory emitted =
                abi.decode(abi.encode(p), (IZeroSeedLaunch.LaunchParameters));
            emitted.salt = keccak256(abi.encode(creator, p.salt));
            for (uint256 j; j < logs.length; j++) {
                if (logs[j].emitter != address(launch) || logs[j].topics[0] != topic) continue;
                found = true;
                assertEq(logs[j].topics.length, 4);
                assertEq(logs[j].topics[1], PoolId.unwrap(actual.poolKey.toPoolId()));
                assertEq(logs[j].topics[2], bytes32(uint256(uint160(actual.token))));
                assertEq(logs[j].topics[3], bytes32(uint256(uint160(address(periphery)))));
                assertEq(
                    logs[j].data,
                    abi.encode(actual.poolKey, actual.positionId, actual.liquidity, emitted, logo),
                    "static parameters followed by dynamic logo"
                );
                console2.log("FIXTURE|LaunchCreated|logo", i);
                for (uint256 k; k < logs[j].topics.length; k++) {
                    console2.logBytes32(logs[j].topics[k]);
                }
                console2.logBytes(logs[j].data);
            }
            assertTrue(found, "LaunchCreated topic and complete ABI payload");
            assertEq(ERC20(actual.token).decimals(), 18);
            assertTrue(vm.revertToState(snapshot));
        }
    }

    // A local Core + forwarding router transaction with every touched persistent slot explicitly cold.
    // 2M includes a 100k allowance for transaction intrinsic/calldata overhead, well below a 30M chain budget.
    function _probeAndCool(address router, address token, bytes memory data, uint256 value)
        internal
        returns (uint256 coreSlots)
    {
        uint256 snapshot = vm.snapshotState();
        vm.record();
        (bool ok,) = router.call{value: value}(data);
        assertTrue(ok, "probe route succeeds");
        address[5] memory accounts = [CORE, address(launch), router, token, activeQuote];
        bytes32[][] memory reads = new bytes32[][](accounts.length);
        for (uint256 i; i < accounts.length; i++) {
            (reads[i],) = vm.accesses(accounts[i]);
        }
        assertTrue(vm.revertToState(snapshot));
        for (uint256 i; i < accounts.length; i++) {
            vm.cool(accounts[i]);
            for (uint256 j; j < reads[i].length; j++) {
                vm.coolSlot(accounts[i], reads[i][j]);
            }
        }
        return reads[0].length;
    }

    function _coldRoute(LaunchTestRouter router, IZeroSeedLaunch.Installation memory inst, bool buy)
        internal
        returns (int256 paid, int256 received)
    {
        address specified = buy ? activeQuote : inst.token;
        address calculated = buy ? inst.token : activeQuote;
        int128 amount = buy ? int128(1e35) : int128(uint128(ERC20(inst.token).balanceOf(address(this))));
        bytes memory data = abi.encodeCall(
            LaunchTestRouter.swap, (inst.poolKey, specified, calculated, amount, int128(0), true, uint32(START))
        );
        uint256 value = buy && activeQuote == address(0) ? uint128(amount) : 0;
        uint256 coreSlots = _probeAndCool(address(router), inst.token, data, value);
        uint256 g = gasleft();
        (bool ok, bytes memory result) = address(router).call{value: value, gas: 1_900_000}(data);
        uint256 used = g - gasleft();
        assertTrue(ok, "cold route fits 1.9M execution gas");
        assertLt(used + 100_000, 2_000_000, "including conservative transaction overhead");
        (,, paid, received) = abi.decode(result, (address, address, int256, int256));
        console2.log("TRAVERSAL|buy", buy);
        console2.log("TRAVERSAL|gas", used);
        console2.log("TRAVERSAL|coreDistinctReadSlots", coreSlots);
    }

    function test_widestRange_coldRouter_bothOrders_under2M() public {
        for (uint256 i; i < 2; i++) {
            uint256 snapshot = vm.snapshotState();
            bool tokenIs0 = i == 0;
            _quote(tokenIs0, 18);
            IZeroSeedLaunch.LaunchParameters memory p = _parameters(MIN_TICK, 1e30, 0);
            p.upperTick = MAX_TICK;
            p.initialFee = 0;
            p.finalFee = 0;
            vm.prank(creator);
            IZeroSeedLaunch.Installation memory inst = periphery.create(p, "");
            assertEq(inst.tickSpacing, 693148);
            LaunchTestRouter router = new LaunchTestRouter(ICore(CORE));
            _approveQuote(activeQuote, address(router));
            ERC20(inst.token).approve(address(router), type(uint256).max);
            vm.deal(address(this), 1e36);
            vm.warp(START);
            (int256 paid, int256 received) = _coldRoute(router, inst, true);
            assertGt(paid, 0);
            assertGt(received, 0);
            PoolState state = ICore(CORE).poolState(inst.poolKey.toPoolId());
            assertEq(
                state.sqrtRatio().toFixed(),
                tickToSqrtRatio(tokenIs0 ? inst.upperTick : -inst.upperTick).toFixed(),
                "whole range swept to upper economic bound"
            );
            (paid, received) = _coldRoute(router, inst, false);
            assertGt(paid, 0);
            assertGt(received, 0);
            assertEq(ERC20(inst.token).balanceOf(address(this)), 0, "all purchased tokens sold");
            assertEq(address(launch).balance, 0);
            assertEq(address(periphery).balance, 0);
            assertTrue(vm.revertToState(snapshot));
        }
    }
}
