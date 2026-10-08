// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {Router} from "../../src/Router.sol";
import {MEVCapture, mevCaptureCallPoints} from "../../src/extensions/MEVCapture.sol";
import {MEVCaptureV21, mevCaptureV21CallPoints} from "../../src/extensions/MEVCaptureV21.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {createSwapParameters} from "../../src/types/swapParameters.sol";
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";

/// @notice Gas table v1 vs v2.1 under identical toolchain settings (foundry.toml default profile). Every measurement is a
///   cold, isolated transaction through the Router on an identical pool layout (0.30% fee, spacing 4096). Results are in
///   snapshots/MEVCaptureV21GasTest.json; the table is in mevcapture-v21.md.
/// forge-config: default.isolate = true
contract MEVCaptureV21GasTest is FullTest {
    int32 internal constant S = 4096;
    uint16 internal constant FEE = 196;
    int128 internal constant BIG = type(int128).max >> 8;

    MEVCapture internal v1;
    MEVCaptureV21 internal v21;
    MEVCaptureV21 internal v64;
    Router internal r1;
    Router internal r21;
    Router internal r64;

    function setUp() public override {
        FullTest.setUp();
        address a1 = address(uint160(mevCaptureCallPoints().toUint8()) << 152);
        deployCodeTo("MEVCapture.sol:MEVCapture", abi.encode(core), a1);
        v1 = MEVCapture(a1);
        uint160 base = uint160(mevCaptureV21CallPoints().toUint8()) << 152;
        deployCodeTo(
            "MEVCaptureV21.sol:MEVCaptureV21", abi.encode(core, 120, 4, 0, 16, 1 << 15, 2500, 3), address(base + 0x1000)
        );
        v21 = MEVCaptureV21(address(base + 0x1000));
        deployCodeTo(
            "MEVCaptureV21.sol:MEVCaptureV21", abi.encode(core, 120, 4, 0, 64, 1 << 15, 2500, 3), address(base + 0x2000)
        );
        v64 = MEVCaptureV21(address(base + 0x2000));
        r1 = new Router(core, address(v1), address(0));
        r21 = new Router(core, address(v21), address(0));
        r64 = new Router(core, address(v64), address(0));
        Router[3] memory rs = [r1, r21, r64];
        for (uint256 i; i < 3; i++) {
            token0.approve(address(rs[i]), type(uint256).max);
            token1.approve(address(rs[i]), type(uint256).max);
        }
    }

    function coolAllContracts() internal override {
        FullTest.coolAllContracts();
        vm.cool(address(v1));
        vm.cool(address(v21));
        vm.cool(address(v64));
        vm.cool(address(r1));
        vm.cool(address(r21));
        vm.cool(address(r64));
    }

    function _pool(address ext, int32 lo, int32 hi) internal returns (PoolKey memory pk) {
        pk = createPool(address(token0), address(token1), 0, createConcentratedPoolConfig(FEE, 12, ext, 0));
        createPosition(pk, lo, hi, 1e24, 1e24);
    }

    function _swap(Router r, PoolKey memory pk, bool isToken1, int128 amount, int32 limitTick, string memory name)
        internal
    {
        coolAllContracts();
        r.swapAllowPartialFill(
            pk,
            createSwapParameters({
                _sqrtRatioLimit: limitTick == 0 ? SqrtRatio.wrap(0) : tickToSqrtRatio(limitTick),
                _amount: amount,
                _isToken1: isToken1,
                _skipAhead: 0,
                _minFee: 0
            }),
            address(this)
        );
        if (bytes(name).length != 0) vm.snapshotGasLastCall(name);
    }

    /// @dev Same swap on a fresh v1, v2.1 (J_LIN 16) and v2.1 (J_LIN 64) pool, first swap of a new timestamp
    function _compare(string memory label, int32 lo, int32 hi, bool isToken1, int128 amount, int32 limitTick) internal {
        PoolKey memory p1 = _pool(address(v1), lo, hi);
        PoolKey memory p21 = _pool(address(v21), lo, hi);
        PoolKey memory p64 = _pool(address(v64), lo, hi);
        vm.warp(vm.getBlockTimestamp() + 12);
        _swap(r1, p1, isToken1, amount, limitTick, string.concat("v1 ", label));
        _swap(r21, p21, isToken1, amount, limitTick, string.concat("v2.1 J16 ", label));
        _swap(r64, p64, isToken1, amount, limitTick, string.concat("v2.1 J64 ", label));
    }

    function test_gas_away_1_segment() public {
        _compare("exact-in 1 away segment", -400 * S, 400 * S, true, BIG, S / 2);
    }

    function test_gas_away_3_segments() public {
        _compare("exact-in 3 away segments", -400 * S, 400 * S, true, BIG, 3 * S - 100);
    }

    function test_gas_away_16_segments() public {
        _compare("exact-in 16 away segments", -400 * S, 400 * S, true, BIG, 16 * S - 100);
    }

    function test_gas_away_64_segments() public {
        _compare("exact-in 64 away segments (J16: 16 + 6 doubling)", -400 * S, 400 * S, true, BIG, 64 * S - 100);
    }

    function test_gas_away_to_cap() public {
        // far enough that both configurations reach MAX_FEE and merge (J16: 40 calls max, J64: 88 calls max)
        _compare("exact-in to MAX_FEE and merge", -4000 * S, 4000 * S, true, BIG, 3000 * S);
    }

    function test_gas_sparse_pool_worst_case() public {
        // liquidity only far away: every away segment before it is an empty Core call
        PoolKey memory p1 = _pool(address(v1), 300 * S, 400 * S);
        PoolKey memory p21 = _pool(address(v21), 300 * S, 400 * S);
        PoolKey memory p64 = _pool(address(v64), 300 * S, 400 * S);
        vm.warp(vm.getBlockTimestamp() + 12);
        _swap(r1, p1, true, 1e18, 0, "v1 sparse pool exact-in to far liquidity");
        _swap(r21, p21, true, 1e18, 0, "v2.1 J16 sparse pool exact-in to far liquidity");
        _swap(r64, p64, true, 1e18, 0, "v2.1 J64 sparse pool exact-in to far liquidity");
    }

    function test_gas_exact_out_3_segments() public {
        _compare("exact-out 3 away segments", -400 * S, 400 * S, false, -BIG, 3 * S - 100);
    }

    function test_gas_first_vs_later_swap_in_timestamp() public {
        PoolKey memory p1 = _pool(address(v1), -400 * S, 400 * S);
        PoolKey memory p21 = _pool(address(v21), -400 * S, 400 * S);
        vm.warp(vm.getBlockTimestamp() + 12);
        _swap(r1, p1, true, 1e18, 0, "v1 first swap in timestamp (1 segment)");
        _swap(r1, p1, true, 1e18, 0, "v1 later swap in timestamp (1 segment)");
        _swap(r21, p21, true, 1e18, 0, "v2.1 J16 first swap in timestamp (1 segment)");
        _swap(r21, p21, true, 1e18, 0, "v2.1 J16 later swap in timestamp (1 segment)");
    }

    function test_gas_toward_only() public {
        PoolKey memory p1 = _pool(address(v1), -400 * S, 400 * S);
        PoolKey memory p21 = _pool(address(v21), -400 * S, 400 * S);
        _swap(r1, p1, false, BIG, -5 * S, "");
        _swap(r21, p21, false, BIG, -5 * S, "");
        vm.warp(vm.getBlockTimestamp() + 12);
        _swap(r1, p1, true, BIG, -S, "v1 exact-in toward the anchor (4 spacings)");
        _swap(r21, p21, true, BIG, -S, "v2.1 J16 exact-in toward the anchor (4 spacings)");
    }

    function test_gas_position_hook() public {
        PoolKey memory p0 = _pool(address(0), -400 * S, 400 * S);
        PoolKey memory p1 = _pool(address(v1), -400 * S, 400 * S);
        PoolKey memory p21 = _pool(address(v21), -400 * S, 400 * S);
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);
        uint256 id = positions.mint();
        vm.warp(vm.getBlockTimestamp() + 12);
        PoolKey[3] memory ps = [p0, p1, p21];
        string[3] memory names = ["no extension", "v1", "v2.1 J16"];
        for (uint256 i; i < 3; i++) {
            coolAllContracts();
            positions.deposit(id, ps[i], -S, S, 1e18, 1e18, 0);
            vm.snapshotGasLastCall(string.concat(names[i], " deposit, first position update in timestamp"));
            coolAllContracts();
            positions.deposit(id, ps[i], -S, S, 1e18, 1e18, 0);
            vm.snapshotGasLastCall(string.concat(names[i], " deposit, later position update in timestamp"));
        }
    }
}
