// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IExposedStorage} from "../../src/interfaces/IExposedStorage.sol";
import {IZeroSeedLaunch, ZERO_SEED_LAUNCH_CREATE} from "../../src/interfaces/extensions/IZeroSeedLaunch.sol";
import {ZeroSeedLaunch, MAX_CREATOR_FEE} from "../../src/extensions/ZeroSeedLaunch.sol";
import {MintableERC20} from "../../src/MintableERC20.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "../../src/math/constants.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolConfig} from "../../src/types/poolConfig.sol";
import {PositionId} from "../../src/types/positionId.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {amountBeforeFee, AmountBeforeFeeOverflow} from "../../src/math/fee.sol";
import {decayedFee, decayQ128, Q128, DECAY_ZERO_FROM} from "../../src/math/feeDecay.sol";
import {ZeroSeedLaunchBase} from "./ZeroSeedLaunch.t.sol";
import {MaliciousLocker} from "./ZeroSeedLaunchAdversarial.t.sol";
import {LaunchTestRouter} from "../LaunchTestRouter.sol";

uint256 constant Q64 = 1 << 64;

/// @dev The previous implementation, kept here only as the benchmark baseline: a per-launch Q0.64 base raised by
/// square-and-multiply with a floor after every multiply, computed twice per fee (endpoint and elapsed).
function legacyPowQ64(uint64 factor, uint256 exponent) pure returns (uint256 result) {
    result = Q64;
    uint256 base = factor;
    unchecked {
        while (exponent != 0) {
            if (exponent & 1 != 0) result = (result * base) >> 64;
            exponent >>= 1;
            if (exponent != 0) base = (base * base) >> 64;
        }
    }
}

function legacyDecayedFee(uint64 initialFee, uint64 finalFee, uint64 decayFactor, uint32 duration, uint256 elapsed)
    pure
    returns (uint64)
{
    if (elapsed == 0) return initialFee;
    if (elapsed >= duration) return finalFee;
    uint256 endpoint = legacyPowQ64(decayFactor, duration);
    return finalFee
        + uint64(uint256(initialFee - finalFee) * (legacyPowQ64(decayFactor, elapsed) - endpoint) / (Q64 - endpoint));
}

/// @dev External entry points so the isolated math can be measured as a call and pure reverts can be expected.
contract FeeMathProbe {
    function fixedBase(uint64 initialFee, uint64 finalFee, uint32 duration, uint256 elapsed)
        external
        pure
        returns (uint64)
    {
        return decayedFee(initialFee, finalFee, duration, elapsed);
    }

    function legacy(uint64 initialFee, uint64 finalFee, uint64 factor, uint32 duration, uint256 elapsed)
        external
        pure
        returns (uint64)
    {
        return legacyDecayedFee(initialFee, finalFee, factor, duration, elapsed);
    }

    function decay(uint256 elapsed) external pure returns (uint256) {
        return decayQ128(elapsed);
    }

    function identity(uint64 initialFee, uint64, uint32, uint256) external pure returns (uint64) {
        return initialFee;
    }

    function identityLegacy(uint64 initialFee, uint64, uint64, uint32, uint256) external pure returns (uint64) {
        return initialFee;
    }

    function beforeFee(uint128 afterFee, uint64 fee) external pure returns (uint128) {
        return amountBeforeFee(afterFee, fee);
    }
}

/// @dev Takes a Core lock and, inside it, asks the test for Core's transient lock state, so the test can prove that
/// its `tload` reads are live (nonzero while a lock is open) and not vacuously zero.
contract LockObserver is BaseLocker {
    constructor(ICore core) BaseLocker(core) {}

    function observe(address test, PoolKey memory key) external returns (uint256 locker, uint256 count) {
        return abi.decode(lock(abi.encode(test, key)), (uint256, uint256));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (address test, PoolKey memory key) = abi.decode(data, (address, PoolKey));
        (uint256 locker, uint256 count,,) = FeeCurveBase(payable(test)).coreLockState(key);
        return abi.encode(locker, count);
    }
}

abstract contract FeeCurveBase is ZeroSeedLaunchBase {
    using CoreLib for ICore;

    uint64 constant RATE_50 = 9223372036854775808;
    uint64 constant RATE_75 = 13835058055282163712;
    uint64 constant RATE_90 = 16602069666338596454;
    /// @dev floor(2**64 * 99 / 100): a study rate like the others, no longer a ceiling.
    uint64 constant RATE_99 = 18262276632972456099;
    /// @dev Highest encodable rate, 2**64 - 1 = MAX_CREATOR_FEE: created like any other rate.
    uint64 constant RATE_MAX = type(uint64).max;
    /// @dev floor(2**64 * 2**(-1/600)): the per-second factor the previous implementation was given for the
    /// canonical window, i.e. the same 600 s half-life the table now fixes.
    uint64 constant LEGACY_FACTOR = 18425445863997925462;

    address ROUTER;

    FeeMathProbe internal probe;

    function setUp() public virtual override {
        super.setUp();
        probe = new FeeMathProbe();
    }

    function _rates() internal pure returns (uint64[5] memory) {
        return [RATE_50, RATE_75, RATE_90, RATE_99, RATE_MAX];
    }

    function _label(uint64 rate) internal pure returns (string memory) {
        if (rate == FEE_03) return "0.3";
        if (rate == FEE_5) return "5";
        if (rate == RATE_50) return "50";
        if (rate == RATE_75) return "75";
        if (rate == RATE_90) return "90";
        if (rate == RATE_99) return "99";
        if (rate == RATE_MAX) return "max";
        return _ustr(rate);
    }

    /// @dev Creates a launch with an explicit schedule through the periphery, exactly as a user would, at any rate
    /// up to and including `RATE_MAX`. The stored record is checked against the request so that no test below can
    /// pass on a substituted rate.
    function _createCurve(bool tokenIs0, uint8 quoteDecimals, uint32 duration, uint64 initialFee, uint64 finalFee)
        internal
        returns (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p)
    {
        _quote(tokenIs0, quoteDecimals);
        p = _parameters(quoteDecimals == 18 ? ASK_18_18 : ASK_18_6, REQUESTED_SUPPLY, duration);
        p.initialFee = initialFee;
        p.finalFee = finalFee;
        _bind(p, creator);
        vm.prank(creator);
        inst = periphery.create(p);
        MintableERC20(inst.token).approve(address(swapper), type(uint256).max);
        _assertSchedule(inst.poolKey.toPoolId(), initialFee, finalFee, duration);
    }

    /// @dev The record holds the requested schedule and the live rate at the start is the requested initial rate.
    function _assertSchedule(PoolId id, uint64 initialFee, uint64 finalFee, uint32 duration) internal view {
        IZeroSeedLaunch.Launch memory l = launch.getLaunch(id);
        assertEq(l.controller, address(periphery), "controller");
        assertEq(l.initialFee, initialFee, "stored initial fee");
        assertEq(l.finalFee, finalFee, "stored final fee");
        assertEq(l.feeDuration, duration, "stored duration");
        assertEq(l.tradingStart, START, "stored start");
        assertEq(launch.feeAt(id, START), initialFee, "rate at start");
        assertEq(launch.feeAt(id, uint256(START) + duration), finalFee, "rate at end");
    }

    /// @dev Core's transient accounting for the probe's lock, read through `tload`: the current locker word (zero
    /// outside any lock), the nonzero-debt count of lock id 0 (the swapper's lock when nothing is nested) and that
    /// lock's debt for each pool token. Slot constants as in `FlashAccountant`:
    /// keccak256("FlashAccountant#CURRENT_LOCKER_SLOT"), keccak256("FlashAccountant#NONZERO_DEBT_COUNT_OFFSET") and
    /// keccak256("FlashAccountant#_DEBT_LOCKER_TOKEN_ADDRESS_OFFSET") + (id << 160) + token.
    function coreLockState(PoolKey memory key)
        public
        view
        returns (uint256 locker, uint256 nonzeroDebtCount, uint256 debt0, uint256 debt1)
    {
        uint256 currentLockerSlot = uint256(keccak256("FlashAccountant#CURRENT_LOCKER_SLOT"));
        uint256 nonzeroDebtCountOffset = uint256(keccak256("FlashAccountant#NONZERO_DEBT_COUNT_OFFSET"));
        uint256 debtOffset = uint256(keccak256("FlashAccountant#_DEBT_LOCKER_TOKEN_ADDRESS_OFFSET"));
        assertEq(currentLockerSlot, 0x07cc7f5195d862f505d6b095c82f92e00cfc1766f5bca4383c28dc5fca1555fd, "slot");
        assertEq(nonzeroDebtCountOffset, 0x7772acfd7e0f66ebb20a058830296c3dc1301b111d23348e1c961d324223190d, "slot");
        assertEq(debtOffset, 0x753dfe4b4dfb3ff6c11bbf6a97f3c094e91c003ce904a55cc5662fbad220f599, "slot");
        (bool ok, bytes memory words) = CORE.staticcall(
            abi.encodePacked(
                IExposedStorage.tload.selector,
                currentLockerSlot,
                nonzeroDebtCountOffset,
                debtOffset + uint256(uint160(key.token0)),
                debtOffset + uint256(uint160(key.token1))
            )
        );
        assertTrue(ok && words.length == 128, "tload");
        (locker, nonzeroDebtCount, debt0, debt1) = abi.decode(words, (uint256, uint256, uint256, uint256));
    }

    function _feeLedger(PoolKey memory key, address token) internal view returns (uint128 tokenFee, uint128 quoteFee) {
        (uint128 f0, uint128 f1) = launch.creatorFees(key);
        (tokenFee, quoteFee) = key.token0 == token ? (f0, f1) : (f1, f0);
    }

    /// @dev Standard ABI for the locally compiled test locker.
    function _route(
        PoolKey memory key,
        address specified,
        address calculated,
        int128 amount,
        int128 minOut,
        bool allowPartial,
        uint32 deadline
    ) internal view returns (bytes memory) {
        return abi.encodeCall(
            LaunchTestRouter.swap, (key, specified, calculated, amount, minOut, allowPartial, deadline)
        );
    }

    function _call(bytes memory route) internal returns (bool ok, int256 specified, int256 calculated) {
        return _callWithValue(route, 0);
    }

    /// @dev Native input is attached as `value`; the router refunds whatever the route does not spend.
    function _callWithValue(bytes memory route, uint256 value)
        internal
        returns (bool ok, int256 specified, int256 calculated)
    {
        bytes memory result;
        (ok, result) = ROUTER.call{value: value}(route);
        if (ok) (,, specified, calculated) = abi.decode(result, (address, address, int256, int256));
    }

    function _routerQuote(bytes memory route) internal returns (int256 calculated) {
        uint256 snapshot = vm.snapshotState();
        vm.deal(ROUTER, 1e35);
        (bool ok, bytes memory result) = ROUTER.call(route);
        assertTrue(ok, "quote");
        (,,, calculated) = abi.decode(result, (address, address, int256, int256));
        vm.revertToState(snapshot);
    }
}

