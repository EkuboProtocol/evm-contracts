// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ScheduledLaunchTest} from "./ScheduledLaunch.t.sol";
import {ScheduledLaunch} from "../../src/extensions/ScheduledLaunch.sol";
import {MintableERC20} from "../../src/MintableERC20.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {MAX_TICK} from "../../src/math/constants.sol";

/// @dev EKU-657: external buys stop at the top of the launch range, so released inventory is always offered.
contract ScheduledLaunchRangeTest is ScheduledLaunchTest {
    using CoreLib for *;

    function _top(bool tokenIs0, int32 upperTick) internal pure returns (SqrtRatio) {
        return tickToSqrtRatio(tokenIs0 ? upperTick : -upperTick);
    }

    function _withinTop(PoolKey memory key, bool tokenIs0, int32 upperTick) internal view returns (bool) {
        SqrtRatio price = core.poolState(key.toPoolId()).sqrtRatio();
        return tokenIs0 ? price <= _top(true, upperTick) : price >= _top(false, upperTick);
    }

    /// At the maximum tick not even one raw unit can be sold back without overflowing quote accounting.
    function testFuzz_unsellableTopRejected(bool tokenIs0) public {
        ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
        config.targetTick = 88_600_000;
        config.upperTick = 88_722_800;
        assertLe(config.upperTick, MAX_TICK);
        vm.expectRevert(ScheduledLaunch.InvalidLaunch.selector);
        actor.create(extension, config);
    }

    /// A high but sellable range still recovers from a start-block push.
    function testFuzz_highRangeKeepsSelling(bool tokenIs0) public {
        ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
        config.targetTick = 86_900_000;
        config.upperTick = 87_000_000;
        PoolKey memory key = actor.create(extension, config);
        MintableERC20(extension.getLaunch(key.toPoolId()).token).approve(address(actor), type(uint256).max);
        vm.warp(START);
        assertEq(_buy(key, 1e18), 0);
        assertTrue(_withinTop(key, tokenIs0, config.upperTick));
        vm.warp(START + 500);
        extension.advance(key);
        assertGt(extension.getLaunch(key.toPoolId()).deployed, 0);
    }

    /// Any sequence of default-limit buys leaves the price at or below the top, and every later
    /// release is offered and can be bought.
    function testFuzz_defaultLimitBuysNeverStallReleases(bool tokenIs0, uint64[3] memory times, uint96[3] memory sizes)
        public
    {
        PoolKey memory key = _create(tokenIs0);
        uint64 t = START;
        for (uint256 i; i < 3; i++) {
            t = uint64(bound(times[i], t, END - 2));
            vm.warp(t);
            _buy(key, uint128(bound(sizes[i], 1, type(uint96).max)));
            assertTrue(_withinTop(key, tokenIs0, 100_000), "price above range top");
        }
        vm.warp(t + 1);
        uint128 deployed = extension.getLaunch(key.toPoolId()).deployed;
        assertGt(_buy(key, 1e18), 0, "release not offered");
        assertGt(extension.getLaunch(key.toPoolId()).deployed, deployed);
    }
}
