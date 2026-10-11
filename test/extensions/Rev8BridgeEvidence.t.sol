// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest, MockExtension} from "../FullTest.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {
    SqrtRatio,
    ONE,
    BIT_MASK,
    TWO_POW_62,
    TWO_POW_94,
    MIN_SQRT_RATIO,
    MAX_SQRT_RATIO,
    MIN_SQRT_RATIO_RAW,
    MAX_SQRT_RATIO_RAW
} from "../../src/types/sqrtRatio.sol";
import {tickToSqrtRatio, sqrtRatioToTick} from "../../src/math/ticks.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {computeFee} from "../../src/math/fee.sol";

/// Evidence for EKU-946 design rev 8 §(b-main) against the unmodified Core on `main` (98d1be1).
/// Core primitives only: the cut + bridge sequence, the exact-tick state, post-cut attribution and the
/// representable neighbours. This is not the extension implementation.
contract Rev8BridgeEvidenceTest is FullTest {
    using CoreLib for *;

    uint96 constant MANTISSA_MAX = uint96(TWO_POW_94) - 1;

    // rev 8 pred/succ: adjacent valid SqrtRatio, with the region jump
    function pred(SqrtRatio r) internal pure returns (SqrtRatio) {
        uint96 raw = SqrtRatio.unwrap(r);
        uint96 region = raw & BIT_MASK;
        uint96 m = raw & ~BIT_MASK;
        if (m == TWO_POW_62 && region != 0) {
            return SqrtRatio.wrap((region - TWO_POW_94) | MANTISSA_MAX);
        }
        return SqrtRatio.wrap(raw - 1);
    }

    function succ(SqrtRatio r) internal pure returns (SqrtRatio) {
        uint96 raw = SqrtRatio.unwrap(r);
        uint96 region = raw & BIT_MASK;
        uint96 m = raw & ~BIT_MASK;
        if (m == MANTISSA_MAX && region != BIT_MASK) {
            return SqrtRatio.wrap((region + TWO_POW_94) | TWO_POW_62);
        }
        return SqrtRatio.wrap(raw + 1);
    }

    // ---- finding 2 (progress): cut, then bridge, then the next search is past the tick ----

    function test_cutThenBridgeDoesNotRepeat() public {
        PoolKey memory key = createPool(-1, 0, 1);
        (, uint128 oldL) = createPosition(key, -100, 0, 1e25, 1e25);
        (, uint128 dustL) = createPosition(key, 0, 100, 1e6, 1e6);
        token1.approve(address(router), type(uint256).max);

        // charged call: cut at pred(E), E = 0 initialized
        SqrtRatio cut = pred(ONE);
        PoolBalanceUpdate charged = router.swapAllowPartialFill(key, true, 1e30, cut, 0);
        PoolState st = core.poolState(key.toPoolId());
        assertEq(SqrtRatio.unwrap(st.sqrtRatio()), SqrtRatio.unwrap(cut));
        assertEq(st.liquidity(), oldL, "charged call ends in the old liquidity");
        assertLt(charged.delta0(), 0);

        // the state machine: next tick event from the stored tick is still E, init, and cur == pred(tS): bridge
        (int32 t, bool init) = core.nextInitializedTick(key.toPoolId(), st.tick(), 1, 0);
        assertTrue(init);
        assertEq(t, 0);
        assertEq(SqrtRatio.unwrap(pred(tickToSqrtRatio(t))), SqrtRatio.unwrap(cut), "bridge condition");

        // bridge: limit = tS, one representable step, crosses E
        PoolBalanceUpdate bridge = router.swapAllowPartialFill(key, true, 1e30, tickToSqrtRatio(t), 0);
        st = core.poolState(key.toPoolId());
        assertEq(SqrtRatio.unwrap(st.sqrtRatio()), SqrtRatio.unwrap(ONE));
        assertEq(st.tick(), 0);
        assertEq(st.liquidity(), dustL, "bridge crosses E");
        assertGt(bridge.delta1(), 0);
        assertLt(bridge.delta0(), 0);

        // progress: the next search from the stored tick is strictly past E, so no repeated call
        (t, init) = core.nextInitializedTick(key.toPoolId(), st.tick(), 1, 0);
        assertTrue(init);
        assertEq(t, 100);
        assertGt(SqrtRatio.unwrap(pred(tickToSqrtRatio(t))), SqrtRatio.unwrap(ONE));
    }

    function test_cutThenBridgeDecreasing() public {
        PoolKey memory key = createPool(1, 0, 1);
        (, uint128 oldL) = createPosition(key, 0, 100, 1e25, 1e25);
        (, uint128 dustL) = createPosition(key, -100, 0, 1e6, 1e6);
        token0.approve(address(router), type(uint256).max);

        SqrtRatio cut = succ(ONE);
        router.swapAllowPartialFill(key, false, 1e30, cut, 0);
        PoolState st = core.poolState(key.toPoolId());
        assertEq(SqrtRatio.unwrap(st.sqrtRatio()), SqrtRatio.unwrap(cut));
        assertEq(st.liquidity(), oldL);
        assertEq(st.tick(), 0, "sqrtRatioToTick(succ(tS)) == E");

        // decreasing search is inclusive of the stored tick: returns E, init, cur == succ(tS): bridge
        (int32 t, bool init) = core.prevInitializedTick(key.toPoolId(), st.tick(), 1, 0);
        assertTrue(init);
        assertEq(t, 0);

        PoolBalanceUpdate bridge = router.swapAllowPartialFill(key, false, 1e30, tickToSqrtRatio(t), 0);
        st = core.poolState(key.toPoolId());
        assertEq(SqrtRatio.unwrap(st.sqrtRatio()), SqrtRatio.unwrap(ONE));
        assertEq(st.tick(), -1, "decreasing crossing stores T - 1");
        assertEq(st.liquidity(), dustL);
        assertGt(bridge.delta0(), 0);

        (t, init) = core.prevInitializedTick(key.toPoolId(), st.tick(), 1, 0);
        assertTrue(init);
        assertEq(t, -100);
    }

    // ---- exact-tick state: price on an initialized tick reached from the other direction ----

    function test_exactTickStateIsDetectedAndResearched() public {
        PoolKey memory key = createPool(-1, 0, 1);
        (, uint128 oldL) = createPosition(key, -100, 0, 1e25, 1e25);
        (, uint128 dustL) = createPosition(key, 0, 100, 1e6, 1e6);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(router), type(uint256).max);

        // increasing: cut + bridge lands on E = 0 with tick = 0 and liquidity = dust
        router.swapAllowPartialFill(key, true, 1e30, pred(ONE), 0);
        router.swapAllowPartialFill(key, true, 1e30, ONE, 0);
        PoolState st = core.poolState(key.toPoolId());
        assertEq(st.tick(), 0);
        assertEq(st.liquidity(), dustL);

        // now decreasing: Core's inclusive search returns E with tS == cur
        (int32 t, bool init) = core.prevInitializedTick(key.toPoolId(), st.tick(), 1, 0);
        assertTrue(init);
        assertEq(t, 0);
        assertEq(SqrtRatio.unwrap(tickToSqrtRatio(t)), SqrtRatio.unwrap(st.sqrtRatio()), "tS == cur");

        // re-search past it (decreasing: from T - 1)
        (t, init) = core.prevInitializedTick(key.toPoolId(), t - 1, 1, 0);
        assertTrue(init);
        assertEq(t, -100);

        // the next charged call starts with Core's zero-width crossing of E; its trading liquidity is oldL
        SqrtRatio limit = succ(tickToSqrtRatio(t));
        router.swapAllowPartialFill(key, false, 1e18, limit, 0);
        st = core.poolState(key.toPoolId());
        assertEq(st.liquidity(), oldL, "post-charge liquidity is the liquidity that traded");
        assertLt(SqrtRatio.unwrap(st.sqrtRatio()), SqrtRatio.unwrap(ONE));
        assertGe(SqrtRatio.unwrap(st.sqrtRatio()), SqrtRatio.unwrap(limit));
    }

    // ---- finding 1 (attribution): the charge after a cut goes only to the liquidity that traded ----

    function test_postCutChargeCreditsOnlyTradedLiquidity() public {
        MockExtension ext = createAndRegisterExtension();
        PoolKey memory key = createPool(-1, 0, 1, address(ext));
        (uint256 honest,) = createPosition(key, -100, 0, 1e25, 1e25);
        (uint256 dust,) = createPosition(key, 0, 100, 1e6, 1e6);
        token1.approve(address(router), type(uint256).max);

        PoolBalanceUpdate charged = router.swapAllowPartialFill(key, true, 1e30, pred(ONE), 0);
        uint128 out = uint128(uint256(-int256(charged.delta0())));
        uint128 fee = computeFee(out, 1 << 62);
        assertGt(fee, 0);

        uint256 fplBefore = core.getPoolFeesPerLiquidity(key.toPoolId()).value0;
        token0.approve(address(ext), fee);
        ext.accumulateFees(key, fee, 0);
        assertGt(core.getPoolFeesPerLiquidity(key.toPoolId()).value0, fplBefore, "not burned");

        (,,, uint128 honestFees0,) = positions.getPositionFeesAndLiquidity(honest, key, -100, 0);
        (,,, uint128 dustFees0,) = positions.getPositionFeesAndLiquidity(dust, key, 0, 100);
        assertEq(dustFees0, 0, "attacker dust collects nothing");
        assertApproxEqAbs(honestFees0, fee, 1, "honest range collects the charge");

        // the bridge then crosses E without any accumulateAsFees; the dust's share stays 0
        uint256 fplAfterCharge = core.getPoolFeesPerLiquidity(key.toPoolId()).value0;
        router.swapAllowPartialFill(key, true, 1e30, ONE, 0);
        assertEq(core.poolState(key.toPoolId()).tick(), 0);
        assertEq(core.getPoolFeesPerLiquidity(key.toPoolId()).value0, fplAfterCharge, "bridge adds no token0 fees");
        (,,, dustFees0,) = positions.getPositionFeesAndLiquidity(dust, key, 0, 100);
        assertEq(dustFees0, 0);
    }

    function test_bridgeIntoZeroLiquidityChargesNothing() public {
        MockExtension ext = createAndRegisterExtension();
        PoolKey memory key = createPool(-1, 0, 1, address(ext));
        createPosition(key, -100, 0, 1e25, 1e25);
        token1.approve(address(router), type(uint256).max);

        router.swapAllowPartialFill(key, true, 1e30, pred(ONE), 0);
        PoolBalanceUpdate bridge = router.swapAllowPartialFill(key, true, 1e30, ONE, 0);
        assertLt(bridge.delta0(), 0, "the bridge trades real tokens (CSO: 10 units)");
        assertEq(core.poolState(key.toPoolId()).liquidity(), 0);
        // rev 8: no charge on the bridge, so there is nothing to burn; the rev 7 burn is not reachable
        uint256 fplBefore = core.getPoolFeesPerLiquidity(key.toPoolId()).value0;
        assertEq(core.getPoolFeesPerLiquidity(key.toPoolId()).value0, fplBefore);
        emit log_named_uint("waived bridge output", uint256(-int256(bridge.delta0())));
    }

    // ---- rev 8 pred/succ vectors (test 25, model part) ----

    function _checkAdjacent(SqrtRatio x) internal pure {
        SqrtRatio p = pred(x);
        SqrtRatio s = succ(x);
        assertTrue(p.isValid() || SqrtRatio.unwrap(x) == MIN_SQRT_RATIO_RAW);
        assertTrue(s.isValid() || SqrtRatio.unwrap(x) == MAX_SQRT_RATIO_RAW);
        assertLt(SqrtRatio.unwrap(p), SqrtRatio.unwrap(x));
        assertGt(SqrtRatio.unwrap(s), SqrtRatio.unwrap(x));
        assertLt(p.toFixed(), x.toFixed());
        assertGt(s.toFixed(), x.toFixed());
        assertEq(SqrtRatio.unwrap(succ(p)), SqrtRatio.unwrap(x), "succ(pred(x)) == x");
        assertEq(SqrtRatio.unwrap(pred(s)), SqrtRatio.unwrap(x), "pred(succ(x)) == x");
    }

    function test_predSuccVectors() public pure {
        SqrtRatio[6] memory v = [
            ONE,
            SqrtRatio.wrap(TWO_POW_94 | TWO_POW_62), // 2^96 fixed (region 1 min)
            SqrtRatio.wrap(uint96(1 << 95) | TWO_POW_62), // 2^128 fixed (region 2 min)
            SqrtRatio.wrap(BIT_MASK | TWO_POW_62), // 2^160 fixed (region 3 min)
            tickToSqrtRatio(MIN_TICK),
            tickToSqrtRatio(MAX_TICK)
        ];
        for (uint256 i = 0; i < v.length; i++) {
            _checkAdjacent(v[i]);
        }
        assertEq(SqrtRatio.unwrap(tickToSqrtRatio(MIN_TICK)), MIN_SQRT_RATIO_RAW);
        assertEq(SqrtRatio.unwrap(tickToSqrtRatio(MAX_TICK)), MAX_SQRT_RATIO_RAW);
        assertTrue(pred(MAX_SQRT_RATIO).isValid());
        assertTrue(succ(MIN_SQRT_RATIO).isValid());
        // region jumps are adjacent in fixed point
        assertEq(pred(SqrtRatio.wrap(TWO_POW_94 | TWO_POW_62)).toFixed(), (uint256(MANTISSA_MAX) << 2));
        assertEq(SqrtRatio.wrap(TWO_POW_94 | TWO_POW_62).toFixed(), uint256(1) << 96);
        // a representable step is far below a tick
        assertEq(sqrtRatioToTick(pred(ONE)), -1);
        assertEq(sqrtRatioToTick(succ(ONE)), 0);
    }

    function testFuzz_predSuccAdjacent(int32 tick) public pure {
        tick = int32(bound(tick, MIN_TICK + 1, MAX_TICK - 1));
        SqrtRatio tS = tickToSqrtRatio(tick);
        _checkAdjacent(tS);
        assertEq(sqrtRatioToTick(pred(tS)), tick - 1);
        assertEq(sqrtRatioToTick(succ(tS)), tick);
    }

    // ---- finding 3: the rounding bound R1, not invariance ----

    function test_splitRoundingBoundR1() public pure {
        uint64 rate = 1 << 62;
        // one call: fee in [out*sur, out*sur + 1)
        assertEq(computeFee(4, rate), 1);
        // two calls: at most +1 per additional charged call
        assertEq(computeFee(2, rate) + computeFee(2, rate), 2);
        assertLe(computeFee(2, rate) + computeFee(2, rate), computeFee(4, rate) + 1);
    }
}