/// @dev Pure schedule properties of the fixed-base table: generator pins, cutoffs, monotonicity, endpoints,
/// Python-pinned digests over every second of two windows at six rates, and the deviation from the previous
/// variable-base implementation at the canonical parameters.
contract FeeCurveMathTest is FeeCurveBase {
    /// @dev `decayQ128(2**i)` is exactly the i-th generated constant; pinned to `gen-fee-decay-table.py` output.
    function test_table_matchesGenerator() public pure {
        uint128[17] memory table = [
            0xffb455641fc9685643c7b57de2b93da1,
            0xff68c125a89b955b2cec5e897ba641e0,
            0xfed1dba68638bfb9c0cc9d0ff56a3393,
            0xfda51be6d4b61b1517e2bfd323d3b6c2,
            0xfb4fc3a33b08a547ec1434c8cf4ed7fc,
            0xf6b5827c6a03777471be5bb1aa9f8ddb,
            0xedc15778e22f2a9d19d78ab31558f4c2,
            0xdccf8dfad4f3c2d605c01895804ca0a4,
            0xbe75644e08659d6e11dc660f7cac0a64,
            0x8db276b8ab1790e9ca4fea27d409af09,
            0x4e6e1330bc54a5572bc9b369ae03cf4a,
            0x180743063215b2baf06deaafe56f4d0f,
            0x02415cc5e5470d1091ac784874015d70,
            0x0005162355b2600ea2c6e0c244fa2dc5,
            0x00000019df4b7092f48b13d2e916f37d,
            0x000000000000029d5f80810ef0d05f8e,
            0x0000000000000000000000000006d63c
        ];
        for (uint256 i; i < table.length; i++) {
            assertEq(decayQ128(1 << i), table[i], "constant");
        }
        assertEq(DECAY_ZERO_FROM, 1 << table.length, "cutoff is the first bit without a constant");
    }

    function test_decay_boundaries() public pure {
        assertEq(decayQ128(0), Q128, "2**0 = 1");
        // 600 s is one half-life and 3,600 s six: the floored chain sits one unit under the exact power of two.
        assertEq(decayQ128(600), (Q128 >> 1) - 1, "half-life");
        assertEq(decayQ128(3600), (Q128 >> 6) - 1, "six half-lives");
        assertEq(decayQ128(76799), 1, "last nonzero second");
        assertEq(decayQ128(76800), 0, "600 * 128 s: 2**-128");
        assertEq(decayQ128(DECAY_ZERO_FROM - 1), 0, "zero before the cutoff");
        assertEq(decayQ128(DECAY_ZERO_FROM), 0, "zero at the cutoff");
        // Without the cutoff, bits above the table would be ignored and 2**17 + 1 would alias to 1 second.
        assertEq(decayQ128(DECAY_ZERO_FROM + 1), 0, "no aliasing above the cutoff");
        assertEq(decayQ128(type(uint32).max), 0, "uint32 duration domain");
        assertEq(decayQ128(type(uint256).max), 0, "whole domain");
    }

    function testFuzz_decayMonotoneAndBounded(uint32 a, uint32 b) public pure {
        if (a > b) (a, b) = (b, a);
        uint256 da = decayQ128(a);
        uint256 db = decayQ128(b);
        assertLe(da, Q128, "<= 1");
        assertGe(da, db, "non-increasing");
    }

    function testFuzz_feeBoundedMonotoneEndpoints(
        uint64 initialFee,
        uint64 finalFee,
        uint32 duration,
        uint32 a,
        uint32 b
    ) public pure {
        // The whole uint64 range for the initial rate, including 2**64 - 1.
        finalFee = uint64(bound(finalFee, 0, initialFee));
        duration = uint32(bound(duration, 1, type(uint32).max));
        if (a > b) (a, b) = (b, a);
        assertEq(decayedFee(initialFee, finalFee, duration, 0), initialFee, "start");
        assertEq(decayedFee(initialFee, finalFee, duration, duration), finalFee, "end");
        assertEq(decayedFee(initialFee, finalFee, duration, uint256(duration) + 1), finalFee, "after end");
        uint64 fa = decayedFee(initialFee, finalFee, duration, a);
        uint64 fb = decayedFee(initialFee, finalFee, duration, b);
        assertLe(fa, initialFee, "<= initial");
        assertGe(fa, finalFee, ">= final");
        assertGe(fa, fb, "non-increasing");
    }

    /// @dev SHA-256 chain over every second of the window, inclusive, as pinned by the Python generator.
    function _digest(uint64 initialFee, uint64 finalFee, uint32 duration) internal pure returns (bytes32 h) {
        for (uint256 t; t <= duration; t++) {
            h = sha256(bytes.concat(h, bytes8(decayedFee(initialFee, finalFee, duration, t))));
        }
    }

    function test_digests_allSeconds_pinned() public pure {
        uint64[5] memory rates = [RATE_50, RATE_75, RATE_90, RATE_99, RATE_MAX];
        bytes32[5] memory d600 = [
            bytes32(0xa5d0666688ef4a2dd7153351cf2871a5b84a4fbf7023bbb876bc2de8c740cf23),
            bytes32(0x8acacd858306553f71f73f15197ccf8915d3473a6a1d3ced8876ff355fd2a865),
            bytes32(0xd29e09a6613fbd52bccbcc0e49ba74ea7469bcea65904887c67b3115603b7109),
            bytes32(0x47a588db69ac7fe12529c7cb9b15fe91b41494195360caa9bccb939ae8133cc4),
            bytes32(0x7c849a9c92021aa28ed2e4a32f7c33b15c2ff8513157f822229f53e85c0f9612)
        ];
        bytes32[5] memory d3600 = [
            bytes32(0x9d60494802e0ebc9136779b23c27cd4a18f13b9c68102aa343908cf6d422b3f6),
            bytes32(0x700df4fd9f07ce4eedc4ad337d17836c478b0a2b1e752ae3cbfdf72940aae60f),
            bytes32(0x4cfbc14801fe33bef5a1c0201d2cc03a992d446efd4bacdd3883469e8dc7d5d1),
            bytes32(0x7988ddeb4a28991a8b29a05eb9ce25763fc27d41a25a370d19f5b1364f285bfc),
            bytes32(0x56a3f80709937290c4323f106110af97b27ec87e019266c65bd91eb3aa316e02)
        ];
        for (uint256 i; i < rates.length; i++) {
            assertEq(_digest(rates[i], FEE_03, 600), d600[i], "600 s digest");
            assertEq(_digest(rates[i], FEE_03, 3600), d3600[i], "3,600 s digest");
        }
    }

    /// @dev The canonical 50% -> 0.3% over 3,600 s curve against the previous implementation at the factor it was
    /// given for that window: every second within 120 units of 2**-64 (about 6.5e-18 absolute), as the generator
    /// reports, and the first and last seconds identical.
    function test_canonical_vsLegacyFactor() public pure {
        uint256 worst;
        uint256 worstAt;
        uint64 previous = RATE_50;
        for (uint256 t; t <= 3600; t++) {
            uint64 fee = decayedFee(RATE_50, FEE_03, 3600, t);
            uint64 legacy = legacyDecayedFee(RATE_50, FEE_03, LEGACY_FACTOR, 3600, t);
            uint256 diff = fee > legacy ? fee - legacy : legacy - fee;
            if (diff > worst) (worst, worstAt) = (diff, t);
            assertLe(fee, previous, "non-increasing");
            previous = fee;
        }
        assertEq(worst, 120, "max deviation in Q64 units");
        assertEq(worstAt, 756, "where");
        assertEq(decayedFee(RATE_50, FEE_03, 3600, 0), legacyDecayedFee(RATE_50, FEE_03, LEGACY_FACTOR, 3600, 0));
        assertEq(decayedFee(RATE_50, FEE_03, 3600, 3600), legacyDecayedFee(RATE_50, FEE_03, LEGACY_FACTOR, 3600, 3600));
        assertEq(decayedFee(RATE_50, FEE_03, 3600, 1800), 1074010432735978337, "midpoint (Python)");
    }

    /// @dev The schedule at the maximum initial rate: exact endpoints, strictly below the maximum one second in
    /// (the decay chain is strictly below one at t = 1), non-increasing, and the duration extremes. For the longest
    /// window the chain reaches zero at 76,800 s, so the rate is `finalFee` from there even though the window is
    /// still open: that is the generated table's documented cutoff, not a rate ceiling.
    function test_maxRate_scheduleEndpointsAndDurationExtremes_pure() public pure {
        uint64[3] memory finals = [uint64(0), FEE_03, RATE_MAX];
        uint32[4] memory durations = [uint32(1), 2, DURATION, type(uint32).max];
        for (uint256 f; f < finals.length; f++) {
            for (uint256 d; d < durations.length; d++) {
                uint64 final_ = finals[f];
                uint32 duration = durations[d];
                assertEq(decayedFee(RATE_MAX, final_, duration, 0), RATE_MAX, "start");
                assertEq(decayedFee(RATE_MAX, final_, duration, duration), final_, "end");
                assertEq(decayedFee(RATE_MAX, final_, duration, uint256(duration) + 1), final_, "after end");
                assertEq(decayedFee(RATE_MAX, final_, duration, type(uint256).max), final_, "far after end");
                uint64 one = decayedFee(RATE_MAX, final_, duration, 1);
                if (final_ == RATE_MAX) assertEq(one, RATE_MAX, "flat at the maximum");
                else if (duration > 1) assertLt(one, RATE_MAX, "strictly below the maximum one second in");
                uint64 previous = RATE_MAX;
                uint256[8] memory samples = [uint256(1), 2, 599, 600, 1800, 3599, 76799, 76800];
                for (uint256 s; s < samples.length; s++) {
                    uint64 fee = decayedFee(RATE_MAX, final_, duration, samples[s]);
                    assertLe(fee, previous, "non-increasing");
                    assertGe(fee, final_, ">= final");
                    previous = fee;
                }
                if (duration == type(uint32).max) {
                    assertEq(decayedFee(RATE_MAX, final_, duration, DECAY_ZERO_FROM), final_, "table cutoff");
                    assertEq(decayedFee(RATE_MAX, final_, duration, 76800), final_, "chain zero");
                    assertGe(decayedFee(RATE_MAX, final_, duration, 76799), final_, "last nonzero second");
                }
            }
        }
    }

    function test_exactOutput_helperAndSignedBounds_pure() public {
        // amountBeforeFee reverts rather than wrapping; the creator fee path inherits the guard.
        assertEq(probe.beforeFee(1, RATE_MAX), 1 << 64, "one unit at the maximum rate grosses up to 2**64");
        vm.expectRevert(AmountBeforeFeeOverflow.selector);
        probe.beforeFee(uint128(1) << 64, RATE_MAX);
    }
}

