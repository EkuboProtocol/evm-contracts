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
import {decayedFee, MAX_DECAY_PRODUCT} from "../../src/math/feeDecay.sol";
import {tickToSqrtRatio, InvalidTick} from "../../src/math/ticks.sol";
import {MAX_TICK_MAGNITUDE} from "../../src/math/constants.sol";
import {ZeroSeedLaunchBase} from "./ZeroSeedLaunch.t.sol";
import {MaliciousLocker} from "./ZeroSeedLaunchAdversarial.t.sol";
import {LaunchTestRouter} from "../LaunchTestRouter.sol";

uint256 constant Q64 = 1 << 64;

/// @dev External entry points so the isolated math can be measured as a call and pure reverts can be expected.
contract FeeMathProbe {
    function fee(uint64 initialFee, uint64 finalFee, uint64 decayRateX32, uint256 elapsed)
        external
        pure
        returns (uint64)
    {
        return decayedFee(initialFee, finalFee, decayRateX32, elapsed);
    }

    function factor(int32 tick) external pure returns (uint256) {
        return tickToSqrtRatio(tick).toFixed();
    }

    function identity(uint64 initialFee, uint64, uint64, uint256) external pure returns (uint64) {
        return initialFee;
    }

    function beforeFee(uint128 afterFee, uint64 fee_) external pure returns (uint128) {
        return amountBeforeFee(afterFee, fee_);
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
    /// @dev floor(2**64 * 999 / 1000), the 99.9% example rate.
    uint64 constant RATE_999 = 18428297329635842064;
    /// @dev Example decay rates in Q32.32: exactly 2 ticks/s, 1/4 tick/s, floor(0.1 * 2**32) = 0.0999999999 ticks/s,
    /// and the slowest and fastest encodable.
    uint64 constant DECAY_2 = 2 << 32;
    uint64 constant DECAY_QUARTER = 1 << 30;
    uint64 constant DECAY_TENTH = 429496729;
    uint64 constant DECAY_MIN = 1;
    uint64 constant DECAY_MAX = type(uint64).max;

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
    function _createCurve(bool tokenIs0, uint8 quoteDecimals, uint64 decayRateX32, uint64 initialFee, uint64 finalFee)
        internal
        returns (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p)
    {
        _quote(tokenIs0, quoteDecimals);
        p = _parameters(quoteDecimals == 18 ? ASK_18_18 : ASK_18_6, REQUESTED_SUPPLY, decayRateX32);
        p.initialFee = initialFee;
        p.finalFee = finalFee;
        _bind(p, creator);
        vm.prank(creator);
        inst = periphery.create(p);
        MintableERC20(inst.token).approve(address(swapper), type(uint256).max);
        _assertSchedule(inst.poolKey.toPoolId(), initialFee, finalFee, decayRateX32);
    }

    /// @dev The record holds the requested schedule, the live rate at the start is the requested initial rate and the
    /// saturated rate is the requested floor.
    function _assertSchedule(PoolId id, uint64 initialFee, uint64 finalFee, uint64 decayRateX32) internal view {
        IZeroSeedLaunch.Launch memory l = launch.getLaunch(id);
        assertEq(l.controller, address(periphery), "controller");
        assertEq(l.initialFee, initialFee, "stored initial fee");
        assertEq(l.finalFee, finalFee, "stored final fee");
        assertEq(l.decayRateX32, decayRateX32, "stored decay rate");
        assertEq(l.tradingStart, START, "stored start");
        assertEq(launch.feeAt(id, START), initialFee, "rate at start");
        if (decayRateX32 != 0) {
            assertEq(launch.feeAt(id, START + _saturationSecond(decayRateX32) + 1), finalFee, "rate after saturation");
        }
        assertEq(launch.feeAt(id, type(uint256).max), decayRateX32 == 0 ? initialFee : finalFee, "rate at the end");
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

/// @dev Pure schedule properties of the tick-rate decay: the formula against the tick helper, the saturation guard
/// before the helper's range (including the nonzero residual at the minimum tick that the guard, not a clamp,
/// resolves), tick stepping at fractional rates, rate and fee extremes, fuzzed bounds and monotonicity over the
/// whole uint64 rate and uint256 elapsed domain, Python-pinned values and digests, and the one-day default.
contract FeeCurveMathTest is FeeCurveBase {
    uint256 constant Q128 = 1 << 128;

    /// @dev The guard constant is `(MAX_TICK_MAGNITUDE + 1) * 2**32 - 1`: the last product whose magnitude the helper
    /// supports. The helper itself reverts one tick beyond the maximum, so saturation must precede the call.
    function test_guard_matchesHelperRange() public {
        assertEq(MAX_DECAY_PRODUCT, (uint256(MAX_TICK_MAGNITUDE) + 1 << 32) - 1, "guard constant");
        assertEq(MAX_DECAY_PRODUCT >> 32, MAX_TICK_MAGNITUDE, "last supported magnitude");
        assertEq(MAX_TICK_MAGNITUDE, 88722835, "pinned tick range");
        assertLt(MAX_DECAY_PRODUCT, 1 << 59, "product bound");
        probe.factor(-int32(MAX_TICK_MAGNITUDE));
        vm.expectRevert(abi.encodeWithSelector(InvalidTick.selector, -int32(MAX_TICK_MAGNITUDE) - 1));
        probe.factor(-int32(MAX_TICK_MAGNITUDE) - 1);
        // Exactly 2**128 at magnitude zero: a fee below one accumulated tick is the initial fee.
        assertEq(probe.factor(0), Q128, "unit factor");
        // At the minimum tick the factor is still above 2**64, so a full-span excess leaves one raw unit; the guard
        // (not a clamp to the minimum tick) is what makes the saturated schedule return exactly `finalFee`.
        uint256 minimum = probe.factor(-int32(MAX_TICK_MAGNITUDE));
        assertEq(minimum, 18447191164202170524, "minimum factor (Python)");
        assertEq((uint256(RATE_MAX) * minimum) >> 128, 1, "residual at the minimum tick");
    }

    /// @dev Last supported second `S = MAX_DECAY_PRODUCT / rate`: the fee at `S` is computed, at `S + 1` and at every
    /// larger elapsed, `type(uint256).max` included, it is the floor, with no revert and no overflow of rate * time.
    function test_saturation_boundaries() public pure {
        uint64[6] memory rates = [DECAY_RATE, DECAY_RATE_600, DECAY_2, DECAY_QUARTER, DECAY_MIN, DECAY_MAX];
        uint256[6] memory saturation = [uint256(5529597), 38399, 44361417, 354891343, MAX_DECAY_PRODUCT, 0];
        for (uint256 i; i < rates.length; i++) {
            uint256 s = _saturationSecond(rates[i]);
            assertEq(s, saturation[i], "saturation second (Python)");
            // At S the magnitude is within range (<= MAX_TICK_MAGNITUDE); at S + 1 it is beyond it.
            assertLe((uint256(rates[i]) * s) >> 32, MAX_TICK_MAGNITUDE, "S in range");
            assertGt((uint256(rates[i]) * (s + 1)) >> 32, MAX_TICK_MAGNITUDE, "S + 1 out of range");
            // Full-span launch: where S lands exactly on the minimum tick the residual is one raw unit (not zero);
            // from S + 1 the fee is exactly the floor.
            uint64 atS = decayedFee(RATE_MAX, 0, rates[i], s);
            if ((uint256(rates[i]) * s) >> 32 == MAX_TICK_MAGNITUDE) assertEq(atS, 1, "residual at the minimum tick");
            else if (s == 0) assertEq(atS, RATE_MAX, "fastest rate: the initial fee at the start");
            else assertLe(atS, 1, "residual at S");
            assertEq(decayedFee(RATE_MAX, 0, rates[i], s + 1), 0, "saturated to zero");
            assertEq(decayedFee(RATE_MAX, FEE_03, rates[i], s + 1), FEE_03, "saturated to the floor");
            assertEq(decayedFee(RATE_MAX, FEE_03, rates[i], type(uint64).max), FEE_03, "uint64 elapsed");
            assertEq(decayedFee(RATE_MAX, FEE_03, rates[i], type(uint256).max), FEE_03, "uint256 elapsed");
        }
        // The slowest rate accumulates its first tick after 2**32 s and reaches the minimum tick exactly at S.
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_MIN, (1 << 32) - 1), RATE_50, "below one tick");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_MIN, 1 << 32), 9223367452842311500, "one tick (Python)");
        assertEq(decayedFee(RATE_MAX, 0, DECAY_MIN, MAX_DECAY_PRODUCT), 1, "minimum tick residual");
        // The fastest rate saturates within the first second.
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_MAX, 0), RATE_50, "start");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_MAX, 1), FEE_03, "one second");
        // A zero rate never moves.
        assertEq(decayedFee(RATE_50, FEE_03, 0, 1), RATE_50, "zero rate");
        assertEq(decayedFee(RATE_50, FEE_03, 0, type(uint256).max), RATE_50, "zero rate forever");
    }

    /// @dev Fractional rates step the fee only when a whole tick has accumulated: 1/4 tick/s moves every 4 s, floor(0.1
    /// * 2**32) slightly below one tick per 10 s, so its first step is at 11 s. One tick of decay is exactly
    /// `(I - F) * (2**128 - tickToSqrtRatio(-1)) / 2**128` floored.
    function test_tickSteps_fractionalRates() public pure {
        uint64 oneTick = 9223367452842311500;
        uint64 twoTicks = 9223362868832139196;
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_QUARTER, 1), RATE_50, "1/4: t=1");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_QUARTER, 3), RATE_50, "1/4: t=3");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_QUARTER, 4), oneTick, "1/4: t=4");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_QUARTER, 7), oneTick, "1/4: t=7");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_QUARTER, 8), twoTicks, "1/4: t=8");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_TENTH, 10), RATE_50, "0.1: t=10 (rate rounded down)");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_TENTH, 11), oneTick, "0.1: t=11");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_TENTH, 20), oneTick, "0.1: t=20");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_TENTH, 21), twoTicks, "0.1: t=21");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_TENTH, 31), 9223358284824258897, "0.1: t=31");
        // The floor is applied to the remaining excess, so the step down is the ceiling of the removed part.
        uint256 excess = RATE_50 - FEE_03;
        assertEq(oneTick, FEE_03 + ((excess * probe_factor(-1)) >> 128), "one tick");
        assertEq(uint256(RATE_50 - oneTick), excess - ((excess * probe_factor(-1)) >> 128), "step");
        // The default accumulates 16 whole ticks per second (16.045...), so every second steps.
        assertEq((uint256(DECAY_RATE) * 1) >> 32, 16, "default: ticks after 1 s");
        assertEq((uint256(DECAY_RATE) * 86400) >> 32, 1386295, "default: ticks after one day");
        // A one-unit excess is gone after the first whole tick at any rate; flat when there is no excess.
        assertEq(decayedFee(FEE_03 + 1, FEE_03, DECAY_RATE, 0), FEE_03 + 1, "1 unit: start");
        assertEq(decayedFee(FEE_03 + 1, FEE_03, DECAY_RATE, 1), FEE_03, "1 unit: one second");
        assertEq(decayedFee(FEE_03 + 1, FEE_03, DECAY_QUARTER, 3), FEE_03 + 1, "1 unit: before the first tick");
        assertEq(decayedFee(FEE_03 + 1, FEE_03, DECAY_QUARTER, 4), FEE_03, "1 unit: first tick");
        assertEq(decayedFee(FEE_03, FEE_03, DECAY_RATE, 1), FEE_03, "equal fees");
        assertEq(decayedFee(RATE_MAX, RATE_MAX, DECAY_RATE, 86400), RATE_MAX, "equal at the maximum");
        assertEq(decayedFee(0, 0, DECAY_RATE, 1), 0, "zero fees");
    }

    function probe_factor(int32 tick) internal pure returns (uint256) {
        return tickToSqrtRatio(tick).toFixed();
    }

    /// @dev The default one-day half-life, 50% -> 0.3%: about 25.15% after one day (not 0.3%), the excess halves each
    /// day, and the floor is reached by rounding well before the helper's range ends. Pinned by the Python oracle
    /// (150-digit Decimal) against `floor(2 * ln 2 / ln 1.000001 * 2**32 / 86400)`.
    function test_default_oneDayHalfLife() public pure {
        assertEq(DECAY_RATE, 68913100933, "default rate");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_RATE, 1), 9223298692930386783, "1 s");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_RATE, 3600), 8962377276946957658, "1 h");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_RATE, 43200), 6538119400055406284, "12 h");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_RATE, 86399), 4639392931174751855, "1 d - 1 s");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_RATE, 86400), 4639356258918185573, "1 d: 25.1500006743%");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_RATE, 86401), 4639319586954996023, "1 d + 1 s");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_RATE, 172800), 2347348307759775472, "2 d: 12.725%");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_RATE, 7 days), 126965494298918151, "7 d: 0.688%");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_RATE, 30 days), 55340240759526319, "30 d: floor + 8538397665");
        assertGt(decayedFee(RATE_50, FEE_03, DECAY_RATE, 30 days), FEE_03, "not at the floor after 30 days");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_RATE, 5529597), FEE_03, "at the floor by rounding");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_RATE, 5529598), FEE_03, "saturated");
        assertEq(decayedFee(RATE_MAX, 0, DECAY_RATE, 86400), 9223372287116814725, "max -> 0 after one day");
        // The rate-2 example from the design discussion: an 8.02 day excess half-life.
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_2, 86400), 8464509350746382498, "2 ticks/s, 1 d: 45.886%");
        assertEq(decayedFee(RATE_50, FEE_03, DECAY_2, 30 days), 741753037726786584, "2 ticks/s, 30 d: 4.021%");
        assertEq(decayedFee(RATE_999, 0, DECAY_2, 30 days), 1379731172434914028, "99.9% -> 0, 30 d: 7.4795%");
        assertEq(_saturationSecond(DECAY_2), 44361417, "2 ticks/s last supported second");
    }

    /// @dev Whole domain: any fees with `finalFee <= initialFee`, any rate, any two elapsed values. Never reverts,
    /// stays in `[finalFee, initialFee]`, never increases, and is exactly `initialFee` at zero elapsed.
    function testFuzz_feeBoundedMonotone(uint64 initialFee, uint64 finalFee, uint64 decayRateX32, uint256 a, uint256 b)
        public
        pure
    {
        finalFee = uint64(bound(finalFee, 0, initialFee));
        if (a > b) (a, b) = (b, a);
        assertEq(decayedFee(initialFee, finalFee, decayRateX32, 0), initialFee, "start");
        uint64 fa = decayedFee(initialFee, finalFee, decayRateX32, a);
        uint64 fb = decayedFee(initialFee, finalFee, decayRateX32, b);
        assertLe(fa, initialFee, "<= initial");
        assertGe(fa, finalFee, ">= final");
        assertGe(fa, fb, "non-increasing");
        assertEq(
            decayedFee(initialFee, finalFee, decayRateX32, type(uint256).max),
            decayRateX32 == 0 ? initialFee : finalFee,
            "end"
        );
    }

    /// @dev The wrapper equals the formula written out: the saturation check, the floored magnitude, the helper's
    /// compact fixed value and the floored Q128 product.
    function testFuzz_matchesWrittenOutFormula(uint64 initialFee, uint64 finalFee, uint64 decayRateX32, uint256 elapsed)
        public
        pure
    {
        finalFee = uint64(bound(finalFee, 0, initialFee));
        uint64 expected;
        if (decayRateX32 == 0) {
            expected = initialFee;
        } else if (elapsed > MAX_DECAY_PRODUCT / decayRateX32) {
            expected = finalFee;
        } else {
            uint256 m = (uint256(decayRateX32) * elapsed) >> 32;
            uint256 factor = tickToSqrtRatio(-int32(int256(m))).toFixed();
            expected = finalFee + uint64((uint256(initialFee - finalFee) * factor) >> 128);
        }
        assertEq(decayedFee(initialFee, finalFee, decayRateX32, elapsed), expected, "formula");
    }

    /// @dev Non-increasing in the rate too: a faster launch is never charging more at the same elapsed time.
    function testFuzz_fasterRateNeverHigher(uint64 initialFee, uint64 finalFee, uint64 r1, uint64 r2, uint256 elapsed)
        public
        pure
    {
        finalFee = uint64(bound(finalFee, 0, initialFee));
        if (r1 > r2) (r1, r2) = (r2, r1);
        assertGe(decayedFee(initialFee, finalFee, r1, elapsed), decayedFee(initialFee, finalFee, r2, elapsed), "rate");
    }

    /// @dev SHA-256 chain over the schedule at the sampled seconds, as pinned by the Python oracle.
    function _digest(uint64 initialFee, uint64 finalFee, uint64 decayRateX32, uint256 last, uint256 step)
        internal
        pure
        returns (bytes32 h)
    {
        for (uint256 t; t <= last; t += step) {
            h = sha256(bytes.concat(h, bytes8(decayedFee(initialFee, finalFee, decayRateX32, t))));
        }
    }

    function test_digests_pinned() public pure {
        assertEq(
            _digest(RATE_50, FEE_03, DECAY_RATE, 3600, 1),
            0xc3de4d91d476acc61f73455efe7fb8c750b89de3759a0c500bbde0bdf9bcd062,
            "default 50% -> 0.3%, every second of the first hour"
        );
        assertEq(
            _digest(RATE_50, FEE_03, DECAY_RATE, 30 days, 60),
            0xb2c022f5cbbc90cedca9834bcf64f636b97c45dee08c730ab4dbf17d8d5acc74,
            "default 50% -> 0.3%, every minute of 30 days"
        );
        assertEq(
            _digest(FEE_5, FEE_03, DECAY_RATE_600, 3600, 1),
            0xc4db35cd45f48222463cb9a940c506599715162db6c37b01428331ff5263bdc6,
            "600 s half-life 5% -> 0.3%, every second of the first hour"
        );
        assertEq(
            _digest(RATE_999, 0, DECAY_2, 30 days, 3600),
            0x8fdefff5fe4cfb98c43bbbf6ed6f0b9a0ae398f1f810ffea0522d5504e1321da,
            "2 ticks/s 99.9% -> 0, every hour of 30 days"
        );
        assertEq(
            _digest(RATE_MAX, 0, DECAY_QUARTER, 3600, 1),
            0x11ff0a905ab22707579e714aba31b895ed3234788a0dab10b0daa0881a9ccf36,
            "1/4 tick/s max -> 0, every second of the first hour"
        );
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
    /// the maximum decaying to the reference floor at the default rate, to zero at the fastest rate, and staying
    /// flat at the maximum at the slowest rate. The emitted `LaunchCreated` parameters, the stored record and the
    /// live schedule all carry the exact requested rates, and a first buy settles at the maximum.
    function test_create_maxRate_bothOrders_nativeAndERC20_schedules() public {
        bool[4] memory orders = [true, false, true, false];
        uint8[4] memory decimals = [18, 18, 6, 6];
        uint64[3] memory finals = [FEE_03, RATE_MAX, 0];
        uint64[3] memory rates = [DECAY_RATE, DECAY_MIN, DECAY_MAX];
        for (uint256 o; o < orders.length; o++) {
            for (uint256 s; s < finals.length; s++) {
                uint256 snap = vm.snapshotState();
                vm.recordLogs();
                (IZeroSeedLaunch.Installation memory inst,) =
                    _createCurve(orders[o], decimals[o], rates[s], RATE_MAX, finals[s]);
                bool native = !orders[o] && decimals[o] == 18;
                assertEq(inst.poolKey.token0 == NATIVE_TOKEN_ADDRESS, native, "native quote is token0");
                assertEq(inst.poolKey.token0 == inst.token, orders[o], "order");
                _assertCreatedEvent(inst, RATE_MAX, finals[s], rates[s]);
                _assertLiveSchedule(inst.poolKey.toPoolId(), finals[s], rates[s]);

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
                        "|decayRateX32=",
                        _ustr(rates[s]),
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
        uint64 decayRateX32
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
            assertEq(emitted.decayRateX32, decayRateX32, "event decay rate");
            assertEq(emitted.tradingStart, START, "event start");
            found = true;
        }
        assertTrue(found, "LaunchCreated emitted");
    }

    /// @dev `feeAt` from the maximum: the initial fee through the start, strictly below the maximum one second in
    /// unless flat or still below one accumulated tick, non-increasing and bounded, `finalFee` once saturated.
    function _assertLiveSchedule(PoolId id, uint64 finalFee, uint64 decayRateX32) internal view {
        assertEq(launch.feeAt(id, START - 1), RATE_MAX, "before start");
        assertEq(launch.feeAt(id, START), RATE_MAX, "at start");
        uint64 one = launch.feeAt(id, START + 1);
        if (finalFee == RATE_MAX) assertEq(one, RATE_MAX, "flat");
        else if (decayRateX32 == DECAY_MAX) assertEq(one, finalFee, "fastest rate saturates in one second");
        else if (decayRateX32 < 1 << 32) assertEq(one, RATE_MAX, "below one tick after one second");
        else assertLt(one, RATE_MAX, "decays from the first second");
        uint64 previous = RATE_MAX;
        uint256[6] memory samples = [uint256(1), 600, 1800, 3600, 86400, 30 days];
        for (uint256 s; s < samples.length; s++) {
            uint64 fee = launch.feeAt(id, START + samples[s]);
            assertLe(fee, previous, "non-increasing");
            assertGe(fee, finalFee, ">= final");
            previous = fee;
        }
        uint256 saturation = _saturationSecond(decayRateX32);
        assertEq(launch.feeAt(id, START + saturation + 1), finalFee, "saturated");
        assertEq(launch.feeAt(id, type(uint256).max), finalFee, "far after saturation");
    }

    /// @dev Exactly 100% is 2**64: not a uint64. Calldata carrying that word in either fee field fails ABI decoding
    /// before any logic, with empty revert data, through the periphery (create and preview) and through a raw
    /// forward. The same calldata with 2**64 - 1 in that word creates the launch, so the one word is the only
    /// difference. Nothing is truncated or wrapped.
    function test_create_exactHundredPercentRefused_maxAccepted() public {
        assertEq(RATE_MAX, MAX_CREATOR_FEE, "the ceiling is the type maximum");
        _quote(true, 18);
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(ASK_18_18, REQUESTED_SUPPLY, DECAY_RATE);
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
        _assertSchedule(inst.poolKey.toPoolId(), RATE_MAX, RATE_MAX, DECAY_RATE);
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
            (IZeroSeedLaunch.Installation memory inst,) =
                _createCurve(tokenIs0, quoteDecimals, DECAY_RATE, rate, FEE_03);
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
        (IZeroSeedLaunch.Installation memory inst,) = _createCurve(tokenIs0, 18, DECAY_RATE, RATE_MAX, FEE_03);
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
        (IZeroSeedLaunch.Installation memory inst,) = _createCurve(true, 18, DECAY_RATE, RATE_MAX, FEE_03);
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
        (IZeroSeedLaunch.Installation memory inst,) = _createCurve(false, 18, DECAY_RATE, RATE_MAX, FEE_03);
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
            (IZeroSeedLaunch.Installation memory inst,) = _createCurve(tokenIs0, 18, DECAY_RATE, RATE_MAX, FEE_03);
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

/// @dev Gas and bytecode: the isolated tick-rate math and forwarded swaps across the schedule, both token orders
/// including native settlement.
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
    /// remains: at the start (no helper walk), across the first day, at the rounding floor and once saturated.
    function test_gas_isolatedMath() public {
        uint256[7] memory elapsed = [uint256(0), 1, 3600, 86400, 30 days, 5529597, 5529598];
        _measure(abi.encodeCall(probe.identity, (RATE_50, FEE_03, DECAY_RATE, 86400)));
        _measure(abi.encodeCall(probe.fee, (RATE_50, FEE_03, DECAY_RATE, 86400)));
        uint256 identity = _measure(abi.encodeCall(probe.identity, (RATE_50, FEE_03, DECAY_RATE, 86400)));
        for (uint256 i; i < elapsed.length; i++) {
            uint256 used = _measure(abi.encodeCall(probe.fee, (RATE_50, FEE_03, DECAY_RATE, elapsed[i])));
            assertGe(used, identity, "warm");
            console2.log(string.concat("GAS|feeMath|elapsed=", _ustr(elapsed[i]), "|tickRate=", _ustr(used - identity)));
        }
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
            (IZeroSeedLaunch.Installation memory inst,) = _createCurve(tokenIs0, 18, DECAY_RATE, RATE_50, FEE_03);
            string memory tag = string.concat("GAS|swap|order=", tokenIs0 ? "t0" : "t1(native)");
            uint256[5] memory at = [uint256(0), 1, 3600, 86400, 5529598];
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
