// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {MEVCaptureV21Base} from "./MEVCaptureV21Base.sol";
import {V21Ref, V21Actor} from "./MEVCaptureV21Helpers.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";

/// @notice End-to-end swap vectors for quoters/indexers: pool layout, extension state, swap parameters, the exact Core
///   call sequence (limit, minFee, amount) and the result. Every swap is checked against the reference model (see
///   MEVCaptureV21Base). The JSON is rebuilt on every run and must equal test/data/mevcapture-v21/swaps.json.
///   Regenerate: FOUNDRY_PROFILE=v21vectors WRITE_V21_VECTORS=true forge test --offline --mc MEVCaptureV21SwapVectorsTest
contract MEVCaptureV21SwapVectorsTest is MEVCaptureV21Base {
    using CoreLib for *;

    int32 internal constant S = 4096;
    int128 internal constant L66 = int128(1) << 66;
    int128 internal constant BIG = type(int128).max >> 8;

    string internal out;
    string internal scenario;
    string internal positionsJson;
    uint256 internal swapCount;
    uint256 internal scenarioCount;

    function _q(string memory s) internal pure returns (string memory) {
        return string.concat('"', s, '"');
    }

    function _kv(string memory k, string memory v) internal pure returns (string memory) {
        return string.concat(_q(k), ":", _q(v));
    }

    function _stateJson(V21Ref.State memory s) internal pure returns (string memory) {
        return string.concat(
            "{",
            _kv("lastUpdateTime", vm.toString(uint256(s.lastUpdateTime))),
            ",",
            _kv("lRefTime", vm.toString(uint256(s.lRefTime))),
            ",",
            _kv("lastPosTime", vm.toString(uint256(s.lastPosTime))),
            ",",
            _kv("lRefBits", vm.toString(s.lRefBits)),
            ",",
            _kv("snapBits", vm.toString(s.snapBits)),
            ",",
            _kv("lRefRaiseTime", vm.toString(uint256(s.raiseTime))),
            ",",
            _kv("anchorX16", vm.toString(s.anchorX16)),
            "}"
        );
    }

    function _poolJson(PoolState p) internal pure returns (string memory) {
        return string.concat(
            "{",
            _kv("sqrtRatio", vm.toString(uint256(SqrtRatio.unwrap(p.sqrtRatio())))),
            ",",
            _kv("tick", vm.toString(int256(p.tick()))),
            ",",
            _kv("liquidity", vm.toString(uint256(p.liquidity()))),
            "}"
        );
    }

    function _begin(string memory name, uint16 fee, uint8 spacingExp, int32 tick) internal {
        createPools(fee, spacingExp, tick, uint64(++scenarioCount));
        scenario = string.concat(
            "{",
            _kv("name", name),
            ",",
            _kv("poolFee", vm.toString(uint256(fee))),
            ",",
            _kv("spacingExp", vm.toString(uint256(spacingExp))),
            ",",
            _kv("initialTick", vm.toString(int256(tick))),
            ",",
            _kv("initTimestamp", vm.toString(uint256(_now()))),
            ',"events":['
        );
        swapCount = 0;
    }

    function _sep() internal {
        if (swapCount++ != 0) scenario = string.concat(scenario, ",");
    }

    function _pos(bytes24 salt, int32 lo, int32 hi, int128 liquidityDelta) internal {
        _sep();
        scenario = string.concat(
            scenario,
            "{",
            _kv("type", "position"),
            ",",
            _kv("timestamp", vm.toString(uint256(_now()))),
            ",",
            _kv("tickLower", vm.toString(int256(lo))),
            ",",
            _kv("tickUpper", vm.toString(int256(hi))),
            ",",
            _kv("liquidityDelta", vm.toString(int256(liquidityDelta))),
            "}"
        );
        _lp(salt, lo, hi, liquidityDelta);
    }

    function _swap(bool isToken1, int128 amount, SqrtRatio limit, uint16 minFee) internal {
        V21Ref.State memory sb = _state(pool);
        PoolState pb = _poolState();
        (PoolBalanceUpdate u, PoolState st) = _swapChecked(isToken1, amount, limit, minFee);
        string memory calls = "[";
        uint256 n = actor.refCallsLength();
        for (uint256 i; i < n; i++) {
            V21Actor.RefCall memory c = actor.refCall(i);
            calls = string.concat(
                calls,
                i == 0 ? "" : ",",
                "{",
                _kv("sqrtRatioLimit", vm.toString(uint256(SqrtRatio.unwrap(c.limit)))),
                ",",
                _kv("minFee", vm.toString(uint256(c.fee))),
                ",",
                _kv("amount", vm.toString(int256(c.amount))),
                "}"
            );
        }
        calls = string.concat(calls, "]");
        _sep();
        scenario = string.concat(
            scenario,
            "{",
            _kv("type", "swap"),
            ",",
            _kv("timestamp", vm.toString(uint256(_now()))),
            ",",
            string.concat(
                _kv("isToken1", isToken1 ? "true" : "false"),
                ",",
                _kv("amount", vm.toString(int256(amount))),
                ",",
                _kv("sqrtRatioLimit", vm.toString(uint256(SqrtRatio.unwrap(limit)))),
                ",",
                _kv("minFee", vm.toString(uint256(minFee))),
                ","
            ),
            string.concat(
                '"poolBefore":',
                _poolJson(pb),
                ',"stateBefore":',
                _stateJson(sb),
                ",",
                _kv("firstOfTimestamp", lastWasFirst ? "true" : "false"),
                ",",
                _kv("gateFailed", lastGateFailed ? "true" : "false"),
                ',"coreCalls":',
                calls,
                ","
            ),
            string.concat(
                _kv("delta0", vm.toString(int256(u.delta0()))),
                ",",
                _kv("delta1", vm.toString(int256(u.delta1()))),
                ',"poolAfter":',
                _poolJson(st),
                ',"stateAfter":',
                _stateJson(_state(pool)),
                "}"
            )
        );
    }

    function _end(bool last) internal {
        out = string.concat(out, scenario, "]}", last ? "" : ",\n");
    }

    function _at(int32 t) internal pure returns (SqrtRatio) {
        return tickToSqrtRatio(t);
    }

    function _build() internal returns (string memory) {
        out = string.concat(
            '{"spec":"EKU-946 rev 5 section (b); src/extensions/MEVCaptureV21.sol",',
            '"config":{"halfLife":"120","slopeK":"4","segmentExp":"0","jLin":"16","maxFee":"32768","clampTicks":"2500","mGate":"3","maxSegments":"40"},',
            '"note":"amount in coreCalls is the remaining specified amount passed to Core; sqrtRatioLimit is the raw 96-bit SqrtRatio; Core takes max(poolFee, minFee)",',
            '"scenarios":[\n'
        );

        uint256 t0 = vm.getBlockTimestamp();

        _begin("away_segments_1_3_16", 196, 12, 0);
        _pos(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        _swap(true, BIG, _at(S / 2), 0); // 1 segment
        _swap(true, BIG, _at(3 * S), 0); // finishes segment 1, then 2 and 3
        _swap(true, BIG, _at(16 * S), 0); // segments 4..16
        _swap(false, BIG, _at(-16 * S), 0); // toward to the anchor, then 16 away segments
        _end(false);

        vm.warp(t0 + 1000);
        _begin("exact_in_vs_exact_out", 196, 12, 0);
        _pos(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        _swap(true, 5e18, SqrtRatio.wrap(0), 0);
        _swap(false, -4e18, SqrtRatio.wrap(0), 0);
        _swap(true, -3e18, SqrtRatio.wrap(0), 300);
        _swap(false, 2e18, SqrtRatio.wrap(0), 0);
        _end(false);

        vm.warp(t0 + 2000);
        _begin("n1_fractional_anchor_decay", 196, 12, 0);
        _pos(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        _swap(true, BIG, _at(300), 0);
        vm.warp(t0 + 2012);
        _swap(false, 1, SqrtRatio.wrap(0), 0); // decay: anchor gets a fractional part
        _swap(false, BIG, _at(-2 * S - 77), 0); // toward to ceil(anchor), sliver at segment 1 rate, away
        _swap(true, BIG, _at(5 * S + 3), 0); // toward to floor(anchor), sliver, away up
        _end(false);

        vm.warp(t0 + 3000);
        _begin("boundary_start_and_limits", 196, 12, 0);
        _pos(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        _pos(bytes24(uint192(2)), 3 * S, 10 * S, 1e9);
        _swap(true, BIG, _at(3 * S), 0);
        _swap(true, BIG, _at(5 * S), 0);
        _swap(true, BIG, _at(6 * S), 0);
        _swap(false, BIG, _at(3 * S), 0);
        _swap(true, BIG, _at(5 * S), 0);
        _end(false);

        vm.warp(t0 + 4000);
        _begin("sparse_pool_merge_after_cap", 13, 7, 0);
        _pos(bytes24(uint192(1)), -128 * 4000, -128 * 3000, L66);
        _pos(bytes24(uint192(2)), 128 * 3000, 128 * 4000, L66);
        _swap(true, 1e18, SqrtRatio.wrap(0), 0);
        _swap(false, -1e15, SqrtRatio.wrap(0), 0);
        _end(false);

        vm.warp(t0 + 5000);
        _begin("gate_and_decay_sequence", 196, 12, 0);
        _pos(bytes24(uint192(1)), -40 * S, 2 * S, L66);
        for (uint256 i; i < 10; i++) {
            vm.warp(vm.getBlockTimestamp() + 60);
            _swap(i % 2 == 0, 1e15, SqrtRatio.wrap(0), 0);
        }
        _swap(true, BIG, _at(50_000), 0); // park in the empty range
        vm.warp(vm.getBlockTimestamp() + 12);
        _swap(false, BIG, _at(0), 0); // first touch observes no liquidity: gate result recorded
        vm.warp(vm.getBlockTimestamp() + 240);
        _swap(true, 2e17, SqrtRatio.wrap(0), 0);
        _end(true);

        return string.concat(out, "\n]}\n");
    }

    function test_swap_vectors() public {
        string memory json = _build();
        string memory path = "test/data/mevcapture-v21/swaps.json";
        if (vm.envOr("WRITE_V21_VECTORS", false)) {
            vm.writeFile(path, json);
        } else {
            assertEq(vm.readFile(path), json, "swap vectors changed: regenerate and review");
        }
    }
}
