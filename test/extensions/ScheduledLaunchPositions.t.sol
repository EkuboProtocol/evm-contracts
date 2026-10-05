// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

// Third-party positions on launch pools (EKU-723). The EKU-664 review showed that a quote-only position
// filling Core's per-tick liquidity cap at the launch's target tick left no room for released inventory:
// the launch added no liquidity and buyers received nothing. Launch pools now reject every position
// except the extension's own.

import {ScheduledLaunchTest} from "./ScheduledLaunch.t.sol";
import {TestToken} from "../TestToken.sol";
import {ScheduledLaunch} from "../../src/extensions/ScheduledLaunch.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {createPositionId} from "../../src/types/positionId.sol";
import {MintableERC20} from "../../src/MintableERC20.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";

contract TickLP is BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function deposit(PoolKey memory key, int32 lower, int32 upper, uint128 liquidity) external {
        lock(abi.encode(key, lower, upper, liquidity, msg.sender));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory key, int32 lower, int32 upper, uint128 liquidity, address payer) =
            abi.decode(data, (PoolKey, int32, int32, uint128, address));
        PoolBalanceUpdate update = ICore(payable(address(ACCOUNTANT)))
            .updatePosition(key, createPositionId(bytes24(0), lower, upper), int128(liquidity));
        if (update.delta0() > 0) ACCOUNTANT.payFrom(payer, key.token0, uint128(update.delta0()));
        if (update.delta1() > 0) ACCOUNTANT.payFrom(payer, key.token1, uint128(update.delta1()));
        return "";
    }
}

contract ScheduledLaunchPositionsTest is ScheduledLaunchTest {
    using CoreLib for *;

    TickLP lp;

    function setUp() public override {
        super.setUp();
        lp = new TickLP(core);
        TestToken(LOW_QUOTE).approve(address(lp), type(uint256).max);
        TestToken(HIGH_QUOTE).approve(address(lp), type(uint256).max);
    }

    function _launchAt(int32 target) internal returns (PoolKey memory key) {
        ScheduledLaunch.LaunchConfig memory config = _config(HIGH_QUOTE); // launch token is token0
        config.targetTick = target;
        config.upperTick = target + 100_000;
        key = actor.create(extension, config);
        MintableERC20(extension.getLaunch(key.toPoolId()).token).approve(address(actor), type(uint256).max);
    }

    function _launchLiquidity(PoolKey memory key) internal view returns (uint128) {
        return core.poolPositions(key.toPoolId(), address(extension), extension.getLaunch(key.toPoolId()).positionId)
        .liquidity;
    }

    /// EKU-664 PoC inverted: the saturating deposit reverts and the launch deploys and sells as usual.
    function _assertSaturationRejected(int32 target) internal {
        PoolKey memory key = _launchAt(target);
        uint128 maxPerTick = key.config.concentratedMaxLiquidityPerTick();
        vm.expectRevert(ScheduledLaunch.PositionsThroughExtensionOnly.selector);
        lp.deposit(key, target - 100, target, maxPerTick);
        vm.warp(START + 500);
        extension.advance(key);
        assertGt(_launchLiquidity(key), 0, "launch liquidity");
        assertGt(_buy(key, 1e18), 0, "tokens bought");
    }

    function test_reviewTargetTickSaturationRejected() public {
        _assertSaturationRejected(-400_000);
    }

    function test_reviewTargetTickSaturationLowPriceRejected() public {
        _assertSaturationRejected(-20_000_000);
    }

    function test_reviewTargetTickSaturationVeryLowPriceRejected() public {
        _assertSaturationRejected(-40_000_000);
    }

    /// Any range, before, during and after the launch, in both token orders.
    function testFuzz_thirdPartyPositionsRejected(bool tokenIs0, int32 lower, int32 width, uint8 phase) public {
        PoolKey memory key = _create(tokenIs0);
        lower = int32(bound(lower, MIN_TICK / 100, MAX_TICK / 100 - 1)) * 100;
        int32 upper = int32(bound(int256(lower) + int256(bound(width, 1, 10_000)) * 100, lower + 100, MAX_TICK));
        upper -= upper % 100;
        if (phase % 3 == 1) vm.warp(START + 100);
        if (phase % 3 == 2) _finish(key);
        vm.expectRevert(ScheduledLaunch.PositionsThroughExtensionOnly.selector);
        lp.deposit(key, lower, upper, 1);
    }

    function test_fullRangePositionRejected() public {
        PoolKey memory key = _create(true);
        vm.expectRevert(ScheduledLaunch.PositionsThroughExtensionOnly.selector);
        lp.deposit(key, -88_722_800, 88_722_800, 1e18);
    }
}
