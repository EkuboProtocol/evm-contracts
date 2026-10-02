// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ScheduledLaunchTest} from "./ScheduledLaunch.t.sol";
import {ScheduledLaunch} from "../../src/extensions/ScheduledLaunch.sol";
import {MintableERC20} from "../../src/MintableERC20.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {TestToken} from "../TestToken.sol";

/// @dev EKU-645 evaluation of PR #371 at 6767d6cc. These pin behavior the launchpad's
/// provenance, analytics and trade preparation depend on. EKU-657 changed the three stall tests
/// to assert that the launch keeps selling; the other seven are unchanged.
contract ScheduledLaunchEvaluationTest is ScheduledLaunchTest {
    using CoreLib for *;

    address constant NAMED_OWNER = address(0xFA11005);
    address constant STRANGER = address(0xBAD);

    function _quote(bool tokenIs0) internal pure returns (address) {
        return tokenIs0 ? HIGH_QUOTE : LOW_QUOTE;
    }

    function _assertAtRangeTop(PoolKey memory key, bool tokenIs0) internal view {
        assertEq(
            SqrtRatio.unwrap(core.poolState(key.toPoolId()).sqrtRatio()),
            SqrtRatio.unwrap(tickToSqrtRatio(tokenIs0 ? int32(100_000) : int32(-100_000)))
        );
    }

    function _token(PoolKey memory key) internal view returns (MintableERC20) {
        return MintableERC20(extension.getLaunch(key.toPoolId()).token);
    }

    /// LaunchCreated.owner is a beneficiary chosen by whoever pays for creation, not a consenting creator.
    function testFuzz_eval_anyPayerCanNameAnyOwner(bool tokenIs0) public {
        ScheduledLaunch.LaunchConfig memory config = _config(_quote(tokenIs0));
        config.owner = NAMED_OWNER;
        vm.prank(STRANGER);
        PoolKey memory key = actor.create(extension, config);
        assertEq(extension.getLaunch(key.toPoolId()).owner, NAMED_OWNER);
        assertEq(vm.getNonce(NAMED_OWNER), 0);
        assertEq(NAMED_OWNER.code.length, 0);
    }

    /// Name and symbol are not identity: identical metadata yields distinct tokens and pools.
    function testFuzz_eval_identicalMetadataYieldsDistinctTokens(bool tokenIs0) public {
        PoolKey memory a = actor.create(extension, _config(_quote(tokenIs0)));
        PoolKey memory b = actor.create(extension, _config(_quote(tokenIs0)));
        assertNotEq(address(_token(a)), address(_token(b)));
        assertNotEq(PoolId.unwrap(a.toPoolId()), PoolId.unwrap(b.toPoolId()));
        assertEq(_token(a).symbol(), _token(b).symbol());
        assertEq(_token(a).name(), _token(b).name());
    }

    /// The fee schedule accepts values just under 100%, leaving an exact-input buyer with dust.
    /// A launch router must bound the fee-inclusive delta, never the raw Core fill.
    function testFuzz_eval_nearTotalFeeLeavesBuyerDust(bool tokenIs0) public {
        ScheduledLaunch.LaunchConfig memory config = _config(_quote(tokenIs0));
        config.initialFee = type(uint64).max;
        config.finalFee = type(uint64).max;
        PoolKey memory key = actor.create(extension, config);
        vm.warp(START + 100);
        uint128 bought = _buy(key, 10_000e18);
        (uint128 fee0, uint128 fee1) = _fees(key);
        uint128 fee = tokenIs0 ? fee0 : fee1;
        assertGt(fee, 1e18);
        assertLt(bought, 1e3);
    }

    /// Exact-input buys pay the creator fee in the launch token, so the creator's claimable
    /// launch-token allocation grows with buy volume even though creation reserved none for them.
    function testFuzz_eval_buyFeesAreCreatorLaunchTokenAllocation(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.warp(START + 100);
        uint128 bought = _buy(key, 10_000e18);
        (uint128 fee0, uint128 fee1) = _fees(key);
        uint128 tokenFee = tokenIs0 ? fee0 : fee1;
        assertEq(tokenIs0 ? fee1 : fee0, 0);
        // 10% declining to 1% over 1000s is 9.1% at 100s, charged on the gross output.
        uint256 bps = uint256(tokenFee) * 10_000 / (uint256(bought) + tokenFee);
        assertApproxEqAbs(bps, 910, 1);
        assertEq(_token(key).balanceOf(address(this)), bought);
        extension.claimFees(key, address(this));
        assertEq(_token(key).balanceOf(address(this)), uint256(bought) + tokenFee);
    }

    /// Supply acquirable by any buyer, however large, is bounded by the linear release schedule.
    function testFuzz_eval_earlyBuyBoundedByRelease(bool tokenIs0, uint64 elapsed) public {
        PoolKey memory key = _create(tokenIs0);
        elapsed = uint64(bound(elapsed, 1, END - START - 1));
        vm.warp(START + elapsed);
        uint128 bought = _buy(key, uint128(type(int128).max));
        (uint128 fee0, uint128 fee1) = _fees(key);
        uint128 releasedNow = extension.released(key.toPoolId());
        assertEq(releasedNow, uint128(uint256(SUPPLY) * elapsed / (END - START)));
        assertLe(uint256(bought) + (tokenIs0 ? fee0 : fee1), releasedNow);
        assertGt(bought, 0);
    }

    /// EKU-657: a default-limit buy in the start-timestamp block still finds an empty pool, but it now stops
    /// at the top of the launch range instead of the maximum price. The next release sells back toward the
    /// target and offers inventory. (Was `emptyPoolPricePushStallsReleases`, which pinned the stall.)
    function testFuzz_eval_emptyPoolPricePushNoLongerStallsReleases(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        uint256 quoteBefore = TestToken(_quote(tokenIs0)).balanceOf(address(this));
        vm.warp(START);
        assertEq(_buy(key, 10_000e18), 0);
        assertEq(TestToken(_quote(tokenIs0)).balanceOf(address(this)), quoteBefore);
        _assertAtRangeTop(key, tokenIs0);

        vm.warp(START + 500);
        assertGt(_buy(key, 10_000e18), 0);
        assertGt(extension.getLaunch(key.toPoolId()).deployed, 0);
        assertEq(extension.released(key.toPoolId()), SUPPLY / 2);
    }

    /// EKU-657: a default-limit buyout exhausts released inventory and stops at the top of the range.
    /// Later releases are sold and bought. (Was `buyoutWithDefaultLimitStallsLaterReleases`.)
    function testFuzz_eval_buyoutWithDefaultLimitNoLongerStallsLaterReleases(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.warp(START + 100);
        assertGt(_buy(key, uint128(type(int128).max)), 0);
        _assertAtRangeTop(key, tokenIs0);
        uint128 deployed = extension.getLaunch(key.toPoolId()).deployed;
        vm.warp(START + 600);
        assertGt(_buy(key, 10_000e18), 0);
        assertGt(extension.getLaunch(key.toPoolId()).deployed, deployed);
    }

    /// EKU-657: the start-block push no longer leaves the supply unsold; the launch sells and migrates.
    /// (Was `stalledLaunchEndsUnsold`.)
    function testFuzz_eval_startBlockPushLaunchStillSellsAndMigrates(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.warp(START);
        _buy(key, 10_000e18);
        vm.warp(END - 1);
        assertGt(_buy(key, 10_000e18), 0);
        _finish(key);
        assertGt(_locked(key), 0);
        (uint128 r0, uint128 r1) = _balances(address(vault), key, PoolId.unwrap(key.toPoolId()));
        assertLt(tokenIs0 ? r0 : r1, SUPPLY);
    }

    /// Ending a launch needs no creator action, and the terminal pool trades through the standard Router.
    function testFuzz_eval_strangerEndsLaunchAndRouterTradesTerminalPool(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.warp(START + 100);
        _buy(key, 10_000e18);
        vm.warp(END);
        vm.prank(STRANGER);
        extension.advance(key);
        assertTrue(extension.getLaunch(key.toPoolId()).complete);
        assertGt(_locked(key), 0);
        vm.expectRevert(ScheduledLaunch.LaunchEnded.selector);
        actor.swap(extension, key, createSwapParameters(SqrtRatio.wrap(0), 1e18, tokenIs0, 0));
        uint256 before = _token(key).balanceOf(address(this));
        PoolBalanceUpdate update =
            router.swap(extension.terminalPool(key), createSwapParameters(SqrtRatio.wrap(0), 1e15, tokenIs0, 0), 1);
        uint128 out = uint128(-(tokenIs0 ? update.delta0() : update.delta1()));
        assertGt(out, 0);
        assertEq(_token(key).balanceOf(address(this)) - before, out);
    }

    /// The creator can redirect fee income but holds no path to locked principal or to minting.
    function testFuzz_eval_creatorPowersStopAtFees(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.warp(START + 100);
        _buy(key, 10_000e18);
        _finish(key);
        uint128 locked = _locked(key);
        vm.startPrank(STRANGER);
        vm.expectRevert(ScheduledLaunch.OwnerOnly.selector);
        extension.claimFees(key, STRANGER);
        vm.expectRevert();
        vault.claimFees(key.toPoolId(), STRANGER);
        vm.stopPrank();
        extension.claimFees(key, address(this));
        vault.claimFees(key.toPoolId(), address(this));
        assertEq(_locked(key), locked);
        assertEq(_token(key).owner(), address(0));
        assertEq(_token(key).totalSupply(), SUPPLY);
    }
}