/// @dev High initial rates on the pinned fixture: ordinary periphery creation at 50/75/90/99% and at the maximum
/// encodable rate, executed swaps in both orders (plain ERC-20 quote above the token, native ETH below it) and at
/// 18/6 decimals, the exact-output representation limits and the test router at the maximum rate.
contract FeeCurveHighRateTest is FeeCurveBase {
    using CoreLib for ICore;

    /// @dev Ordinary creation at `2**64 - 1`: both orders, native ETH and plain ERC-20 quotes at 18 and 6 decimals,
    /// the maximum decaying to the reference final rate, to zero, and staying flat at the maximum, over the
    /// canonical window and both duration extremes. The emitted `LaunchCreated` parameters, the stored record and
    /// the live schedule all carry the exact requested rate, and a first buy settles at that rate.
    function test_create_maxRate_bothOrders_nativeAndERC20_schedules() public {
        bool[4] memory orders = [true, false, true, false];
        uint8[4] memory decimals = [18, 18, 6, 6];
        uint64[3] memory finals = [FEE_03, RATE_MAX, 0];
        uint32[3] memory durations = [DURATION, 1, type(uint32).max];
        for (uint256 o; o < orders.length; o++) {
            for (uint256 s; s < finals.length; s++) {
                uint256 snap = vm.snapshotState();
                vm.recordLogs();
                (IZeroSeedLaunch.Installation memory inst,) =
                    _createCurve(orders[o], decimals[o], durations[s], RATE_MAX, finals[s]);
                bool native = !orders[o] && decimals[o] == 18;
                assertEq(inst.poolKey.token0 == NATIVE_TOKEN_ADDRESS, native, "native quote is token0");
                assertEq(inst.poolKey.token0 == inst.token, orders[o], "order");
                _assertCreatedEvent(inst, RATE_MAX, finals[s], durations[s]);
                _assertLiveSchedule(inst.poolKey.toPoolId(), finals[s], durations[s]);

                // A first buy of one whole quote unit at the start settles at the maximum rate.
                vm.warp(START);
                int128 unit = int128(uint128(10 ** decimals[o]));
                PoolBalanceUpdate u = _buy(inst.poolKey, inst.token, unit, false);
                (uint128 feeToken,) = _feeLedger(inst.poolKey, inst.token);
                uint128 net = uint128(-_tokenDelta(inst.poolKey, inst.token, u));
                uint256 gross = uint256(net) + feeToken;
                assertEq(net, gross >> 64, "net = floor(gross / 2**64)");
                assertEq(feeToken, gross - (gross >> 64), "fee = gross - net");
                assertGt(net, 0, "a whole unit still fills");
                _assertLedger(inst, activeQuote, uint128(unit), 0, MAX_DUST);
                console2.log(
                    string.concat(
                        "VEC|createMax|order=",
                        orders[o] ? "t0" : "t1",
                        native ? "(native)" : "",
                        "|dec=18/",
                        _ustr(decimals[o]),
                        "|final=",
                        _label(finals[s]),
                        "|duration=",
                        _ustr(durations[s]),
                        "|gross=",
                        _ustr(gross),
                        "|fee=",
                        _ustr(feeToken),
                        "|net=",
                        _ustr(net)
                    )
                );
                vm.revertToState(snap);
            }
        }
    }

    /// @dev The `LaunchCreated` event emitted by the extension carries the parameters as requested.
    function _assertCreatedEvent(
        IZeroSeedLaunch.Installation memory inst,
        uint64 initialFee,
        uint64 finalFee,
        uint32 duration
    ) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(launch) || logs[i].topics[0] != IZeroSeedLaunch.LaunchCreated.selector) {
                continue;
            }
            assertEq(logs[i].topics[1], PoolId.unwrap(inst.poolKey.toPoolId()), "event pool id");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), inst.token, "event token");
            assertEq(address(uint160(uint256(logs[i].topics[3]))), address(periphery), "event controller");
            (,, uint128 liquidity, IZeroSeedLaunch.LaunchParameters memory emitted) =
                abi.decode(logs[i].data, (PoolKey, PositionId, uint128, IZeroSeedLaunch.LaunchParameters));
            assertEq(liquidity, inst.liquidity, "event liquidity");
            assertEq(emitted.initialFee, initialFee, "event initial fee");
            assertEq(emitted.finalFee, finalFee, "event final fee");
            assertEq(emitted.feeDuration, duration, "event duration");
            assertEq(emitted.tradingStart, START, "event start");
            found = true;
        }
        assertTrue(found, "LaunchCreated emitted");
    }

    /// @dev `feeAt` over the window from the maximum: exact endpoints, strictly below the maximum one second in
    /// unless flat or a one-second window, non-increasing and bounded, `finalFee` at and after the end.
    function _assertLiveSchedule(PoolId id, uint64 finalFee, uint32 duration) internal view {
        assertEq(launch.feeAt(id, START - 1), RATE_MAX, "before start");
        assertEq(launch.feeAt(id, START), RATE_MAX, "at start");
        uint64 one = launch.feeAt(id, START + 1);
        if (finalFee == RATE_MAX) assertEq(one, RATE_MAX, "flat");
        else if (duration == 1) assertEq(one, finalFee, "one-second window");
        else assertLt(one, RATE_MAX, "decays from the first second");
        uint64 previous = RATE_MAX;
        uint256[6] memory samples = [uint256(1), 600, 1800, 3599, 3600, 76800];
        for (uint256 s; s < samples.length; s++) {
            uint64 fee = launch.feeAt(id, START + samples[s]);
            assertLe(fee, previous, "non-increasing");
            assertGe(fee, finalFee, ">= final");
            previous = fee;
        }
        assertEq(launch.feeAt(id, uint256(START) + duration), finalFee, "at end");
        assertEq(launch.feeAt(id, uint256(START) + duration + 1), finalFee, "after end");
        assertEq(launch.feeAt(id, type(uint256).max), finalFee, "far after end");
    }

    /// @dev Exactly 100% is 2**64: not a uint64. Calldata carrying that word in either fee field fails ABI decoding
    /// before any logic, with empty revert data, through the periphery (create and preview) and through a raw
    /// forward. The same calldata with 2**64 - 1 in that word creates the launch, so the one word is the only
    /// difference. Nothing is truncated or wrapped.
    function test_create_exactHundredPercentRefused_maxAccepted() public {
        assertEq(RATE_MAX, MAX_CREATOR_FEE, "the ceiling is the type maximum");
        _quote(true, 18);
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(ASK_18_18, REQUESTED_SUPPLY, DURATION);
        p.initialFee = RATE_MAX;
        p.finalFee = RATE_MAX;
        _bind(p, creator);
        bytes memory create = abi.encodeCall(periphery.create, (p));
        bytes memory preview = abi.encodeCall(periphery.previewInstallation, (creator, p));
        bytes32 word = bytes32(uint256(RATE_MAX));
        // The struct is encoded in field order, so the first match is `initialFee` and the second `finalFee`.
        uint256[2] memory offsets = [_wordOffset(create, word, 4), 0];
        offsets[1] = _wordOffset(create, word, offsets[0] + 32);
        assertEq(offsets[1], offsets[0] + 32, "initialFee and finalFee are adjacent words");
        for (uint256 i; i < 2; i++) {
            bytes memory bad = _withWord(create, offsets[i], bytes32(uint256(1) << 64));
            vm.prank(creator);
            (bool ok, bytes memory reason) = address(periphery).call(bad);
            assertFalse(ok, "100% rejected by create");
            assertEq(reason.length, 0, "ABI decoder revert, no custom error");
            uint256 previewOffset = _wordOffset(preview, word, 4) + 32 * i;
            (ok, reason) = address(periphery).call(_withWord(preview, previewOffset, bytes32(uint256(1) << 64)));
            assertFalse(ok, "100% rejected by preview");
            assertEq(reason.length, 0, "ABI decoder revert, no custom error");
        }
        // Bits above the field are not masked off either: 2**64 + (2**64 - 1) is refused the same way.
        (bool okHigh, bytes memory reasonHigh) =
            address(periphery).call(_withWord(create, offsets[0], bytes32((uint256(1) << 64) | RATE_MAX)));
        assertFalse(okHigh, "dirty high bits rejected");
        assertEq(reasonHigh.length, 0, "ABI decoder revert, no custom error");

        // A raw forward carrying 2**64 fails inside the extension's decoder and the error passes through Core and
        // the locker unchanged; the lock leaves nothing behind.
        MaliciousLocker raw = new MaliciousLocker(ICore(CORE));
        bytes memory payload = abi.encode(ZERO_SEED_LAUNCH_CREATE, p);
        uint256 payloadOffset = _wordOffset(payload, word, 0);
        (bool okRaw, bytes memory reasonRaw) = address(raw)
            .call(
                abi.encodeCall(
                    raw.forwardRaw, (address(launch), _withWord(payload, payloadOffset, bytes32(uint256(1) << 64)))
                )
            );
        assertFalse(okRaw, "100% rejected by a raw forward");
        assertEq(reasonRaw.length, 0, "ABI decoder revert, no custom error");

        // The unmodified calldata, 2**64 - 1 in both fields, creates the launch.
        vm.prank(creator);
        (bool okMax, bytes memory result) = address(periphery).call(create);
        assertTrue(okMax, "2**64 - 1 accepted");
        IZeroSeedLaunch.Installation memory inst = abi.decode(result, (IZeroSeedLaunch.Installation));
        _assertSchedule(inst.poolKey.toPoolId(), RATE_MAX, RATE_MAX, DURATION);
        // And the same payload forwarded by an arbitrary locker creates that locker's own launch at the maximum.
        bytes memory forwarded = raw.forwardRaw(address(launch), payload);
        IZeroSeedLaunch.Installation memory rawInst = abi.decode(forwarded, (IZeroSeedLaunch.Installation));
        IZeroSeedLaunch.Launch memory l = launch.getLaunch(rawInst.poolKey.toPoolId());
        assertEq(l.controller, address(raw), "raw locker is the controller");
        assertEq(l.initialFee, RATE_MAX, "raw forward initial fee");
        assertEq(l.finalFee, RATE_MAX, "raw forward final fee");
        assertTrue(rawInst.token != inst.token, "namespaced by controller");
    }

    /// @dev Offset of the first word-aligned (from `from`) occurrence of `word`.
    function _wordOffset(bytes memory data, bytes32 word, uint256 from) private pure returns (uint256) {
        for (uint256 i = from; i + 32 <= data.length; i += 32) {
            bytes32 w;
            assembly ("memory-safe") {
                w := mload(add(add(data, 32), i))
            }
            if (w == word) return i;
        }
        revert("word not found");
    }

    function _withWord(bytes memory data, uint256 offset, bytes32 word) private pure returns (bytes memory copy) {
        copy = bytes.concat(data);
        assembly ("memory-safe") {
            mstore(add(add(copy, 32), offset), word)
        }
    }

    /// @dev Executed swaps at every study rate, the maximum included, on launches created through the periphery:
    /// one raw quote unit, one whole quote unit exact-in, the same net amount exact-out, and a sell of everything
    /// held, with the ledger and conservation checked after each.
    function _matrix(bool tokenIs0, uint8 quoteDecimals) internal {
        uint64[5] memory rates = _rates();
        for (uint256 r; r < rates.length; r++) {
            uint256 snap = vm.snapshotState();
            uint64 rate = rates[r];
            (IZeroSeedLaunch.Installation memory inst,) = _createCurve(tokenIs0, quoteDecimals, DURATION, rate, FEE_03);
            PoolKey memory key = inst.poolKey;
            address token = inst.token;
            string memory tag = string.concat(
                "VEC|highRate|rate=", _label(rate), "|order=", tokenIs0 ? "t0" : "t1", "|dec=18/", _ustr(quoteDecimals)
            );
            vm.warp(START);
            uint256 quoteIn;
            uint256 quoteOut;

            // One raw quote unit: at the maximum rate the gross output is below 2**64, so the net is zero and the
            // whole output is the fee. A positive fill is still a swap: the buyer pays and receives nothing.
            PoolBalanceUpdate u = _buy(key, token, 1, false);
            quoteIn += 1;
            (uint128 feeToken,) = _feeLedger(key, token);
            uint128 net = uint128(-_tokenDelta(key, token, u));
            uint256 gross = uint256(net) + feeToken;
            assertEq(feeToken, (gross * rate + Q64 - 1) >> 64, "fee = ceil(gross * rate)");
            assertEq(net, gross * (Q64 - rate) >> 64, "net = floor(gross * (1 - rate))");
            if (rate == RATE_MAX) assertEq(net, 0, "max rate: one unit buys nothing");
            else assertGt(net, 0, "positive fill");
            console2.log(
                string.concat(tag, "|oneUnit|gross=", _ustr(gross), "|fee=", _ustr(feeToken), "|net=", _ustr(net))
            );

            // One whole quote unit, exact input.
            int128 unit = int128(uint128(10 ** quoteDecimals));
            uint128 feeBefore = feeToken;
            u = _buy(key, token, unit, false);
            quoteIn += uint128(unit);
            (feeToken,) = _feeLedger(key, token);
            net = uint128(-_tokenDelta(key, token, u));
            gross = uint256(net) + (feeToken - feeBefore);
            assertEq(feeToken - feeBefore, (gross * rate + Q64 - 1) >> 64, "fee = ceil(gross * rate)");
            assertEq(net, gross * (Q64 - rate) >> 64, "net = floor(gross * (1 - rate))");
            assertGt(net, 0, "a whole unit fills");
            console2.log(
                string.concat(
                    tag,
                    "|buyExactIn|quoteIn=",
                    _ustr(uint128(unit)),
                    "|gross=",
                    _ustr(gross),
                    "|fee=",
                    _ustr(feeToken - feeBefore),
                    "|net=",
                    _ustr(net)
                )
            );

            // Exact output of that same net amount: the fee-inclusive input is the calculated quote grossed up.
            (, uint128 quoteFeeBefore) = _feeLedger(key, token);
            u = _buy(key, token, int128(net), true);
            assertEq(uint128(-_tokenDelta(key, token, u)), net, "exact-out filled in full");
            (, uint128 quoteFee) = _feeLedger(key, token);
            uint128 paid = uint128(_quoteDelta(key, token, u));
            quoteIn += paid;
            uint128 calc = paid - (quoteFee - quoteFeeBefore);
            uint256 grossUp = uint256(calc) << 64;
            assertEq(paid, grossUp / (Q64 - rate) + (grossUp % (Q64 - rate) == 0 ? 0 : 1), "paid = ceil(calc / (1-r))");
            console2.log(
                string.concat(
                    tag,
                    "|buyExactOut|tokenOut=",
                    _ustr(net),
                    "|calcQuote=",
                    _ustr(calc),
                    "|fee=",
                    _ustr(quoteFee - quoteFeeBefore),
                    "|paid=",
                    _ustr(paid)
                )
            );

            // Immediate exact-input sell of everything held: the sell fee is in quote at the same rate.
            uint256 held = ERC20(token).balanceOf(address(this));
            (, quoteFeeBefore) = _feeLedger(key, token);
            u = _sell(key, token, int128(uint128(held)), false);
            uint128 out = uint128(-_quoteDelta(key, token, u));
            quoteOut += out;
            (, quoteFee) = _feeLedger(key, token);
            uint256 sellGross = uint256(out) + (quoteFee - quoteFeeBefore);
            assertEq(quoteFee - quoteFeeBefore, (sellGross * rate + Q64 - 1) >> 64, "sell fee = ceil(gross * rate)");
            console2.log(
                string.concat(
                    tag,
                    "|sellAll|tokenIn=",
                    _ustr(held),
                    "|grossQuote=",
                    _ustr(sellGross),
                    "|fee=",
                    _ustr(quoteFee - quoteFeeBefore),
                    "|quoteOut=",
                    _ustr(out),
                    "|roundTripLoss=",
                    _ustr(quoteIn - quoteOut)
                )
            );
            (uint256 tokenDust, uint256 quoteDust) = _assertLedger(inst, activeQuote, quoteIn, quoteOut, MAX_DUST);
            console2.log(string.concat(tag, "|dust|token=", _ustr(tokenDust), "|quote=", _ustr(quoteDust)));
            vm.revertToState(snap);
        }
    }

    function test_highRate_token0_18_18() public {
        _matrix(true, 18);
    }

    function test_highRate_token1_18_18_native() public {
        _matrix(false, 18);
    }

    function test_highRate_token0_18_6() public {
        _matrix(true, 6);
    }

    function test_highRate_token1_18_6() public {
        _matrix(false, 6);
    }

    /// @dev Pool state, fee ledger, position liquidity and Core's balance of both assets.
    function _stateDigest(PoolKey memory key, IZeroSeedLaunch.Installation memory inst)
        internal
        view
        returns (bytes32)
    {
        (uint128 f0, uint128 f1) = launch.creatorFees(key);
        PoolId id = key.toPoolId();
        return keccak256(
            abi.encode(
                PoolState.unwrap(ICore(CORE).poolState(id)),
                f0,
                f1,
                ICore(CORE).poolPositions(id, address(launch), inst.positionId).liquidity,
                _balance(key.token0, CORE),
                _balance(key.token1, CORE)
            )
        );
    }

    /// @dev Balances of the two accounts a probe can charge: this contract (ERC-20 payer, output recipient) and the
    /// swapper (native payer).
    function _payerDigest(PoolKey memory key) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                _balance(key.token0, address(this)),
                _balance(key.token1, address(this)),
                _balance(key.token0, address(swapper)),
                _balance(key.token1, address(swapper))
            )
        );
    }

    /// @dev The atomicity proof for one rejected forwarded swap, taken from the live EVM state right after the
    /// revert and before any snapshot is restored: pool state, fee ledger, position and Core's balances are exactly
    /// as before the call, neither payer was charged, Core holds no lock and no debt for the probe's lock, and a
    /// fresh valid swap on the same launch still settles with the ledger conserved.
    function _assertRejectedSwapLeftNothing(
        PoolKey memory key,
        IZeroSeedLaunch.Installation memory inst,
        bytes32 stateBefore,
        bytes32 payerBefore
    ) internal {
        assertEq(_stateDigest(key, inst), stateBefore, "rejected swap: pool, ledger, position, Core balances");
        assertEq(_payerDigest(key), payerBefore, "rejected swap: payers not charged");
        (uint256 locker, uint256 nonzeroDebtCount, uint256 debt0, uint256 debt1) = coreLockState(key);
        assertEq(locker, 0, "rejected swap: no lock left in Core");
        assertEq(nonzeroDebtCount, 0, "rejected swap: no nonzero-debt count left");
        assertEq(debt0, 0, "rejected swap: no token0 debt left");
        assertEq(debt1, 0, "rejected swap: no token1 debt left");
        PoolBalanceUpdate u = _buy(key, inst.token, 1e18, false);
        assertGt(uint128(-_tokenDelta(key, inst.token, u)), 0, "a valid swap settles after the rejected one");
        _assertLedger(inst, activeQuote, 1e18, 0, MAX_DUST);
    }

    /// @dev Probes an exact-output buy of `want` tokens: success with the calculated quote (paid minus fee), or the
    /// revert selector together with the atomicity checks above, all taken before the snapshot is restored. Only
    /// then is the state restored so every probe starts from the same point.
    function _probeExactOut(PoolKey memory key, IZeroSeedLaunch.Installation memory inst, uint128 want)
        internal
        returns (bool ok, bytes4 selector, uint128 calc, uint128 paid)
    {
        address token = inst.token;
        uint256 snap = vm.snapshotState();
        bytes32 stateBefore = _stateDigest(key, inst);
        bytes32 payerBefore = _payerDigest(key);
        (, uint128 feeBefore) = _feeLedger(key, token);
        try swapper.forwardSwap(
            key, createSwapParameters(SqrtRatio.wrap(0), -int128(want), key.token1 == token, 0)
        ) returns (
            PoolBalanceUpdate u
        ) {
            ok = true;
            paid = uint128(_quoteDelta(key, token, u));
            (, uint128 feeAfter) = _feeLedger(key, token);
            calc = paid - (feeAfter - feeBefore);
            // The digests are sensitive: an executed probe moves both of them.
            assertTrue(_stateDigest(key, inst) != stateBefore, "executed swap changed state");
            assertTrue(_payerDigest(key) != payerBefore, "executed swap charged the payer");
        } catch (bytes memory reason) {
            selector = bytes4(reason);
            _assertRejectedSwapLeftNothing(key, inst, stateBefore, payerBefore);
        }
        vm.revertToState(snap);
    }

    /// @dev At the maximum rate the fee-inclusive input is calc * 2**64, so both representation limits are inside
    /// the fixture's inventory: calc <= 2**63 - 1 executes, calc in [2**63, 2**64 - 1] passes the uint128 helper
    /// and fails the signed conversion, calc >= 2**64 fails the helper. Everything reverts atomically: pool state,
    /// fee ledger, Core balances, the position and the payers are the same right after every rejected probe, Core
    /// holds no lock or debt for it, and a valid swap still settles; all checked in `_probeExactOut` on the live
    /// state before the snapshot is restored (the snapshot only resets the harness between probes).
    function test_exactOut_executedBounds_maxRate_token0_erc20() public {
        _exactOutBounds(true);
    }

    function test_exactOut_executedBounds_maxRate_token1_native() public {
        _exactOutBounds(false);
    }

    function _exactOutBounds(bool tokenIs0) internal {
        (IZeroSeedLaunch.Installation memory inst,) = _createCurve(tokenIs0, 18, DURATION, RATE_MAX, FEE_03);
        PoolKey memory key = inst.poolKey;
        assertEq(key.token0 == NATIVE_TOKEN_ADDRESS, !tokenIs0, "native order");
        vm.warp(START);
        bytes32 ledgerBefore = _stateDigest(key, inst);
        // The transient reads behind the rollback proof are live: inside an open lock the locker word is nonzero
        // (id 0 stored as 1 with the locker's address) and outside it everything is zero.
        (uint256 openLocker, uint256 openCount) = new LockObserver(ICore(CORE)).observe(address(this), key);
        assertEq(openLocker >> 160, 1, "lock id 0 is open as 1");
        assertEq(openCount, 0, "no debt inside an idle lock");
        (uint256 idleLocker, uint256 idleCount, uint256 idle0, uint256 idle1) = coreLockState(key);
        assertEq(idleLocker | idleCount | idle0 | idle1, 0, "nothing open before the probes");

        uint128 lo = 1;
        uint128 hi = inst.installedSupply;
        while (lo < hi) {
            uint128 mid = lo + (hi - lo + 1) / 2;
            (bool ok,,,) = _probeExactOut(key, inst, mid);
            if (ok) lo = mid;
            else hi = mid - 1;
        }
        uint128 lastValid = lo;
        (bool okLast,, uint128 calcLast, uint128 paidLast) = _probeExactOut(key, inst, lastValid);
        assertTrue(okLast, "last valid executes");
        assertEq(uint256(paidLast), uint256(calcLast) << 64, "paid = calc * 2**64");
        // One more token unit raises the calculated quote by at most one raw unit at these prices, so the last
        // executable request sits exactly on the signed bound.
        assertEq(calcLast, uint128(type(int128).max) >> 64, "calc = 2**63 - 1 exactly");
        (bool okNext, bytes4 selNext,,) = _probeExactOut(key, inst, lastValid + 1);
        assertFalse(okNext, "first invalid reverts");
        assertEq(selNext, SafeCastLib.Overflow.selector, "signed int128 overflow, helper succeeded");
        assertEq(_stateDigest(key, inst), ledgerBefore, "harness: snapshot restored between probes");

        lo = lastValid + 1;
        hi = inst.installedSupply;
        while (lo < hi) {
            uint128 mid = lo + (hi - lo + 1) / 2;
            (, bytes4 sel,,) = _probeExactOut(key, inst, mid);
            if (sel == SafeCastLib.Overflow.selector) lo = mid;
            else hi = mid - 1;
        }
        (, bytes4 selHelperLast,,) = _probeExactOut(key, inst, lo);
        (, bytes4 selHelperFirst,,) = _probeExactOut(key, inst, lo + 1);
        assertEq(selHelperLast, SafeCastLib.Overflow.selector, "helper still succeeds");
        assertEq(selHelperFirst, AmountBeforeFeeOverflow.selector, "helper uint128 overflow");
        assertEq(_stateDigest(key, inst), ledgerBefore, "harness: snapshot restored after the last probe");
        _assertLedger(inst, activeQuote, 0, 0, 1);
        console2.log(
            string.concat(
                "VEC|exactOutBounds|rate=max|order=",
                tokenIs0 ? "t0" : "t1(native)",
                "|lastValidTokenOut=",
                _ustr(lastValid),
                "|calc=",
                _ustr(calcLast),
                "|paid=",
                _ustr(paidLast),
                "|firstSignedOverflowTokenOut=",
                _ustr(lastValid + 1),
                "|lastSignedOverflowTokenOut=",
                _ustr(lo),
                "|firstHelperOverflowTokenOut=",
                _ustr(lo + 1)
            )
        );
    }

    /// @dev The test router against a normally created maximum-rate launch with a plain ERC-20 quote (token0
    /// order): minimum output, deadline, partial fill and insufficient balance.
    function test_router_maxRate_minOut_deadline_partial_balance() public {
        ROUTER = address(new LaunchTestRouter(ICore(CORE)));
        (IZeroSeedLaunch.Installation memory inst,) = _createCurve(true, 18, DURATION, RATE_MAX, FEE_03);
        ERC20(activeQuote).approve(ROUTER, type(uint256).max);
        ERC20(inst.token).approve(ROUTER, type(uint256).max);
        PoolKey memory key = inst.poolKey;
        vm.warp(START);
        uint32 nowTs = uint32(block.timestamp);

        int256 quotedWei = _routerQuote(_route(key, activeQuote, inst.token, 1, 0, false, nowTs));
        assertEq(quotedWei, 0, "one wei quotes nothing at the maximum rate");
        (bool ok,,) = _call(_route(key, activeQuote, inst.token, 1, 1, false, nowTs));
        assertFalse(ok, "zero fill refused with minOut 1");
        (bool okZero, int256 paidZero, int256 gotZero) = _call(_route(key, activeQuote, inst.token, 1, 0, false, nowTs));
        assertTrue(okZero, "zero fill accepted with minOut 0");
        assertEq(gotZero, 0, "nothing received");
        assertEq(paidZero, 1, "one wei paid");

        int256 quoted = _routerQuote(_route(key, activeQuote, inst.token, 1e18, 0, false, nowTs));
        assertGt(quoted, 0, "positive net");
        (ok,,) = _call(_route(key, activeQuote, inst.token, 1e18, int128(quoted + 1), false, nowTs));
        assertFalse(ok, "minOut quote+1 refused");
        (ok,,) = _call(_route(key, activeQuote, inst.token, 1e18, int128(quoted), false, nowTs - 1));
        assertFalse(ok, "expired deadline refused");
        (bool okExact, int256 paid, int256 got) =
            _call(_route(key, activeQuote, inst.token, 1e18, int128(quoted), false, nowTs));
        assertTrue(okExact, "minOut == quote, inclusive deadline");
        assertEq(got, quoted, "quote == execution");
        assertEq(paid, 1e18, "full input");

        (ok,,) = _call(_route(key, activeQuote, inst.token, 1e30, 0, false, nowTs));
        assertFalse(ok, "full fill beyond inventory refused");
        (bool okPartial, int256 paidPartial,) = _call(_route(key, activeQuote, inst.token, 1e30, 0, true, nowTs));
        assertTrue(okPartial, "partial fill");
        assertLt(paidPartial, 1e30, "unused input refunded");

        address poor = makeAddr("poor");
        vm.prank(poor);
        ERC20(activeQuote).approve(ROUTER, type(uint256).max);
        bytes memory route = _route(key, activeQuote, inst.token, 1e18, 0, false, nowTs);
        vm.prank(poor);
        (bool okPoor,) = ROUTER.call(route);
        assertFalse(okPoor, "insufficient balance refused");
    }

    /// @dev The test router against a normally created maximum-rate launch with native ETH (token1 order): every
    /// buy attaches `value`, the router pays Core only the actual input and refunds the rest, a one-wei buy nets
    /// nothing and costs exactly one wei, an exact-output buy pays calc * 2**64 and refunds the unspent value, a
    /// sell pays ETH out net of the maximum-rate quote fee, and the partial fill beyond inventory refunds the rest.
    function test_router_maxRate_native_value_refund_minOut_partial() public {
        ROUTER = address(new LaunchTestRouter(ICore(CORE)));
        (IZeroSeedLaunch.Installation memory inst,) = _createCurve(false, 18, DURATION, RATE_MAX, FEE_03);
        assertEq(activeQuote, NATIVE_TOKEN_ADDRESS, "native quote");
        ERC20(inst.token).approve(ROUTER, type(uint256).max);
        PoolKey memory key = inst.poolKey;
        vm.warp(START);
        uint32 nowTs = uint32(block.timestamp);
        vm.deal(address(this), 1e30 + 1e24);
        uint256 quoteIn;
        uint256 quoteOut;

        // One wei: nets nothing, refused with any positive minimum, costs exactly one wei with none.
        (bool ok,,) = _callWithValue(_route(key, activeQuote, inst.token, 1, 1, false, nowTs), 1);
        assertFalse(ok, "zero fill refused with minOut 1");
        uint256 ethBefore = address(this).balance;
        (bool okZero, int256 paidZero, int256 gotZero) =
            _callWithValue(_route(key, activeQuote, inst.token, 1, 0, false, nowTs), 1);
        assertTrue(okZero, "zero fill accepted with minOut 0");
        assertEq(gotZero, 0, "nothing received");
        assertEq(paidZero, 1, "one wei paid");
        assertEq(ethBefore - address(this).balance, 1, "exactly one wei left the account");
        quoteIn += 1;

        // One whole ETH, exact input, with a surplus attached that comes back.
        int256 quoted = _routerQuote(_route(key, activeQuote, inst.token, 1e18, 0, false, nowTs));
        assertGt(quoted, 0, "positive net");
        (ok,,) = _callWithValue(_route(key, activeQuote, inst.token, 1e18, int128(quoted + 1), false, nowTs), 1e18);
        assertFalse(ok, "minOut quote+1 refused");
        ethBefore = address(this).balance;
        (bool okExact, int256 paid, int256 got) =
            _callWithValue(_route(key, activeQuote, inst.token, 1e18, int128(quoted), false, nowTs), 2e18);
        assertTrue(okExact, "minOut == quote");
        assertEq(got, quoted, "quote == execution");
        assertEq(paid, 1e18, "full input");
        assertEq(ethBefore - address(this).balance, 1e18, "surplus value refunded");
        assertEq(ERC20(inst.token).balanceOf(address(this)), uint256(got), "tokens received");
        quoteIn += 1e18;

        // Exact output of 1e9 raw tokens: paid = calc * 2**64, unspent value refunded.
        int256 calcOut = _routerQuote(_route(key, inst.token, activeQuote, -1e9, type(int128).min, false, nowTs));
        uint256 paidOut = uint256(-calcOut);
        (, uint128 quoteFeeBefore) = _feeLedger(key, inst.token);
        ethBefore = address(this).balance;
        (bool okOut, int256 specOut, int256 calcExec) =
            _callWithValue(_route(key, inst.token, activeQuote, -1e9, type(int128).min, false, nowTs), paidOut + 1e18);
        assertTrue(okOut, "exact output");
        assertEq(specOut, -1e9, "exact output filled");
        assertEq(calcExec, calcOut, "exact-out quote == execution");
        assertEq(ethBefore - address(this).balance, paidOut, "only the fee-inclusive input left the account");
        (, uint128 quoteFee) = _feeLedger(key, inst.token);
        uint256 calcQuote = paidOut - (quoteFee - quoteFeeBefore);
        assertEq(paidOut, calcQuote << 64, "paid = calc * 2**64");
        quoteIn += paidOut;

        // Sell everything: the quote output is net of the maximum-rate fee, paid out in ETH. Below 2**64 raw
        // units of gross quote the whole output is the fee, so this sell pays nothing out and the fee is the gross.
        uint256 held = ERC20(inst.token).balanceOf(address(this));
        (, quoteFeeBefore) = _feeLedger(key, inst.token);
        ethBefore = address(this).balance;
        (bool okSell,, int256 gotSell) =
            _call(_route(key, inst.token, activeQuote, int128(uint128(held)), 0, false, nowTs));
        assertTrue(okSell, "sell");
        assertEq(address(this).balance - ethBefore, uint256(gotSell), "ETH paid out");
        (, quoteFee) = _feeLedger(key, inst.token);
        uint256 sellGross = uint256(gotSell) + (quoteFee - quoteFeeBefore);
        assertGt(sellGross, 0, "the sell has a gross quote output");
        assertEq(uint256(gotSell), sellGross >> 64, "sell net = floor(gross / 2**64)");
        assertEq(quoteFee - quoteFeeBefore, sellGross - (sellGross >> 64), "sell fee = gross - net");
        quoteOut += uint256(gotSell);

        // Beyond the inventory: refused as a full fill, partially filled and refunded otherwise.
        (ok,,) = _callWithValue(_route(key, activeQuote, inst.token, 1e30, 0, false, nowTs), 1e30);
        assertFalse(ok, "full fill beyond inventory refused");
        ethBefore = address(this).balance;
        (bool okPartial, int256 paidPartial,) =
            _callWithValue(_route(key, activeQuote, inst.token, 1e30, 0, true, nowTs), 1e30);
        assertTrue(okPartial, "partial fill");
        assertLt(paidPartial, 1e30, "unused input refunded");
        assertEq(ethBefore - address(this).balance, uint256(paidPartial), "only the fill is paid in ETH");
        quoteIn += uint256(paidPartial);
        assertEq(address(launch).balance, 0, "extension holds no ETH");
        assertEq(address(periphery).balance, 0, "periphery holds no ETH");
        assertEq(ROUTER.balance, 0, "router holds no ETH");
        _assertLedger(inst, activeQuote, quoteIn, quoteOut, MAX_DUST);
    }

    /// @dev Claims at the maximum rate, both orders: the owner receives exactly the ledger in both assets, native
    /// ETH by Core's plain call, the ledger is zero afterwards, the position is untouched, and a second claim pays
    /// nothing. The ledger equals the sum of the `LaunchSwapped.feeAmount` values.
    function test_claim_maxRate_bothOrders() public {
        for (uint256 o; o < 2; o++) {
            uint256 snap = vm.snapshotState();
            bool tokenIs0 = o == 0;
            (IZeroSeedLaunch.Installation memory inst,) = _createCurve(tokenIs0, 18, DURATION, RATE_MAX, FEE_03);
            PoolKey memory key = inst.poolKey;
            vm.warp(START);
            vm.recordLogs();
            PoolBalanceUpdate u = _buy(key, inst.token, 1e18, false);
            uint128 bought = uint128(-_tokenDelta(key, inst.token, u));
            _buy(key, inst.token, int128(bought / 2), true);
            _sell(key, inst.token, int128(bought), false);
            (uint128 sum0, uint128 sum1) = _sumSwapFees(vm.getRecordedLogs());
            (uint128 f0, uint128 f1) = launch.creatorFees(key);
            assertEq(f0, sum0, "ledger0 = sum of emitted fees");
            assertEq(f1, sum1, "ledger1 = sum of emitted fees");
            assertGt(f0, 0, "token-side fee collected");
            assertGt(f1, 0, "quote-side fee collected");
            (uint128 p0, uint128 p1) = _principal(inst);

            uint256 before0 = _balance(key.token0, feeRecipient);
            uint256 before1 = _balance(key.token1, feeRecipient);
            vm.prank(creator);
            (uint128 a0, uint128 a1) = periphery.claimFees(key, feeRecipient);
            assertEq(a0, f0, "claimed0");
            assertEq(a1, f1, "claimed1");
            assertEq(_balance(key.token0, feeRecipient) - before0, f0, "paid0");
            assertEq(_balance(key.token1, feeRecipient) - before1, f1, "paid1");
            (f0, f1) = launch.creatorFees(key);
            assertEq(f0 + f1, 0, "ledger cleared");
            (uint128 q0, uint128 q1) = _principal(inst);
            assertEq(q0, p0, "principal0 untouched");
            assertEq(q1, p1, "principal1 untouched");
            vm.prank(creator);
            (a0, a1) = periphery.claimFees(key, feeRecipient);
            assertEq(a0 + a1, 0, "nothing left to claim");
            vm.revertToState(snap);
        }
    }

    function _sumSwapFees(Vm.Log[] memory logs) internal view returns (uint128 sum0, uint128 sum1) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(launch) || logs[i].topics[0] != IZeroSeedLaunch.LaunchSwapped.selector) {
                continue;
            }
            (,, uint64 rate, uint128 feeAmount, bool feeIsToken1) =
                abi.decode(logs[i].data, (int128, int128, uint64, uint128, bool));
            assertEq(rate, RATE_MAX, "swapped at the maximum rate");
            if (feeIsToken1) sum1 += feeAmount;
            else sum0 += feeAmount;
        }
    }
}

