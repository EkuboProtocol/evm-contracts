// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {console2} from "forge-std/console2.sol";
import {IZeroSeedLaunch} from "../../src/interfaces/extensions/IZeroSeedLaunch.sol";
import {IZeroSeedLaunchPeriphery} from "../../src/interfaces/IZeroSeedLaunchPeriphery.sol";
import {createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {ZeroSeedLaunchBase, LaunchSwapper} from "./ZeroSeedLaunch.t.sol";

/// @dev Identical harness can run against the pinned baseline: only shared fields and entrypoints are referenced.
contract ZeroSeedLaunchAccessTest is ZeroSeedLaunchBase {
    function _invoke(address target, address actor, bytes memory data) internal returns (uint256 used) {
        vm.prank(actor);
        uint256 start = gasleft();
        (bool ok,) = target.call(data);
        used = start - gasleft();
        assertTrue(ok, "measured call succeeded");
    }

    function _bench(address target, address actor, bytes memory data, address token, string memory label) internal {
        uint256 snapshot = vm.snapshotState();
        vm.record();
        _invoke(target, actor, data);
        address[6] memory accounts = [CORE, address(launch), address(periphery), address(swapper), token, activeQuote];
        bytes32[][] memory slots = new bytes32[][](accounts.length);
        for (uint256 i; i < accounts.length; i++) {
            (slots[i],) = vm.accesses(accounts[i]);
        }
        assertTrue(vm.revertToState(snapshot));
        for (uint256 i; i < accounts.length; i++) {
            vm.cool(accounts[i]);
            for (uint256 j; j < slots[i].length; j++) {
                vm.coolSlot(accounts[i], slots[i][j]);
            }
        }
        uint256 cold = _invoke(target, actor, data);
        assertTrue(vm.revertToState(snapshot));
        for (uint256 i; i < accounts.length; i++) {
            if (accounts[i] != address(0)) assertGt(accounts[i].code.length, 0, "warm account");
            for (uint256 j; j < slots[i].length; j++) {
                vm.warmSlot(accounts[i], slots[i][j]);
            }
        }
        uint256 warm = _invoke(target, actor, data);
        console2.log(string.concat("ACCESS|", label));
        console2.log("cold", cold);
        console2.log("warm", warm);
        console2.log("Core distinct read slots", slots[0].length);
        console2.log("extension distinct read slots", slots[1].length);
        console2.log("periphery distinct read slots", slots[2].length);
    }

    function test_coldWarm_accessPatterns_swapsAndClaims() public {
        for (uint256 i; i < 2; i++) {
            uint256 snapshot = vm.snapshotState();
            (IZeroSeedLaunch.Installation memory inst,) = _create(i == 0, 18, DECAY_RATE);
            vm.warp(START);
            bytes memory data = abi.encodeCall(
                LaunchSwapper.forwardSwap,
                (
                    inst.poolKey,
                    createSwapParameters(SqrtRatio.wrap(0), 1e18, activeQuote == inst.poolKey.token1, 0)
                        .withDefaultSqrtRatioLimit()
                )
            );
            _bench(address(swapper), address(this), data, inst.token, i == 0 ? "buy t0" : "buy native t1");
            data = abi.encodeCall(IZeroSeedLaunchPeriphery.claimFees, (inst.poolKey, creator));
            _bench(address(periphery), creator, data, inst.token, i == 0 ? "claim t0" : "claim native t1");
            assertTrue(vm.revertToState(snapshot));
        }
    }
}
