// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Vm} from "forge-std/Vm.sol";
import {FullTest} from "../FullTest.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {Router} from "../../src/Router.sol";
import {MEVCapture, mevCaptureCallPoints} from "../../src/extensions/MEVCapture.sol";
import {MEVCaptureV21, mevCaptureV21CallPoints} from "../../src/extensions/MEVCaptureV21.sol";
import {V21Actor} from "./MEVCaptureV21Helpers.sol";
import {PositionId, createPositionId} from "../../src/types/positionId.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {SqrtRatio, MAX_SQRT_RATIO} from "../../src/types/sqrtRatio.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";

/// @notice Test 28: gas rows of v2.1 against v1 on `main`, identical layouts and swap parameters, cold contracts.
///   Every v2.1 row logs the Core swap-call and FeesAccumulated counts; the designed R / I / U of each layout is
///   stated in the row's comment and in the gas table of the PR.
contract MEVCaptureV21GasTest is FullTest {
    using CoreLib for *;

    bytes32 internal constant FEES_ACCUMULATED_TOPIC = keccak256("FeesAccumulated(bytes32,uint128,uint128)");

    uint64 internal constant FEE_30BP = 55340232221128654;
    uint32 internal constant SP = 1000;
    int32 internal constant S = 1000;
    int128 internal constant L = int128(1) << 80;

    MEVCapture internal v1;
    MEVCaptureV21 internal v21;
    Router internal v1Router;
    Router internal v21Router;
    V21Actor internal lp;
    uint192 internal salt;

    function setUp() public override {
        FullTest.setUp();
        address v1Addr = address(uint160(mevCaptureCallPoints().toUint8()) << 152);
        deployCodeTo("MEVCapture.sol", abi.encode(core), v1Addr);
        v1 = MEVCapture(v1Addr);
        v1Router = new Router(core, v1Addr, address(0));
        v21 = _deployV21(120, 4, 4, 16, uint64(1) << 63, 2500, 3, 0);
        v21Router = new Router(core, address(v21), address(0));
        token0.approve(address(v1Router), type(uint256).max);
        token1.approve(address(v1Router), type(uint256).max);
        token0.approve(address(v21Router), type(uint256).max);
        token1.approve(address(v21Router), type(uint256).max);
        lp = new V21Actor(core, address(this));
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
    }

    function _deployV21(
        uint32 halfLife,
        uint8 slopeK,
        uint8 segmentExp,
        uint8 jLin,
        uint64 maxFee,
        uint32 clampTicks,
        uint8 mGate,
        uint160 index
    ) internal returns (MEVCaptureV21 ext) {
        address a = address((uint160(mevCaptureV21CallPoints().toUint8()) << 152) + 0x2000 + index);
        deployCodeTo(
            "MEVCaptureV21.sol:MEVCaptureV21",
            abi.encode(core, halfLife, slopeK, segmentExp, jLin, maxFee, clampTicks, mGate),
            a
        );
        ext = MEVCaptureV21(a);
    }

    function coolAllContracts() internal override {
        FullTest.coolAllContracts();
        vm.cool(address(v1));
        vm.cool(address(v21));
        vm.cool(address(v1Router));
        vm.cool(address(v21Router));
        vm.cool(address(lp));
    }

    struct Layout {
        uint64 fee;
        uint32 spacing;
        int32 tick;
        int32[] los;
        int32[] his;
        int128[] liqs;
    }

    function _pools(Layout memory l, address ext21) internal returns (PoolKey memory p1, PoolKey memory p21) {
        p1 = createPool(
            address(token0), address(token1), l.tick, createConcentratedPoolConfig(l.fee, l.spacing, address(v1))
        );
        p21 =
            createPool(address(token0), address(token1), l.tick, createConcentratedPoolConfig(l.fee, l.spacing, ext21));
        for (uint256 i; i < l.los.length; i++) {
            _mint(p1, l.los[i], l.his[i], l.liqs[i]);
            _mint(p21, l.los[i], l.his[i], l.liqs[i]);
        }
    }

    function _mint(PoolKey memory pk, int32 lo, int32 hi, int128 liq) internal {
        V21Actor.Action[] memory acts = new V21Actor.Action[](1);
        PositionId pid = createPositionId(bytes24(++salt), lo, hi);
        acts[0] = V21Actor.Action({kind: 0, poolKey: pk, a: PositionId.unwrap(pid), b: liq, target: address(0)});
        lp.run(acts);
    }

    function _layout(uint64 fee, uint32 spacing, int32 tick, uint256 n) internal pure returns (Layout memory l) {
        l.fee = fee;
        l.spacing = spacing;
        l.tick = tick;
        l.los = new int32[](n);
        l.his = new int32[](n);
        l.liqs = new int128[](n);
    }

    function _row(string memory name, PoolKey memory p1, PoolKey memory p21, Router r21, SwapParameters params)
        internal
    {
        coolAllContracts();
        v1Router.swapAllowPartialFill(p1, params, address(this));
        vm.snapshotGasLastCall(string.concat("v1/", name));
        coolAllContracts();
        vm.recordLogs();
        r21.swapAllowPartialFill(p21, params, address(this));
        vm.snapshotGasLastCall(string.concat("v21/", name));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 calls;
        uint256 fees;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(core)) continue;
            if (logs[i].topics.length == 0 && logs[i].data.length == 116) calls++;
            else if (logs[i].topics.length != 0 && logs[i].topics[0] == FEES_ACCUMULATED_TOPIC) fees++;
        }
        emit log_named_string("row", name);
        emit log_named_uint("  core swap calls", calls);
        emit log_named_uint("  FeesAccumulated", fees);
    }

    function _in1(int128 amount, SqrtRatio limit) internal pure returns (SwapParameters) {
        return createSwapParameters({_sqrtRatioLimit: limit, _amount: amount, _isToken1: true, _skipAhead: 0});
    }

    function _in1(int128 amount, SqrtRatio limit, uint256 skipAhead) internal pure returns (SwapParameters) {
        return createSwapParameters({_sqrtRatioLimit: limit, _amount: amount, _isToken1: true, _skipAhead: skipAhead});
    }

    // ---- rows: W = 16 S (segExp 4), 4 segments traversed, 0 / 1 / 4 / 16 initialized ticks per segment ----

    function _ticksPerSegment(uint256 perSegment) internal returns (PoolKey memory p1, PoolKey memory p21) {
        uint256 n = 1 + 4 * perSegment;
        Layout memory l = _layout(FEE_30BP, SP, 0, n);
        (l.los[0], l.his[0], l.liqs[0]) = (-200 * S, 200 * S, L);
        // narrow one-spacing positions spread evenly inside each of the 4 segments [16kS, 16(k+1)S)
        for (uint256 k; k < 4; k++) {
            for (uint256 j; j < perSegment; j++) {
                int32 lo = int32(int256(16 * k)) * S + int32(int256(j * 16 / perSegment)) * S;
                uint256 idx = 1 + k * perSegment + j;
                (l.los[idx], l.his[idx], l.liqs[idx]) = (lo, lo + S, L / 1024);
            }
        }
        (p1, p21) = _pools(l, address(v21));
    }

    /// forge-config: default.isolate = true
    function test_gas_segments4_ticks0() public {
        (PoolKey memory p1, PoolKey memory p21) = _ticksPerSegment(0);
        // R = 4, I = 0, U = 0
        _row("segments4_ticks0_exact_in", p1, p21, v21Router, _in1(type(int128).max >> 8, tickToSqrtRatio(64 * S)));
    }

    /// forge-config: default.isolate = true
    function test_gas_segments4_ticks1() public {
        (PoolKey memory p1, PoolKey memory p21) = _ticksPerSegment(1);
        // R = 4, I = 8 (each narrow position has two ticks), U = 0
        _row("segments4_ticks1_exact_in", p1, p21, v21Router, _in1(type(int128).max >> 8, tickToSqrtRatio(64 * S)));
    }

    /// forge-config: default.isolate = true
    function test_gas_segments4_ticks4() public {
        (PoolKey memory p1, PoolKey memory p21) = _ticksPerSegment(4);
        // R = 4, I = 32, U = 0
        _row("segments4_ticks4_exact_in", p1, p21, v21Router, _in1(type(int128).max >> 8, tickToSqrtRatio(64 * S)));
    }

    /// forge-config: default.isolate = true
    function test_gas_segments4_ticks16() public {
        (PoolKey memory p1, PoolKey memory p21) = _ticksPerSegment(16);
        // dense adversarial layout: every spacing initialized across 64 ticks; R = 4, I = 64 (adjacent positions
        // share ticks), U = 0
        _row(
            "segments4_ticks16_dense_exact_in", p1, p21, v21Router, _in1(type(int128).max >> 8, tickToSqrtRatio(64 * S))
        );
    }

    /// forge-config: default.isolate = true
    function test_gas_segments4_ticks0_exact_out() public {
        (PoolKey memory p1, PoolKey memory p21) = _ticksPerSegment(0);
        SwapParameters p = createSwapParameters({
            _sqrtRatioLimit: tickToSqrtRatio(64 * S), _amount: -(type(int128).max >> 8), _isToken1: false, _skipAhead: 0
        });
        _row("segments4_ticks0_exact_out", p1, p21, v21Router, p);
    }

    /// forge-config: default.isolate = true
    function test_gas_segments4_ticks4_exact_out() public {
        (PoolKey memory p1, PoolKey memory p21) = _ticksPerSegment(4);
        SwapParameters p = createSwapParameters({
            _sqrtRatioLimit: tickToSqrtRatio(64 * S), _amount: -(type(int128).max >> 8), _isToken1: false, _skipAhead: 0
        });
        _row("segments4_ticks4_exact_out", p1, p21, v21Router, p);
    }

    // ---- one segment, no ticks: the minimal away swap; and toward-only ----

    /// forge-config: default.isolate = true
    function test_gas_single_segment() public {
        (PoolKey memory p1, PoolKey memory p21) = _ticksPerSegment(0);
        // R = 0 (ends inside segment 1), I = 0, U = 0: one charged call
        _row("single_segment_exact_in", p1, p21, v21Router, _in1(type(int128).max >> 8, tickToSqrtRatio(8 * S)));
    }

    /// forge-config: default.isolate = true
    function test_gas_toward_only() public {
        (PoolKey memory p1, PoolKey memory p21) = _ticksPerSegment(0);
        // move away first (not measured), then one uncut toward call
        v1Router.swapAllowPartialFill(p1, _in1(type(int128).max >> 8, tickToSqrtRatio(40 * S)), address(this));
        v21Router.swapAllowPartialFill(p21, _in1(type(int128).max >> 8, tickToSqrtRatio(40 * S)), address(this));
        SwapParameters p = createSwapParameters({
            _sqrtRatioLimit: tickToSqrtRatio(2 * S), _amount: type(int128).max >> 8, _isToken1: false, _skipAhead: 0
        });
        _row("toward_only_exact_in", p1, p21, v21Router, p);
    }

    // ---- empty bitmap words beyond the liquidity, skipAhead 0 and 3 ----

    function _emptyWords(uint256 words, uint256 skipAhead) internal {
        Layout memory l = _layout(FEE_30BP, SP, 0, 1);
        (l.los[0], l.his[0], l.liqs[0]) = (-S, S, L);
        (PoolKey memory p1, PoolKey memory p21) = _pools(l, address(v21));
        // one word is 256 spacings; the limit lies `words` words past the end of the liquidity
        int32 limitTick = S + int32(int256(words)) * 256 * S;
        _row(
            string.concat("empty_words", vm.toString(words), "_skip", vm.toString(skipAhead)),
            p1,
            p21,
            v21Router,
            _in1(type(int128).max >> 8, tickToSqrtRatio(limitTick), skipAhead)
        );
    }

    /// forge-config: default.isolate = true
    function test_gas_empty_words1_skip0() public {
        _emptyWords(1, 0);
    }

    /// forge-config: default.isolate = true
    function test_gas_empty_words4_skip0() public {
        _emptyWords(4, 0);
    }

    /// forge-config: default.isolate = true
    function test_gas_empty_words1_skip3() public {
        _emptyWords(1, 3);
    }

    /// forge-config: default.isolate = true
    function test_gas_empty_words4_skip3() public {
        _emptyWords(4, 3);
    }

    // ---- rate-cap tail: tick cuts and bridges continue after the surcharge reaches the cap ----

    /// forge-config: default.isolate = true
    function test_gas_cap_tail() public {
        Layout memory l = _layout(FEE_30BP, SP, 0, 3);
        (l.los[0], l.his[0], l.liqs[0]) = (-5000 * S, 5000 * S, L);
        (l.los[1], l.his[1], l.liqs[1]) = (3000 * S, 3001 * S, L / 1024);
        (l.los[2], l.his[2], l.liqs[2]) = (4000 * S, 4001 * S, L / 1024);
        (PoolKey memory p1, PoolKey memory p21) = _pools(l, address(v21));
        // the cap (50% - 0.3%) is reached around segment 42; 3000S..4001S lie beyond it: I = 4 after the cap
        _row("cap_tail_exact_in", p1, p21, v21Router, _in1(type(int128).max >> 8, tickToSqrtRatio(4500 * S)));
    }

    // ---- J_LIN = 64 with the doublings that fit, spacing 1 ----

    function _jlin64(uint256 skipAhead) internal {
        MEVCaptureV21 ext = _deployV21(120, 4, 0, 64, uint64(1) << 63, 2500, 3, 1);
        Router r = new Router(core, address(ext), address(0));
        token1.approve(address(r), type(uint256).max);
        Layout memory l = _layout(FEE_30BP, 1, 0, 1);
        (l.los[0], l.his[0], l.liqs[0]) = (-70000, 70000, int128(1) << 100);
        (PoolKey memory p1, PoolKey memory p21) = _pools(l, address(ext));
        // W = 1 tick: 64 linear boundaries then doublings 2, 4, ..., 2^14 reach 65536 - 2 + 64; R = 78, I = 0,
        // U = one uninitialized word endpoint per 256 ticks (256 with skipAhead 0)
        _row(
            string.concat("jlin64_doublings_skip", vm.toString(skipAhead)),
            p1,
            p21,
            r,
            _in1(type(int128).max >> 8, tickToSqrtRatio(65000), skipAhead)
        );
    }

    /// forge-config: default.isolate = true
    function test_gas_jlin64_skip0() public {
        _jlin64(0);
    }

    /// forge-config: default.isolate = true
    function test_gas_jlin64_skip32() public {
        _jlin64(32);
    }

    // ---- fees at the edges of the 0.64 range ----

    function _feeEdge(uint64 fee, string memory name) internal {
        Layout memory l = _layout(fee, SP, 0, 1);
        (l.los[0], l.his[0], l.liqs[0]) = (-200 * S, 200 * S, L);
        (PoolKey memory p1, PoolKey memory p21) = _pools(l, address(v21));
        _row(name, p1, p21, v21Router, _in1(type(int128).max >> 8, tickToSqrtRatio(64 * S)));
    }

    /// forge-config: default.isolate = true
    function test_gas_fee_1ulp() public {
        _feeEdge(1, "fee_1ulp_segments4");
    }

    /// forge-config: default.isolate = true
    function test_gas_fee_near_max() public {
        // cap = 1 ulp from the first segment on: no rate cuts, one charged call to the limit
        _feeEdge((uint64(1) << 63) - 1, "fee_near_max_segments4");
    }
}