/// @dev Gas and bytecode: the fixed-base table against the previous variable-base exponentiation, isolated and
/// inside forwarded swaps at the window's endpoints and interior, both token orders including native settlement.
contract FeeCurveGasTest is FeeCurveBase {
    using CoreLib for ICore;

    function _measure(bytes memory call_) internal returns (uint256 used) {
        address target = address(probe);
        uint256 before = gasleft();
        (bool ok,) = target.call(call_);
        used = before - gasleft();
        require(ok, "probe");
    }

    /// @dev Isolated math as a warm external call, minus the identical identity call, so only the arithmetic
    /// remains.
    function test_gas_isolatedMath_tableVersusLegacy() public {
        uint256[6] memory elapsed = [uint256(1), 7, 600, 1800, 3599, 4095];
        // Warm the probe's code and the call targets before measuring.
        _measure(abi.encodeCall(probe.identity, (RATE_50, FEE_03, DURATION, 1800)));
        _measure(abi.encodeCall(probe.identityLegacy, (RATE_50, FEE_03, LEGACY_FACTOR, DURATION, 1800)));
        _measure(abi.encodeCall(probe.fixedBase, (RATE_50, FEE_03, DURATION, 1800)));
        _measure(abi.encodeCall(probe.legacy, (RATE_50, FEE_03, LEGACY_FACTOR, DURATION, 1800)));
        uint256 identity = _measure(abi.encodeCall(probe.identity, (RATE_50, FEE_03, DURATION, 1800)));
        uint256 identityLegacy =
            _measure(abi.encodeCall(probe.identityLegacy, (RATE_50, FEE_03, LEGACY_FACTOR, DURATION, 1800)));
        for (uint256 i; i < elapsed.length; i++) {
            uint256 table = _measure(abi.encodeCall(probe.fixedBase, (RATE_50, FEE_03, DURATION, elapsed[i])));
            uint256 legacy =
                _measure(abi.encodeCall(probe.legacy, (RATE_50, FEE_03, LEGACY_FACTOR, DURATION, elapsed[i])));
            assertGe(table, identity, "warm");
            assertGe(legacy, identityLegacy, "warm");
            // At or after the window both return `finalFee` before any arithmetic.
            if (elapsed[i] < DURATION) {
                assertLt(table - identity, legacy - identityLegacy, "table cheaper than square-and-multiply");
            }
            console2.log(
                string.concat(
                    "GAS|feeMath|elapsed=",
                    _ustr(elapsed[i]),
                    "|table=",
                    _ustr(table - identity),
                    "|legacy=",
                    _ustr(legacy - identityLegacy)
                )
            );
        }
        _measure(abi.encodeCall(probe.decay, (3599)));
        uint256 decayOnly = _measure(abi.encodeCall(probe.decay, (3599)));
        console2.log(string.concat("GAS|decayQ128(3599)|warmCall=", _ustr(decayOnly)));
    }

    function test_bytecodeSizes() public view {
        bytes memory extension = address(launch).code;
        bytes memory periph = address(periphery).code;
        console2.log(string.concat("SIZE|ZeroSeedLaunch.runtime=", _ustr(extension.length)));
        console2.log(string.concat("SIZE|ZeroSeedLaunchPeriphery.runtime=", _ustr(periph.length)));
        console2.log(
            string.concat(
                "SIZE|ZeroSeedLaunch.initcode=", _ustr(vm.getCode("ZeroSeedLaunch.sol:ZeroSeedLaunch").length)
            )
        );
        console2.log(
            string.concat(
                "SIZE|ZeroSeedLaunchPeriphery.initcode=",
                _ustr(vm.getCode("ZeroSeedLaunchPeriphery.sol:ZeroSeedLaunchPeriphery").length)
            )
        );
        assertLe(extension.length, 24576, "extension fits");
        assertLe(periph.length, 24576, "periphery fits");
        // Deployed runtime hashes with the immutables resolved (CORE at the canonical address, the extension at its
        // callpoint address), reproducible from this test alone.
        console2.log(string.concat("HASH|ZeroSeedLaunch.runtime.keccak256=", vm.toString(address(launch).codehash)));
        console2.log(
            string.concat("HASH|ZeroSeedLaunchPeriphery.runtime.keccak256=", vm.toString(address(periphery).codehash))
        );
        console2.log(
            string.concat(
                "HASH|ZeroSeedLaunch.initcode.keccak256=",
                vm.toString(keccak256(vm.getCode("ZeroSeedLaunch.sol:ZeroSeedLaunch")))
            )
        );
        console2.log(
            string.concat(
                "HASH|ZeroSeedLaunchPeriphery.initcode.keccak256=",
                vm.toString(keccak256(vm.getCode("ZeroSeedLaunchPeriphery.sol:ZeroSeedLaunchPeriphery")))
            )
        );
    }

    /// @dev Warm forwarded swaps at t = start (initial fee, no table walk), interior and final, exact input and
    /// exact output, both orders; the native order settles ETH through Core.
    function test_gas_swapsAcrossWindow() public {
        for (uint256 o; o < 2; o++) {
            uint256 snap = vm.snapshotState();
            bool tokenIs0 = o == 0;
            (IZeroSeedLaunch.Installation memory inst,) = _createCurve(tokenIs0, 18, DURATION, RATE_50, FEE_03);
            string memory tag = string.concat("GAS|swap|order=", tokenIs0 ? "t0" : "t1(native)");
            uint256[4] memory at = [uint256(0), 1, 1800, 3600];
            vm.warp(START);
            _buy(inst.poolKey, inst.token, 1e18, false); // warm the pool and the ledger
            for (uint256 i; i < at.length; i++) {
                vm.warp(START + at[i]);
                uint256 g = gasleft();
                _buy(inst.poolKey, inst.token, 1e18, false);
                uint256 exactIn = g - gasleft();
                g = gasleft();
                _buy(inst.poolKey, inst.token, 1e20, true);
                uint256 exactOut = g - gasleft();
                g = gasleft();
                _sell(inst.poolKey, inst.token, 1e20, false);
                uint256 sell = g - gasleft();
                console2.log(
                    string.concat(
                        tag,
                        "|t=start+",
                        _ustr(at[i]),
                        "|buyExactIn=",
                        _ustr(exactIn),
                        "|buyExactOut=",
                        _ustr(exactOut),
                        "|sellExactIn=",
                        _ustr(sell)
                    )
                );
            }
            vm.revertToState(snap);
        }
    }
}
