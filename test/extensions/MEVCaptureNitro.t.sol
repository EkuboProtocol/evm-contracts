// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {MEVCaptureV21Base} from "./MEVCaptureV21Base.sol";
import {V21Ref, V21Actor} from "./MEVCaptureV21Helpers.sol";
import {
    ARB_SYS,
    ARB_SYS_NUMBER_CLOCK,
    expectedPrioritySurcharge,
    MEVCaptureNitroUnregistered
} from "./MEVCaptureNitroHelpers.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {MEVCaptureNitro} from "../../src/extensions/MEVCaptureNitro.sol";
import {mevCaptureV21CallPoints} from "../../src/extensions/MEVCaptureV21.sol";
import {IMEVCaptureNitro} from "../../src/interfaces/extensions/IMEVCaptureNitro.sol";
import {IMEVCaptureV21} from "../../src/interfaces/extensions/IMEVCaptureV21.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PositionId} from "../../src/types/positionId.sol";
import {SwapParameters} from "../../src/types/swapParameters.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";

/// @notice What MEVCaptureNitro adds to MEV Capture v2.1: the L2-block clock and the priority surcharge. The ArbSys
///   mock answers with `block.number`, so `vm.roll` is one L2 block and `vm.warp` is time that the extension must not
///   see. Every swap made through `_swapChecked` is replayed by the v2.1 reference model with the L2 block number as
///   its clock and the priority surcharge of the transaction added to every away segment.
contract MEVCaptureNitroTest is MEVCaptureV21Base {
    using CoreLib for *;

    uint256 internal constant BASE_FEE = 0.02 gwei;
    uint64 internal constant FREE = 0.05 gwei;
    // 10 bps per gwei of priority fee, as a 0.64 number per wei
    uint64 internal constant SLOPE = 18446744;
    // 10 bps
    uint64 internal constant CAP = 18446744073709551;

    uint64 internal constant FEE_5BP = 9223372036854775; // 0.05% as a 0.64 number (floor)
    uint64 internal constant MAX_FEE_1PCT = 184467440737095516;
    uint32 internal constant SP = 100;
    int32 internal constant S = 100;
    int128 internal constant L66 = int128(1) << 66;
    int128 internal constant BIG = type(int128).max >> 8;

    uint64 internal priorityFree = FREE;
    uint64 internal prioritySlope = SLOPE;
    uint64 internal priorityCap = CAP;

    function _variant() internal view override returns (Variant memory v) {
        (v.nitro, v.arbSysCode) = (true, ARB_SYS_NUMBER_CLOCK);
        (v.priorityFree, v.prioritySlope, v.priorityCap) = (priorityFree, prioritySlope, priorityCap);
        (v.baseFee, v.gasPrice) = (BASE_FEE, BASE_FEE);
    }

    function _now() internal view override returns (uint32) {
        return uint32(vm.getBlockNumber());
    }

    /// @notice Sub-second parameters: 1 bp segments, slope 5 bps per bp on a 0.05% pool, half-life 40 blocks
    function _config() internal pure returns (V21Ref.Cfg memory c) {
        c = V21Ref.defaults();
        (c.tau, c.slopeK, c.segExp, c.jLin, c.maxFee) = (40, 2, 0, 64, MAX_FEE_1PCT);
    }

    function setUp() public override {
        MEVCaptureV21Base.setUp();
        useExtension(deployV21(_config(), 1), _config());
    }

    function nitro() internal view returns (MEVCaptureNitro) {
        return MEVCaptureNitro(address(v21));
    }

    function _standard() internal {
        createPools(FEE_5BP, SP, 0);
        _lp(bytes24(uint192(1)), -400 * S, 400 * S, L66);
    }

    function _at(int32 tick) internal pure returns (SqrtRatio) {
        return tickToSqrtRatio(tick);
    }

    function _roll(uint256 blocks) internal {
        vm.roll(vm.getBlockNumber() + blocks);
    }

    function _tip(uint256 priorityFeePerGas) internal {
        _setGas(BASE_FEE, BASE_FEE + priorityFeePerGas);
    }

    function _deploy(V21Ref.Cfg memory c) internal returns (MEVCaptureNitroUnregistered) {
        return new MEVCaptureNitroUnregistered(
            core,
            uint32(c.tau),
            uint8(c.slopeK),
            uint8(c.segExp),
            uint8(c.jLin),
            uint64(c.maxFee),
            uint32(c.clamp),
            uint8(c.mGate),
            priorityFree,
            prioritySlope,
            priorityCap
        );
    }

    // ================================================================ deployment

    function test_registered_at_v21_call_points() public view {
        assertTrue(core.isExtensionRegistered(address(v21)));
        assertEq(uint160(address(v21)) >> 152, mevCaptureV21CallPoints().toUint8());
    }

    function test_getConfig_and_getPriorityConfig() public view {
        IMEVCaptureV21.Config memory c = nitro().getConfig();
        assertEq(c.halfLife, 40);
        assertEq(c.slopeK, 2);
        assertEq(c.maxFee, MAX_FEE_1PCT);
        IMEVCaptureNitro.PriorityConfig memory p = nitro().getPriorityConfig();
        assertEq(p.freePriorityFee, FREE);
        assertEq(p.slope, SLOPE);
        assertEq(p.cap, CAP);
    }

    /// @notice The constructor reverts unless the precompile answers with at least one word
    function test_constructor_requires_arbsys() public {
        V21Ref.Cfg memory c = _config();
        bytes[4] memory unavailable = [
            bytes(""),
            // PUSH0 PUSH0 REVERT
            hex"5f5ffd",
            // PUSH1 0x1f PUSH0 RETURN: 31 bytes
            hex"601f5ff3",
            // INVALID, the code Nitro reports at a precompile address to a client that does not run the precompile
            hex"fe"
        ];
        for (uint256 i; i < unavailable.length; i++) {
            vm.etch(ARB_SYS, unavailable[i]);
            vm.expectRevert(IMEVCaptureNitro.ArbSysUnavailable.selector);
            _deploy(c);
        }
        // NUMBER PUSH0 MSTORE PUSH1 0x40 PUSH0 RETURN: more than one word is accepted, the first is the block number
        vm.etch(ARB_SYS, hex"435f5260405ff3");
        _deploy(c);
        vm.etch(ARB_SYS, ARB_SYS_NUMBER_CLOCK);
        _deploy(c);
    }

    /// @notice Disabled is all zero; enabled needs a nonzero slope and a nonzero cap below the fee cap
    function test_constructor_validates_priority_config() public {
        V21Ref.Cfg memory c = _config();
        uint64[3][5] memory invalid = [
            [uint64(1), 0, 0],
            [uint64(0), 0, 1],
            [uint64(0), 1, 0],
            [uint64(0), 1, MAX_FEE_1PCT],
            [uint64(0), 1, type(uint64).max]
        ];
        for (uint256 i; i < invalid.length; i++) {
            (priorityFree, prioritySlope, priorityCap) = (invalid[i][0], invalid[i][1], invalid[i][2]);
            vm.expectRevert(IMEVCaptureV21.InvalidConfig.selector);
            _deploy(c);
        }
        uint64[3][3] memory valid =
            [[uint64(0), 0, 0], [type(uint64).max, type(uint64).max, MAX_FEE_1PCT - 1], [uint64(0), 1, 1]];
        for (uint256 i; i < valid.length; i++) {
            (priorityFree, prioritySlope, priorityCap) = (valid[i][0], valid[i][1], valid[i][2]);
            IMEVCaptureNitro.PriorityConfig memory p = _deploy(c).getPriorityConfig();
            assertEq(p.freePriorityFee, valid[i][0]);
            assertEq(p.slope, valid[i][1]);
            assertEq(p.cap, valid[i][2]);
        }
        // the v2.1 checks still apply
        c.tau = 0;
        vm.expectRevert(IMEVCaptureV21.InvalidConfig.selector);
        _deploy(c);
    }

    // ================================================================ clock

    /// @notice The clock is `ArbSys(0x64).arbBlockNumber()`, read once by each of the three entry points
    function test_clock_calls_arbBlockNumber() public {
        vm.expectCall(ARB_SYS, abi.encodeWithSignature("arbBlockNumber()"), 3);
        createPools(FEE_5BP, SP, 0);
        _lpOn(pool, bytes24(uint192(1)), -400 * S, 400 * S, L66);
        _swapRaw(true, 1e18, SqrtRatio.wrap(0), 0);
    }

    function test_init_state_uses_l2_block(uint64 blockNumber, uint32 time) public {
        vm.roll(blockNumber);
        vm.warp(time);
        createPools(FEE_5BP, SP, 0);
        V21Ref.State memory s = _state(pool);
        assertEq(s.lastUpdateTime, uint32(blockNumber));
        assertEq(s.lRefTime, uint32(blockNumber));
        unchecked {
            assertEq(s.raiseTime, uint32(blockNumber) - 40);
        }
    }

    /// @notice Seconds passing inside one L2 block do not move the anchor; the next L2 block does, within one second
    function test_anchor_moves_per_l2_block_not_per_second() public {
        _standard();
        // same block as the initialization: no anchor update, the price leaves the anchor behind
        _swapChecked(true, BIG, _at(30 * S));
        assertFalse(lastWasFirst);
        assertEq(_anchor(), 0);

        advanceTime(1000);
        _swapChecked(false, 1);
        assertFalse(lastWasFirst, "a later timestamp in the same L2 block is not a new clock value");
        assertEq(_anchor(), 0);

        uint256 time = vm.getBlockTimestamp();
        _roll(1);
        _swapChecked(false, 1);
        assertEq(vm.getBlockTimestamp(), time);
        assertTrue(lastWasFirst, "the next L2 block is");
        assertEq(_state(pool).lastUpdateTime, _now());
        // one block of a 40 block half-life: the offset shrinks by the factor 2^(-1/40)
        int256 offset = (int256(_poolState().tick()) << 16) - _anchor();
        assertApproxEqRel(offset, int256(30 * S << 16) * 982821 / 1000000, 1e15);

        _swapChecked(false, 1);
        assertFalse(lastWasFirst, "one update per L2 block");
    }

    /// @notice `HALF_LIFE` is in L2 blocks
    function test_half_life_is_in_l2_blocks() public {
        _standard();
        _swapChecked(true, BIG, _at(20 * S));
        // more than a half-life of seconds, no blocks
        advanceTime(4000);
        _swapChecked(false, 1);
        assertEq(_anchor(), 0);
        _roll(40);
        _swapChecked(false, 1);
        int256 offset = (int256(_poolState().tick()) << 16) - _anchor();
        assertApproxEqRel(offset, int256(10 * S << 16), 1e15, "the offset halves in 40 blocks");
    }

    /// @notice Elapsed blocks are counted modulo 2^32, so the low 32 bits of the block number wrapping is harmless
    function test_clock_wraps_at_32_bits() public {
        vm.roll((uint256(1) << 32) - 3);
        _standard();
        _swapChecked(true, BIG, _at(20 * S));
        V21Ref.State memory before = _state(pool);
        assertEq(before.lastUpdateTime, type(uint32).max - 2);

        _roll(8);
        // the reference is given the wrapped clock value and computes an elapsed time of 8
        _swapChecked(false, 1);
        assertTrue(lastWasFirst);
        assertEq(_state(pool).lastUpdateTime, 5);
        int256 offset = (int256(_poolState().tick()) << 16) - _anchor();
        // 2^(-8/40)
        assertApproxEqRel(offset, int256(20 * S << 16) * 870551 / 1000000, 1e15);
    }

    function test_fuzz_block_numbers_above_32_bits(uint64 start, uint16 blocks) public {
        vm.roll(start);
        _standard();
        _swapChecked(true, BIG, _at(20 * S));
        vm.roll(uint256(start) + blocks);
        _swapChecked(false, 1);
        assertEq(lastWasFirst, blocks != 0);
        assertEq(_state(pool).lastUpdateTime, uint32(uint256(start) + blocks));
    }

    /// @notice The active liquidity is snapshotted before the first position update of each L2 block
    function test_position_snapshot_once_per_l2_block() public {
        _standard();
        uint256 bits = V21Ref.bitlen(uint128(L66));
        assertEq(_state(pool).lastPosTime, _now());
        assertEq(_state(pool).snapBits, 0, "the first update of the block saw no liquidity");

        advanceTime(1000);
        // `_lp` checks the hook against the reference, which is told the L2 block number
        _lp(bytes24(uint192(2)), -S, S, L66);
        assertEq(_state(pool).snapBits, 0, "a later timestamp in the same L2 block keeps the snapshot");

        _roll(1);
        _lp(bytes24(uint192(3)), -S, S, L66);
        assertEq(_state(pool).lastPosTime, _now());
        assertEq(_state(pool).snapBits, bits + 1, "the next L2 block snapshots the liquidity before the update");
    }

    /// @notice Once deployed, every entry point that reads the clock reverts if the precompile stops answering
    function test_reverts_if_arbsys_stops_answering() public {
        _standard();
        vm.etch(ARB_SYS, hex"5f5ffd");

        V21Actor.Action[] memory acts = new V21Actor.Action[](1);
        acts[0] = _action(1, pool, SwapParameters.unwrap(_params(true, 1e18, SqrtRatio.wrap(0))), 0, address(v21));
        vm.expectRevert(IMEVCaptureNitro.ArbSysUnavailable.selector);
        actor.run(acts);

        acts[0] = _action(0, pool, PositionId.unwrap(_pid(bytes24(uint192(1)), -400 * S, 400 * S)), -1, address(0));
        vm.expectRevert(IMEVCaptureNitro.ArbSysUnavailable.selector);
        actor.run(acts);

        PoolKey memory other = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createConcentratedPoolConfig(FEE_5BP, SP + 1, address(v21))
        });
        vm.expectRevert(IMEVCaptureNitro.ArbSysUnavailable.selector);
        core.initializePool(other, 0);

        // and everything works again once it answers
        vm.etch(ARB_SYS, ARB_SYS_NUMBER_CLOCK);
        _swapChecked(true, 1e18);
    }

    /// @notice Random L2 blocks and seconds between random swaps, each replayed by the reference on the block clock
    function test_fuzz_blocks_and_seconds(uint256 seed) public {
        vm.roll(bound(uint256(keccak256(abi.encode(seed, 0))), 0, uint256(1) << 33));
        _standard();
        for (uint256 j; j < 10; j++) {
            uint256 r = uint256(keccak256(abi.encode(seed, 100 + j)));
            if (r % 4 != 0) _roll((r >> 8) % 4 == 0 ? (r >> 16) % 200 : (r >> 16) % 3);
            if ((r >> 32) % 2 == 0) advanceTime((r >> 40) % 100);
            _randomSwap(r);
        }
    }

    function _randomSwap(uint256 r) internal {
        bool isToken1 = (r >> 60) & 1 == 1;
        bool exactOut = (r >> 61) & 1 == 1;
        int128 amount = int128(uint128(1 + (r >> 64) % 1e21));
        if ((r >> 62) % 5 == 0) amount = int128(uint128(1 + (r >> 64) % 1000));
        if (exactOut) amount = -amount;
        bool increasing = isToken1 != exactOut;
        int256 dist = int256(1 + (r >> 210) % (60 * uint256(int256(S))));
        int256 limitTick = int256(_poolState().tick()) + (increasing ? dist : -dist);
        if (limitTick <= MIN_TICK) limitTick = MIN_TICK + 1;
        if (limitTick >= MAX_TICK) limitTick = MAX_TICK - 1;
        this.swapCheckedExt(isToken1, amount, tickToSqrtRatio(int32(limitTick)));
    }

    // ================================================================ priority surcharge: the rate

    function test_prioritySurcharge_vectors() public view {
        MEVCaptureNitro n = nitro();
        assertEq(n.prioritySurcharge(0), 0);
        assertEq(n.prioritySurcharge(FREE), 0);
        assertEq(n.prioritySurcharge(FREE + 1), SLOPE);
        // 5 bps at half a gwei above the allowance
        assertEq(n.prioritySurcharge(FREE + 0.5 gwei), uint256(SLOPE) * 0.5 gwei);
        assertApproxEqRel(n.prioritySurcharge(FREE + 0.5 gwei), (uint256(1) << 64) * 5 / 10000, 1e12);
        // the slope is rounded down, so one gwei is just under the cap and four wei more reach it
        assertEq(n.prioritySurcharge(FREE + 1 gwei), uint256(SLOPE) * 1 gwei);
        assertLt(n.prioritySurcharge(FREE + 1 gwei + 3), CAP);
        assertEq(n.prioritySurcharge(FREE + 1 gwei + 4), CAP);
        assertEq(n.prioritySurcharge(type(uint128).max), CAP);
        assertEq(n.prioritySurcharge(uint256(type(uint128).max) + FREE + 1), CAP);
        assertEq(n.prioritySurcharge(type(uint256).max), CAP);
    }

    /// @notice Zero up to the allowance, never above the cap, equal to the independently stated rule, for any
    ///   configuration the constructor accepts
    function test_fuzz_prioritySurcharge(uint64 free, uint64 slope, uint64 cap, uint256 tip) public {
        slope = uint64(bound(slope, 1, type(uint64).max));
        cap = uint64(bound(cap, 1, MAX_FEE_1PCT - 1));
        (priorityFree, prioritySlope, priorityCap) = (free, slope, cap);
        MEVCaptureNitro n = _deploy(_config());
        uint256 rate = n.prioritySurcharge(tip);
        assertEq(rate, expectedPrioritySurcharge(tip, 0, free, slope, cap));
        assertLe(rate, cap);
        assertEq(rate == 0, tip <= free);
    }

    function test_fuzz_prioritySurcharge_monotonic(uint256 a, uint256 b) public view {
        if (a > b) (a, b) = (b, a);
        assertLe(nitro().prioritySurcharge(a), nitro().prioritySurcharge(b));
    }

    // ================================================================ priority surcharge: swaps

    /// @notice A transaction that pays no more than the free allowance, or a gas price below the base fee as a
    ///   simulated call can, is charged exactly what it is charged with no tip at all
    function test_no_priority_surcharge_up_to_free_allowance() public {
        _standard();
        uint256 snapshot = vm.snapshotState();
        _tip(0);
        (PoolBalanceUpdate noTip, PoolState stateNoTip) = _swapChecked(true, BIG, _at(12 * S));
        uint256 fee = lastFee0;
        assertGt(fee, 0);

        uint256[4] memory gasPrices = [BASE_FEE + 1, BASE_FEE + FREE, BASE_FEE - 1, 0];
        for (uint256 i; i < gasPrices.length; i++) {
            vm.revertToState(snapshot);
            _setGas(BASE_FEE, gasPrices[i]);
            assertEq(cfg.prio, 0);
            (PoolBalanceUpdate u, PoolState st) = _swapChecked(true, BIG, _at(12 * S));
            assertEq(PoolBalanceUpdate.unwrap(u), PoolBalanceUpdate.unwrap(noTip));
            assertEq(PoolState.unwrap(st), PoolState.unwrap(stateNoTip));
            assertEq(lastFee0, fee);
        }
    }

    /// @notice The priority surcharge is taken from the swapper and credited to the liquidity that traded: the same
    ///   swap with a tip moves the pool identically, returns less by the rate times the output, and the position
    ///   collects the difference
    function test_priority_surcharge_is_paid_to_liquidity() public {
        _standard();
        uint256 snapshot = vm.snapshotState();

        _tip(0);
        (PoolBalanceUpdate noTip, PoolState stateNoTip) = _swapChecked(true, BIG, _at(12 * S));
        uint256 feeNoTip = lastFee0;
        (uint128 collectedNoTip,) = _collect(pool, bytes24(uint192(1)), -400 * S, 400 * S);

        vm.revertToState(snapshot);
        _tip(FREE + 0.5 gwei);
        uint256 prio = uint256(SLOPE) * 0.5 gwei;
        assertEq(cfg.prio, prio);
        (PoolBalanceUpdate tipped, PoolState stateTipped) = _swapChecked(true, BIG, _at(12 * S));
        uint256 feeTipped = lastFee0;
        (uint128 collectedTipped,) = _collect(pool, bytes24(uint192(1)), -400 * S, 400 * S);

        assertEq(PoolState.unwrap(stateTipped), PoolState.unwrap(stateNoTip), "the pool ends in the same state");
        assertEq(tipped.delta1(), noTip.delta1(), "the swapper pays the same input");
        assertEq(lastFee1, 0, "nothing is charged on the specified token");
        uint256 extra = feeTipped - feeNoTip;
        assertEq(int256(tipped.delta0()) - int256(noTip.delta0()), int256(extra), "the output falls by the surcharge");
        // the whole swap is away from the anchor: 12 charged calls, each rounding its fee up
        assertEq(lastCharged, 12);
        uint256 grossOutput = uint256(-int256(noTip.delta0())) + feeNoTip;
        assertApproxEqAbs(extra, (grossOutput * prio) >> 64, 12, "extra == priority rate * output");
        // one accumulateAsFees per charged call, each rounding the position's share down
        assertApproxEqAbs(uint256(collectedTipped) - collectedNoTip, extra, 12, "the position collects the extra");
        assertEq(token0.balanceOf(address(v21)) + token1.balanceOf(address(v21)), 0);
    }

    /// @notice Movement toward the anchor pays no priority surcharge; the part of the same swap that continues past
    ///   the anchor pays the segment surcharge plus the priority surcharge
    function test_priority_surcharge_only_away_from_anchor() public {
        _standard();
        _tip(0);
        _swapChecked(true, BIG, _at(10 * S));
        assertEq(_anchor(), 0);

        _tip(FREE + 5 gwei);
        assertEq(cfg.prio, CAP);
        _swapChecked(false, BIG, _at(2 * S));
        assertEq(lastCalls, 1);
        assertEq(lastCharged, 0, "toward the anchor is one uncharged call");
        assertEq(lastFee0 + lastFee1, 0);

        _swapChecked(false, BIG, _at(-2 * S));
        assertEq(actor.refCall(0).kind, 1, "toward call to the anchor");
        assertEq(actor.refCall(0).fee0 + actor.refCall(0).fee1, 0);
        // first segment below the anchor: ceil(SLOPE_K / 2 * poolFee * 0.5), plus the capped priority surcharge
        assertEq(actor.refCall(1).sur, (uint256(FEE_5BP) + 1) / 2 + CAP);
        assertEq(actor.refCall(2).sur, (3 * uint256(FEE_5BP) + 1) / 2 + CAP);
        assertEq(lastCharged, 2);
        assertGt(lastFee1, 0);
    }

    /// @notice The total fee never exceeds `MAX_FEE`: the priority surcharge brings the cap forward, and from there
    ///   the swap runs without rate boundaries at exactly `MAX_FEE - poolFee`
    function test_priority_surcharge_under_max_fee() public {
        V21Ref.Cfg memory c = _config();
        // room for 20 bps of surcharge above the pool fee
        c.maxFee = FEE_5BP + 36893488147419103;
        useExtension(deployV21(c, 2), c);
        uint256 cap = c.maxFee - FEE_5BP;
        _standard();
        uint256 snapshot = vm.snapshotState();

        // without a tip the segment rates are 2.5, 7.5, 12.5, 17.5 bps and then capped
        _tip(0);
        _swapChecked(true, BIG, _at(12 * S));
        assertEq(lastCharged, 5);
        assertLt(actor.refCall(3).sur, cap);
        assertEq(actor.refCall(4).sur, cap);

        // with 10 bps of priority surcharge: 12.5, 17.5 bps and then capped
        vm.revertToState(snapshot);
        _tip(FREE + 5 gwei);
        _swapChecked(true, BIG, _at(12 * S));
        assertEq(lastCharged, 3);
        assertEq(actor.refCall(0).sur, (uint256(FEE_5BP) + 1) / 2 + CAP);
        assertLt(actor.refCall(1).sur, cap);
        assertEq(actor.refCall(2).sur, cap);
        for (uint256 i; i < lastCalls; i++) {
            assertLe(uint256(actor.refCall(i).sur) + FEE_5BP, c.maxFee);
        }
    }

    /// @notice Exact-out: the priority surcharge is grossed up on the input, like the segment surcharge
    function test_priority_surcharge_exact_out() public {
        _standard();
        uint256 snapshot = vm.snapshotState();
        _tip(0);
        (PoolBalanceUpdate noTip,) = _swapChecked(false, -1e18, _at(12 * S));
        uint256 feeNoTip = lastFee1;

        vm.revertToState(snapshot);
        _tip(FREE + 0.5 gwei);
        (PoolBalanceUpdate tipped,) = _swapChecked(false, -1e18, _at(12 * S));
        assertEq(tipped.delta0(), noTip.delta0(), "the swapper receives the same output");
        assertEq(lastFee0, 0);
        assertGt(lastFee1, feeNoTip);
        assertEq(int256(tipped.delta1()) - int256(noTip.delta1()), int256(lastFee1 - feeNoTip));
    }

    /// @notice A disabled priority surcharge ignores the gas price entirely
    function test_fuzz_disabled_priority_ignores_gas_price(uint256 baseFee, uint256 gasPrice, uint256 seed) public {
        (priorityFree, prioritySlope, priorityCap) = (0, 0, 0);
        useExtension(deployV21(_config(), 2), _config());
        _standard();
        // the test environment accepts gas prices below 2^64 only
        _setGas(bound(baseFee, 0, type(uint64).max - 1), bound(gasPrice, 0, type(uint64).max - 1));
        assertEq(cfg.prio, 0);
        assertEq(nitro().prioritySurcharge(gasPrice), 0);
        for (uint256 j; j < 4; j++) {
            _roll(1);
            _randomSwap(uint256(keccak256(abi.encode(seed, j))));
        }
    }

    /// @notice Random gas prices, base fees, L2 blocks and swaps, each replayed by the reference with the priority
    ///   surcharge that the independently stated rule gives for that transaction
    function test_fuzz_priority_swaps(uint256 seed) public {
        _standard();
        uint256 charged;
        for (uint256 j; j < 10; j++) {
            uint256 r = uint256(keccak256(abi.encode(seed, j)));
            uint256 baseFee = (r >> 8) % 5 == 0 ? 0 : (r >> 16) % 1 gwei;
            uint256 kind = (r >> 48) % 6;
            uint256 tip;
            if (kind == 1) tip = (r >> 56) % (uint256(FREE) + 1);
            else if (kind == 2 || kind == 3) tip = FREE + (r >> 56) % 1.2 gwei;
            // the test environment accepts gas prices below 2^64 only
            else if (kind == 4) tip = (r >> 56) % (type(uint64).max - 1 gwei);
            // below the base fee, as in a simulated call
            uint256 gasPrice = kind == 5 ? baseFee / 2 : baseFee + tip;
            _setGas(baseFee, gasPrice);
            assertLe(cfg.prio, CAP);
            if (kind < 2 || kind == 5) assertEq(cfg.prio, 0);
            if (r % 3 == 0) _roll(1 + (r >> 4) % 50);
            _randomSwap(uint256(keccak256(abi.encode(seed, 1000 + j))));
            if (cfg.prio != 0) charged += lastCharged;
        }
        assertEq(token0.balanceOf(address(v21)) + token1.balanceOf(address(v21)), 0);
        emit log_named_uint("charged calls with a priority surcharge", charged);
    }
}
