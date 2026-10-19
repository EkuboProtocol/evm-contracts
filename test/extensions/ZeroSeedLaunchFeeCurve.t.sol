// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {console2} from "forge-std/console2.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IZeroSeedLaunch} from "../../src/interfaces/extensions/IZeroSeedLaunch.sol";
import {ZeroSeedLaunch, MAX_CREATOR_FEE} from "../../src/extensions/ZeroSeedLaunch.sol";
import {MintableERC20} from "../../src/MintableERC20.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolConfig} from "../../src/types/poolConfig.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {amountBeforeFee, AmountBeforeFeeOverflow} from "../../src/math/fee.sol";
import {decayedFee, powQ64, Q64} from "../../src/math/feeDecay.sol";
import {ZeroSeedLaunchBase} from "./ZeroSeedLaunch.t.sol";

/// @dev Comparison baseline only: the pre-change linear schedule over the same storage and ABI. `decayFactor` is
/// stored and ignored, so a launch created with identical parameters has identical state under both variants.
contract LinearZeroSeedLaunch is ZeroSeedLaunch {
    constructor(ICore core, address quote) ZeroSeedLaunch(core, quote) {}

    function _feeAt(Launch storage launch, uint256 timestamp) internal view override returns (uint64) {
        uint64 initialFee = launch.initialFee;
        uint256 start = launch.tradingStart;
        if (timestamp <= start) return initialFee;
        uint256 elapsed = timestamp - start;
        uint256 duration = launch.feeDuration;
        uint64 finalFee = launch.finalFee;
        if (elapsed >= duration) return finalFee;
        return initialFee - uint64(uint256(initialFee - finalFee) * elapsed / duration);
    }
}

/// @dev External entry points so the isolated math can be measured as a call and pure reverts can be expected.
contract FeeMathProbe {
    function exponential(uint64 initialFee, uint64 finalFee, uint64 factor, uint32 duration, uint256 elapsed)
        external
        pure
        returns (uint64)
    {
        return decayedFee(initialFee, finalFee, factor, duration, elapsed);
    }

    function linear(uint64 initialFee, uint64 finalFee, uint32 duration, uint256 elapsed)
        external
        pure
        returns (uint64)
    {
        if (elapsed == 0) return initialFee;
        if (elapsed >= duration) return finalFee;
        return initialFee - uint64(uint256(initialFee - finalFee) * elapsed / duration);
    }

    function power(uint64 factor, uint256 exponent) external pure returns (uint256) {
        return powQ64(factor, exponent);
    }

    function identity(uint64 initialFee, uint64, uint64, uint32, uint256) external pure returns (uint64) {
        return initialFee;
    }

    function beforeFee(uint128 afterFee, uint64 fee) external pure returns (uint128) {
        return amountBeforeFee(afterFee, fee);
    }
}

abstract contract FeeCurveBase is ZeroSeedLaunchBase {
    using CoreLib for ICore;

    uint64 constant RATE_50 = 9223372036854775808;
    uint64 constant RATE_75 = 13835058055282163712;
    uint64 constant RATE_90 = 16602069666338596454;
    uint64 constant RATE_99 = 18262276632972456099;
    /// @dev Highest encodable rate, 2**64 - 1: refused by `create`; reachable in tests only by storage injection.
    uint64 constant RATE_MAX = type(uint64).max;
    /// @dev floor(2**64 * 2**(-1/1800)): an underlying 1,800 s half-life, the time at which the 3,600 s linear
    /// schedule has shed half of its excess. Study constant.
    uint64 constant FACTOR_HALF_1800 = 18439641936446208053;
    uint32 constant MAX_DURATION = type(uint32).max;

    address constant ROUTER = 0x03c8B90854b90AA22448b11e885F692972DA441C;
    bytes32 constant ROUTER_CODEHASH = 0x32ba8475c95ee5d9f7807f4ad9dce849929c992df9c68e9030e986d1854e726f;
    bytes32 constant CORE_CODEHASH = 0xc5f90c9d0dbc5037f8f9e248f4bb292e7c1824f584eb6550cb4cad525b38c71a;

    string internal artifact = "ZeroSeedLaunch.sol:ZeroSeedLaunch";
    FeeMathProbe internal probe;

    function setUp() public virtual override {
        super.setUp();
        probe = new FeeMathProbe();
    }

    function _launchArtifact() internal view override returns (string memory) {
        return artifact;
    }

    function _useLinear(bool linear) internal {
        artifact = linear ? "ZeroSeedLaunchFeeCurve.t.sol:LinearZeroSeedLaunch" : "ZeroSeedLaunch.sol:ZeroSeedLaunch";
    }

    function _rates() internal pure returns (uint64[5] memory) {
        return [RATE_50, RATE_75, RATE_90, RATE_99, RATE_MAX];
    }

    function _label(uint64 rate) internal pure returns (string memory) {
        if (rate == FEE_5) return "5";
        if (rate == RATE_50) return "50";
        if (rate == RATE_75) return "75";
        if (rate == RATE_90) return "90";
        if (rate == RATE_99) return "99";
        if (rate == RATE_MAX) return "max";
        return _ustr(rate);
    }

    /// @dev Creates a launch with an explicit schedule. `RATE_MAX` is refused by `create`, so it is created at the
    /// cap and then injected into storage: research-only, never a reachable configuration.
    function _createCurve(
        bool tokenIs0,
        uint8 quoteDecimals,
        uint32 duration,
        uint64 initialFee,
        uint64 finalFee,
        uint64 factor
    ) internal returns (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p) {
        address quote = _quote(tokenIs0, quoteDecimals);
        p = _parameters(quote, quoteDecimals == 18 ? ASK_18_18 : ASK_18_6, REQUESTED_SUPPLY, duration);
        p.initialFee = initialFee > MAX_CREATOR_FEE ? MAX_CREATOR_FEE : initialFee;
        p.finalFee = finalFee;
        p.decayFactor = factor;
        _bind(p, creator);
        vm.prank(creator);
        inst = launch.create(p);
        MintableERC20(inst.token).approve(address(swapper), type(uint256).max);
        if (initialFee > MAX_CREATOR_FEE) {
            vm.prank(creator);
            vm.expectRevert(IZeroSeedLaunch.FeeTooHigh.selector);
            launch.create(_withInitialFee(p, initialFee));
            _injectInitialFee(inst.poolKey.toPoolId(), initialFee);
            p.initialFee = initialFee;
        }
    }

    function _withInitialFee(IZeroSeedLaunch.LaunchParameters memory p, uint64 initialFee)
        internal
        pure
        returns (IZeroSeedLaunch.LaunchParameters memory q)
    {
        q = abi.decode(abi.encode(p), (IZeroSeedLaunch.LaunchParameters));
        q.initialFee = initialFee;
        q.salt = bytes32(uint256(2));
    }

    /// @dev `_launches` is mapping slot 0; `initialFee` is the low 8 bytes of the record's second word.
    function _injectInitialFee(PoolId id, uint64 fee) internal {
        bytes32 slot = bytes32(uint256(keccak256(abi.encode(id, uint256(0)))) + 1);
        uint256 word = uint256(vm.load(address(launch), slot));
        vm.store(address(launch), slot, bytes32((word & ~uint256(type(uint64).max)) | fee));
        IZeroSeedLaunch.Launch memory l = launch.getLaunch(id);
        assertEq(l.initialFee, fee, "injected initial fee");
        assertEq(l.creator, creator, "record intact");
        assertEq(launch.feeAt(id, START), fee, "injected rate live");
    }

    function _linear(uint64 initialFee, uint64 finalFee, uint32 duration, uint256 elapsed)
        internal
        pure
        returns (uint64)
    {
        if (elapsed == 0) return initialFee;
        if (elapsed >= duration) return finalFee;
        return initialFee - uint64(uint256(initialFee - finalFee) * elapsed / duration);
    }

    function _feeLedger(PoolKey memory key, address token) internal view returns (uint128 tokenFee, uint128 quoteFee) {
        (uint128 f0, uint128 f1) = launch.creatorFees(key);
        (tokenFee, quoteFee) = key.token0 == token ? (f0, f1) : (f1, f0);
    }

    function _int128(int128 value) internal pure returns (uint128 encoded) {
        assembly ("memory-safe") {
            encoded := value
        }
    }

    /// @dev yul-router v0.8 route: flags bit0 recipient, bit1 inclusive uint32 deadline; one forwarded hop.
    function _route(
        PoolKey memory key,
        address specified,
        address calculated,
        int128 amount,
        int128 minOut,
        bool allowPartial,
        uint32 deadline
    ) internal view returns (bytes memory) {
        return bytes.concat(
            bytes1(uint8(3)),
            bytes1(uint8(0)),
            bytes20(specified),
            bytes20(calculated),
            bytes16(_int128(minOut)),
            bytes20(address(this)),
            bytes4(deadline),
            bytes16(_int128(amount)),
            bytes1(uint8(0)),
            bytes1(uint8(1)),
            bytes20(key.config.extension()),
            bytes20(key.token0),
            bytes20(key.token1),
            bytes32(PoolConfig.unwrap(key.config)),
            bytes12(uint96(0)),
            bytes4(allowPartial ? uint32(1 << 31) : uint32(0))
        );
    }

    function _call(bytes memory route) internal returns (bool ok, int256 specified, int256 calculated) {
        bytes memory result;
        (ok, result) = ROUTER.call(route);
        if (ok) (,, specified, calculated) = abi.decode(result, (address, address, int256, int256));
    }

    function _routerQuote(bytes memory route) internal returns (int256 calculated) {
        (bool ok, bytes memory result) = ROUTER.call(abi.encodeWithSignature("quote(bytes)", route));
        assertTrue(ok, "quote");
        (,,, calculated) = abi.decode(result, (address, address, int256, int256));
    }
}

/// @dev Pure schedule properties: endpoints, boundedness, monotonicity, the study factors' chord dominance over
/// every second with Python-pinned digests, and the documented rounding counterexamples.
contract FeeCurveMathTest is FeeCurveBase {
    function test_power_identities() public pure {
        assertEq(powQ64(1, 0), Q64, "b^0 = 1");
        assertEq(powQ64(RATE_MAX, 0), Q64, "b^0 = 1");
        assertEq(powQ64(FACTOR_3600, 1), FACTOR_3600, "b^1 = b");
        assertEq(powQ64(1, 1), 1, "1 unit ^1");
        assertEq(powQ64(1, 2), 0, "1 unit ^2 floors to zero");
        assertEq(powQ64(RATE_MAX, MAX_DURATION), 18446744069414584321, "(Q-1)^(2^32-1), Python reference");
        assertEq(powQ64(FACTOR_HALF_1800, MAX_DURATION), 0, "half-life factor over max duration floors to zero");
        assertLt(powQ64(RATE_MAX, type(uint256).max), Q64, "always below one");
    }

    /// @dev Every second of both study schedules at all six rates: pinned to a SHA-256 chain over the big-endian
    /// uint64 values that the Python reference recomputes independently (test/vectors/zero-seed-launch.json).
    function test_studyFactors_allSeconds_boundedMonotoneChord_pinned() public pure {
        bytes32[6] memory pinned600 = [
            bytes32(0x6346e95d7a66797ce3270ff25d5fc19e64c2e9ccabf1c2dbc03a946276fe64b5),
            bytes32(0x73b08ebf1a8d045805ec42c84200bbd841e25e515a1aef7f7fb6d246c6b6027a),
            bytes32(0xac34495b80e94c660319b488c697f7ecf05af9eeb3f4a03c27c1b7bc79d4e5f4),
            bytes32(0x87c5e5119e29faddc71e59753cca77fea297b4d76419fd0b66a78a340c4b7cef),
            bytes32(0xaf32943cbe63a0991532e385ad42960e1ce4040d59981ca6d4a4d4b86dc20cb0),
            bytes32(0xdce005ce818ddc4248d259c7a6e2b9c0652cb4b4705b70cf9f4f04f1270023af)
        ];
        bytes32[6] memory pinned3600 = [
            bytes32(0x306aaf4b3acfabe5ba98a1ee86cf91ba6564e010f806d1f592f3a403620bfd77),
            bytes32(0xac4fa207bb2beec03e9a122e5839482d14abb55c72a4b65c155da02ea15baf51),
            bytes32(0xc7eaeb00462cc16f7ce3684309604d97a9a22a1eaec15a1b8862bbfd68705771),
            bytes32(0xfb0df6da40ddcacfe08f4a599b3078a1e6dbe0017b97e73b6b4e384563247354),
            bytes32(0xee35ebedb9d7c09c69675d9517cdc1dc26e177eb61e0aa76fd13eb63dee8cba8),
            bytes32(0x82e00f48c0d5dc03d757e417a60a410a8ee9cfd0d41c12cfb72547bfc73ac4f7)
        ];
        uint64[6] memory rates = [FEE_5, RATE_50, RATE_75, RATE_90, RATE_99, RATE_MAX];
        for (uint256 d; d < 2; d++) {
            uint32 duration = d == 0 ? DURATION_SHORT : DURATION;
            uint64 factor = d == 0 ? FACTOR_600 : FACTOR_3600;
            for (uint256 r; r < 6; r++) {
                bytes32 digest;
                uint64 previous = rates[r];
                for (uint256 t; t <= duration; t++) {
                    uint64 fee = decayedFee(rates[r], FEE_03, factor, duration, t);
                    assertLe(fee, previous, "non-increasing");
                    assertGe(fee, FEE_03, "at least final");
                    assertLe(fee, _linear(rates[r], FEE_03, duration, t), "study factor stays under the chord");
                    previous = fee;
                    digest = sha256(abi.encodePacked(digest, fee));
                }
                assertEq(decayedFee(rates[r], FEE_03, factor, duration, 0), rates[r], "start");
                assertEq(decayedFee(rates[r], FEE_03, factor, duration, duration), FEE_03, "end");
                assertEq(decayedFee(rates[r], FEE_03, factor, duration, type(uint256).max), FEE_03, "forever");
                assertEq(digest, d == 0 ? pinned600[r] : pinned3600[r], "pinned digest");
            }
        }
    }

    /// @dev Nearly flat factors: floor-rpow normalization can land slightly above the integer chord. Reproduced
    /// exactly as documented; the chord inequality is not asserted for arbitrary factors.
    function test_counterexamples_exponentialAboveIntegerChord() public pure {
        uint256[8][5] memory rows = [
            [
                uint256(18446744073692774400),
                600,
                561,
                6145946118234823704,
                3773859608321006899,
                3928045231480721956,
                3928045231465404992,
                15316964
            ],
            [
                uint256(18446744073675997184),
                600,
                596,
                18262276632972456099,
                16093730704593406921,
                16108187677454293848,
                16108187677449267249,
                5026599
            ],
            [
                uint256(18446744073709551608),
                4294967295,
                4197406844,
                18446744073709551615,
                18012629042273719369,
                18022489992398216608,
                18022489992391328815,
                6887793
            ],
            [
                uint256(18446744073709551608),
                4294967295,
                4028198074,
                18446744073709551615,
                14193599660735192734,
                14457771176879541746,
                14457771176818802869,
                60738877
            ],
            [
                uint256(18446744073709551608),
                4294967295,
                4074259523,
                18446744073709551615,
                11939927239388337278,
                12274296501798491214,
                12274296501754310277,
                44180937
            ]
        ];
        for (uint256 i; i < rows.length; i++) {
            uint64 factor = uint64(rows[i][0]);
            uint32 duration = uint32(rows[i][1]);
            uint256 elapsed = rows[i][2];
            uint64 initialFee = uint64(rows[i][3]);
            uint64 finalFee = uint64(rows[i][4]);
            uint64 fee = decayedFee(initialFee, finalFee, factor, duration, elapsed);
            uint64 chord = _linear(initialFee, finalFee, duration, elapsed);
            assertEq(fee, rows[i][5], "documented exponential value");
            assertEq(chord, rows[i][6], "documented chord value");
            assertEq(fee - chord, rows[i][7], "documented excess");
            assertGt(fee, chord, "exceeds the chord");
            // Boundedness and monotonicity still hold around the counterexample.
            assertLe(fee, initialFee);
            assertGe(fee, finalFee);
            assertLe(fee, decayedFee(initialFee, finalFee, factor, duration, elapsed - 1), "monotone before");
            assertGe(fee, decayedFee(initialFee, finalFee, factor, duration, elapsed + 1), "monotone after");
        }
    }

    function testFuzz_boundedMonotoneEndpoints(
        uint64 factor,
        uint32 duration,
        uint32 elapsed,
        uint64 initialFee,
        uint64 finalFee
    ) public pure {
        factor = uint64(bound(factor, 1, RATE_MAX));
        duration = uint32(bound(duration, 1, MAX_DURATION));
        finalFee = uint64(bound(finalFee, 0, initialFee));
        assertEq(decayedFee(initialFee, finalFee, factor, duration, 0), initialFee, "start");
        assertEq(decayedFee(initialFee, finalFee, factor, duration, duration), finalFee, "end");
        assertEq(decayedFee(initialFee, finalFee, factor, duration, uint256(duration) + elapsed), finalFee, "after");
        uint64 fee = decayedFee(initialFee, finalFee, factor, duration, elapsed);
        assertLe(fee, initialFee, "<= initial");
        assertGe(fee, finalFee, ">= final");
        assertGe(fee, decayedFee(initialFee, finalFee, factor, duration, uint256(elapsed) + 1), "non-increasing");
        if (initialFee == finalFee) assertEq(fee, initialFee, "equal fees are constant");
    }

    function testFuzz_powerMonotoneAndBelowOne(uint64 factor, uint32 a, uint32 b) public pure {
        factor = uint64(bound(factor, 1, RATE_MAX));
        if (a > b) (a, b) = (b, a);
        uint256 pa = powQ64(factor, a);
        assertGe(pa, powQ64(factor, b), "non-increasing in the exponent");
        assertLe(pa, Q64, "<= one");
        if (a != 0) assertLt(pa, Q64, "< one for positive exponents");
    }

    /// @dev Equal half-life comparison fixture: 1,800 s underlying half-life over the maximum duration. The power
    /// chain floors to zero at 115,200 s, but the fee already equals `finalFee` from 107,174 s, where the scaled
    /// power term floors to zero; before that the tail stays above the 3,600 s linear schedule's final fee.
    function test_halfLifeFactor_maxDuration_tail() public pure {
        uint64[10] memory expected = [
            922337203685477580,
            922003403234100432,
            919004976445628917,
            902534965489818689,
            743476184499003893,
            488838717953303091,
            272089475087215860,
            55340232221128654,
            55340232221128654,
            55340232221128654
        ];
        uint256[10] memory at = [uint256(0), 1, 10, 60, 600, 1800, 3600, 107174, 115200, type(uint64).max];
        for (uint256 i; i < at.length; i++) {
            assertEq(decayedFee(FEE_5, FEE_03, FACTOR_HALF_1800, MAX_DURATION, at[i]), expected[i], "tail");
        }
        assertEq(decayedFee(FEE_5, FEE_03, FACTOR_HALF_1800, MAX_DURATION, 107173), FEE_03 + 1, "last second above");
        assertEq(powQ64(FACTOR_HALF_1800, 115199), 1, "chain still positive");
        // Half point: matches the linear schedule's midpoint to within rounding, by construction of the factor.
        assertApproxEqAbs(expected[5], _linear(FEE_5, FEE_03, DURATION, 1800), 100, "half of the excess at 1800");
    }

    function test_exactOutput_helperAndSignedBounds_pure() public {
        uint64[6] memory rates = [FEE_5, RATE_50, RATE_75, RATE_90, RATE_99, RATE_MAX];
        for (uint256 i; i < rates.length; i++) {
            uint256 d = Q64 - rates[i];
            uint128 helperBound = uint128(uint256(type(uint128).max) * d / Q64);
            uint128 signedBound = uint128(uint256(uint128(type(int128).max)) * d / Q64);
            assertLe(probe.beforeFee(helperBound, rates[i]), type(uint128).max, "last valid helper input");
            vm.expectRevert(AmountBeforeFeeOverflow.selector);
            probe.beforeFee(helperBound + 1, rates[i]);
            assertLe(probe.beforeFee(signedBound, rates[i]), uint128(type(int128).max), "last valid signed input");
            assertGt(probe.beforeFee(signedBound + 1, rates[i]), uint128(type(int128).max), "first signed overflow");
            console2.log(
                string.concat(
                    "VEC|bounds|rate=",
                    _label(rates[i]),
                    "|helperLastValid=",
                    _ustr(helperBound),
                    "|signedLastValid=",
                    _ustr(signedBound)
                )
            );
        }
    }
}

/// @dev High initial rates on the pinned fixture: executed swaps at 50/75/90/99% and at the injected maximum.
contract FeeCurveHighRateTest is FeeCurveBase {
    using CoreLib for ICore;

    function test_create_capAndExactHundredPercentRefused() public {
        address quote = _quote(true, 18);
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(quote, ASK_18_18, REQUESTED_SUPPLY, DURATION);
        _bind(p, creator);
        p.initialFee = MAX_CREATOR_FEE + 1;
        vm.expectRevert(IZeroSeedLaunch.FeeTooHigh.selector);
        launch.previewInstallation(creator, p);
        vm.prank(creator);
        vm.expectRevert(IZeroSeedLaunch.FeeTooHigh.selector);
        launch.create(p);
        p.initialFee = RATE_MAX;
        vm.prank(creator);
        vm.expectRevert(IZeroSeedLaunch.FeeTooHigh.selector);
        launch.create(p);
        // Exactly 100% is 2**64: not a uint64. Calldata carrying that word fails ABI decoding before any logic.
        p.initialFee = MAX_CREATOR_FEE;
        bytes memory data = abi.encodeCall(launch.create, (p));
        uint256 offset = _wordOffset(data, bytes32(uint256(MAX_CREATOR_FEE)));
        assembly ("memory-safe") {
            mstore(add(add(data, 32), offset), 0x10000000000000000)
        }
        vm.prank(creator);
        (bool ok, bytes memory reason) = address(launch).call(data);
        assertFalse(ok, "100% rejected");
        assertEq(reason.length, 0, "ABI decoder revert, no custom error");
        // Factor bounds: zero refused, the highest encodable factor accepted at the cap.
        p.decayFactor = 0;
        vm.expectRevert(IZeroSeedLaunch.InvalidFeeSchedule.selector);
        launch.previewInstallation(creator, p);
        p.decayFactor = RATE_MAX;
        vm.prank(creator);
        launch.create(p);
    }

    function _wordOffset(bytes memory data, bytes32 word) private pure returns (uint256) {
        for (uint256 i = 4; i + 32 <= data.length; i += 32) {
            bytes32 w;
            assembly ("memory-safe") {
                w := mload(add(add(data, 32), i))
            }
            if (w == word) return i;
        }
        revert("word not found");
    }

    function _matrix(bool tokenIs0, uint8 quoteDecimals) internal {
        uint64[5] memory rates = _rates();
        for (uint256 r; r < rates.length; r++) {
            uint256 snap = vm.snapshotState();
            uint64 rate = rates[r];
            (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p) =
                _createCurve(tokenIs0, quoteDecimals, DURATION, rate, FEE_03, FACTOR_3600);
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
            (uint256 tokenDust, uint256 quoteDust) = _assertLedger(inst, p.quoteToken, quoteIn, quoteOut, MAX_DUST);
            console2.log(string.concat(tag, "|dust|token=", _ustr(tokenDust), "|quote=", _ustr(quoteDust)));
            vm.revertToState(snap);
        }
    }

    function test_highRate_token0_18_18() public {
        _matrix(true, 18);
    }

    function test_highRate_token1_18_18() public {
        _matrix(false, 18);
    }

    function test_highRate_token0_18_6() public {
        _matrix(true, 6);
    }

    function test_highRate_token1_18_6() public {
        _matrix(false, 6);
    }

    function _stateDigest(PoolKey memory key) internal view returns (bytes32) {
        (uint128 f0, uint128 f1) = launch.creatorFees(key);
        return keccak256(abi.encode(PoolState.unwrap(ICore(CORE).poolState(key.toPoolId())), f0, f1));
    }

    /// @dev Probes an exact-output buy of `want` tokens in a throwaway state: success with the calculated quote
    /// (paid minus fee), or the revert selector.
    function _probeExactOut(PoolKey memory key, address token, uint128 want)
        internal
        returns (bool ok, bytes4 selector, uint128 calc, uint128 paid)
    {
        uint256 snap = vm.snapshotState();
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
        } catch (bytes memory reason) {
            selector = bytes4(reason);
        }
        vm.revertToState(snap);
    }

    /// @dev At the maximum rate the fee-inclusive input is calc * 2**64, so both representation limits are inside
    /// the fixture's inventory: calc <= 2**63 - 1 executes, calc in [2**63, 2**64 - 1] passes the uint128 helper
    /// and fails the signed conversion, calc >= 2**64 fails the helper. Everything reverts atomically.
    function test_exactOut_executedBounds_maxRate() public {
        (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p) =
            _createCurve(true, 18, DURATION, RATE_MAX, FEE_03, FACTOR_3600);
        PoolKey memory key = inst.poolKey;
        vm.warp(START);
        bytes32 ledgerBefore = _stateDigest(key);

        // Largest requested output that executes.
        uint128 lo = 1;
        uint128 hi = inst.installedSupply;
        while (lo < hi) {
            uint128 mid = lo + (hi - lo + 1) / 2;
            (bool ok,,,) = _probeExactOut(key, inst.token, mid);
            if (ok) lo = mid;
            else hi = mid - 1;
        }
        (bool okLast,, uint128 calcLast, uint128 paidLast) = _probeExactOut(key, inst.token, lo);
        assertTrue(okLast, "last valid executes");
        assertEq(uint256(paidLast), uint256(calcLast) << 64, "paid = calc * 2**64");
        assertLe(calcLast, uint128(type(int128).max) >> 64, "calc within the signed bound");
        (bool okNext, bytes4 selNext,,) = _probeExactOut(key, inst.token, lo + 1);
        assertFalse(okNext, "first invalid reverts");
        assertEq(selNext, SafeCastLib.Overflow.selector, "signed int128 overflow, helper succeeded");
        console2.log(
            string.concat(
                "VEC|exactOutBounds|rate=max|signed|lastValidTokenOut=",
                _ustr(lo),
                "|calcQuote=",
                _ustr(calcLast),
                "|paid=",
                _ustr(paidLast),
                "|firstInvalidTokenOut=",
                _ustr(lo + 1),
                "|revert=Overflow"
            )
        );

        // Largest requested output whose revert is still the signed conversion; the next one fails the helper.
        lo = lo + 1;
        hi = inst.installedSupply;
        while (lo < hi) {
            uint128 mid = lo + (hi - lo + 1) / 2;
            (, bytes4 sel,,) = _probeExactOut(key, inst.token, mid);
            if (sel == SafeCastLib.Overflow.selector) lo = mid;
            else hi = mid - 1;
        }
        (, bytes4 selHelperLast,,) = _probeExactOut(key, inst.token, lo);
        (, bytes4 selHelperFirst,,) = _probeExactOut(key, inst.token, lo + 1);
        assertEq(selHelperLast, SafeCastLib.Overflow.selector, "helper still succeeds");
        assertEq(selHelperFirst, AmountBeforeFeeOverflow.selector, "helper uint128 overflow");
        console2.log(
            string.concat(
                "VEC|exactOutBounds|rate=max|helper|lastSignedOverflowTokenOut=",
                _ustr(lo),
                "|firstHelperOverflowTokenOut=",
                _ustr(lo + 1),
                "|revert=AmountBeforeFeeOverflow"
            )
        );
        assertEq(_stateDigest(key), ledgerBefore, "probes left nothing behind");
        _assertLedger(inst, p.quoteToken, 0, 0, 1);
    }

    /// @dev The other rates' representation limits are far beyond the fixture inventory: the whole supply is bought
    /// for far less than the 99% signed bound, so they are pure-math facts, not executable here.
    function test_exactOut_boundsUnreachableBelowMax() public {
        (IZeroSeedLaunch.Installation memory inst,) = _createCurve(true, 18, DURATION, RATE_99, FEE_03, FACTOR_3600);
        vm.warp(START);
        (bool ok,, uint128 calc, uint128 paid) = _probeExactOut(inst.poolKey, inst.token, inst.installedSupply);
        assertTrue(ok, "whole inventory executes at 99%");
        assertLt(paid, 1701411834604692325064505548116852735, "far below the 99% signed bound");
        console2.log(
            string.concat("VEC|exactOutBounds|rate=99|wholeSupply|calcQuote=", _ustr(calc), "|paid=", _ustr(paid))
        );
    }

    /// @dev The deployed Base Yul router runtime against the injected maximum rate, both token orders.
    function test_router_maxRate_minOut_deadline_partial_balance() public {
        vm.etch(ROUTER, vm.parseBytes(vm.trim(vm.readFile("test/fixtures/yul-router-0x03c8-base-52449112.hex"))));
        assertEq(ROUTER.codehash, ROUTER_CODEHASH, "router fixture");
        assertEq(CORE.codehash, CORE_CODEHASH, "local Core == Base Core runtime");
        for (uint256 i; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            bool tokenIs0 = i == 0;
            (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p) =
                _createCurve(tokenIs0, 18, DURATION, RATE_MAX, FEE_03, FACTOR_3600);
            ERC20(p.quoteToken).approve(ROUTER, type(uint256).max);
            ERC20(inst.token).approve(ROUTER, type(uint256).max);
            PoolKey memory key = inst.poolKey;
            vm.warp(START);
            uint32 nowTs = uint32(block.timestamp);
            string memory tag = string.concat("VEC|routerMax|order=", tokenIs0 ? "t0" : "t1");

            // One wei in: quoted zero. Minimum output 1 refuses; minimum output 0 executes a zero fill that
            // still takes the input.
            int256 quotedWei = _routerQuote(_route(key, p.quoteToken, inst.token, 1, 0, false, nowTs));
            assertEq(quotedWei, 0, "one wei quotes nothing at the maximum rate");
            (bool ok,,) = _call(_route(key, p.quoteToken, inst.token, 1, 1, false, nowTs));
            assertFalse(ok, "zero fill refused with minOut 1");
            uint256 balanceBefore = ERC20(p.quoteToken).balanceOf(address(this));
            (bool okZero, int256 paidZero, int256 gotZero) =
                _call(_route(key, p.quoteToken, inst.token, 1, 0, false, nowTs));
            assertTrue(okZero, "zero fill accepted with minOut 0");
            assertEq(gotZero, 0, "nothing received");
            assertEq(paidZero, 1, "one wei paid");
            assertEq(balanceBefore - ERC20(p.quoteToken).balanceOf(address(this)), 1, "wei taken");
            (uint128 feeToken,) = _feeLedger(key, inst.token);
            console2.log(string.concat(tag, "|oneWei|paid=1|got=0|creatorTokenFee=", _ustr(feeToken)));

            // One whole unit: minimum output around the quote, inclusive deadline, expiry.
            int256 quoted = _routerQuote(_route(key, p.quoteToken, inst.token, 1e18, 0, false, nowTs));
            assertGt(quoted, 0, "positive net");
            (ok,,) = _call(_route(key, p.quoteToken, inst.token, 1e18, int128(quoted + 1), false, nowTs));
            assertFalse(ok, "minOut quote+1 refused");
            (ok,,) = _call(_route(key, p.quoteToken, inst.token, 1e18, int128(quoted), false, nowTs - 1));
            assertFalse(ok, "expired deadline refused");
            (bool okExact, int256 paid, int256 got) =
                _call(_route(key, p.quoteToken, inst.token, 1e18, int128(quoted), false, nowTs));
            assertTrue(okExact, "minOut == quote, inclusive deadline");
            assertEq(got, quoted, "quote == execution");
            assertEq(paid, 1e18, "full input");
            console2.log(string.concat(tag, "|unit|paid=", _str(paid), "|got=", _str(got)));
            int256 quoted2 = _routerQuote(_route(key, p.quoteToken, inst.token, 1e18, 0, false, nowTs));
            assertLt(quoted2, quoted, "second buy at a higher price");
            (bool okMinus,, int256 gotMinus) =
                _call(_route(key, p.quoteToken, inst.token, 1e18, int128(quoted2 - 1), false, nowTs));
            assertTrue(okMinus, "minOut quote-1 executes");
            assertEq(gotMinus, quoted2, "quote == execution");

            // Full-fill flag beyond inventory refused; partial flag fills to the bound and refunds.
            (ok,,) = _call(_route(key, p.quoteToken, inst.token, 1e30, 0, false, nowTs));
            assertFalse(ok, "full fill beyond inventory refused");
            (bool okPartial, int256 paidPartial, int256 gotPartial) =
                _call(_route(key, p.quoteToken, inst.token, 1e30, 0, true, nowTs));
            assertTrue(okPartial, "partial fill");
            assertLt(paidPartial, 1e30, "unused input refunded");
            console2.log(string.concat(tag, "|partial|paid=", _str(paidPartial), "|got=", _str(gotPartial)));

            // Balance failure: a payer without the input reverts before any state change.
            address poor = makeAddr("poor");
            vm.prank(poor);
            ERC20(p.quoteToken).approve(ROUTER, type(uint256).max);
            bytes memory route = _route(key, p.quoteToken, inst.token, 1e18, 0, false, nowTs);
            vm.prank(poor);
            (bool okPoor,) = ROUTER.call(route);
            assertFalse(okPoor, "insufficient balance refused");
            vm.revertToState(snap);
        }
    }
}

/// @dev Immediate round trips and creator access, linear versus exponential at identical states.
contract FeeCurveRoundTripTest is FeeCurveBase {
    using CoreLib for ICore;

    struct Trip {
        uint64 rate;
        uint256 net;
        uint256 quoteOut;
        uint256 tokenFee;
        uint256 quoteFee;
    }

    function _starts() internal pure returns (uint256[6] memory) {
        return [uint256(0), 1, 10, 60, 600, 3600];
    }

    /// @dev Buy one quote unit, exact input, then sell everything back, exact input, at the same timestamp.
    function _trip(IZeroSeedLaunch.Installation memory inst, address quote, uint256 t)
        internal
        returns (Trip memory r)
    {
        vm.warp(START + t);
        r.rate = launch.feeAt(inst.poolKey.toPoolId(), block.timestamp);
        PoolBalanceUpdate u = _buy(inst.poolKey, inst.token, 1e18, false);
        r.net = uint128(-_tokenDelta(inst.poolKey, inst.token, u));
        u = _sell(inst.poolKey, inst.token, int128(uint128(r.net)), false);
        r.quoteOut = uint128(-_quoteDelta(inst.poolKey, inst.token, u));
        (r.tokenFee, r.quoteFee) = _feeLedger(inst.poolKey, inst.token);
        _assertLedger(inst, quote, 1e18, r.quoteOut, MAX_DUST);
    }

    function _pair(
        string memory name,
        uint64 initialFee,
        uint64 finalFee,
        uint32 linearDuration,
        uint32 exponentialDuration,
        uint64 factor,
        bool assertUnderChord
    ) internal {
        uint256[6] memory starts = _starts();
        for (uint256 i; i < starts.length; i++) {
            Trip[2] memory trips;
            for (uint256 v; v < 2; v++) {
                uint256 snap = vm.snapshotState();
                _useLinear(v == 0);
                (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p) =
                    _createCurve(true, 18, v == 0 ? linearDuration : exponentialDuration, initialFee, finalFee, factor);
                trips[v] = _trip(inst, p.quoteToken, starts[i]);
                console2.log(
                    string.concat(
                        "VEC|roundTrip|pair=",
                        name,
                        "|curve=",
                        v == 0 ? "linear" : "exponential",
                        "|t=",
                        _ustr(starts[i]),
                        "|rateQ64=",
                        _ustr(trips[v].rate),
                        "|quoteIn=1000000000000000000|net=",
                        _ustr(trips[v].net),
                        "|quoteOut=",
                        _ustr(trips[v].quoteOut),
                        "|loss=",
                        _ustr(1e18 - trips[v].quoteOut),
                        "|creatorTokenFee=",
                        _ustr(trips[v].tokenFee),
                        "|creatorQuoteFee=",
                        _ustr(trips[v].quoteFee)
                    )
                );
                vm.revertToState(snap);
            }
            _useLinear(false);
            if (assertUnderChord) {
                assertLe(trips[1].rate, trips[0].rate, "exponential rate under the chord");
                assertLe(1e18 - trips[1].quoteOut, 1e18 - trips[0].quoteOut, "exponential loss under linear");
                if (starts[i] == 0 || starts[i] >= linearDuration) {
                    assertEq(trips[1].quoteOut, trips[0].quoteOut, "identical at shared endpoints");
                }
            }
        }
    }

    function test_roundTrip_equalEndpoints_5to03_3600() public {
        _pair("I5-F03-D3600", FEE_5, FEE_03, DURATION, DURATION, FACTOR_3600, true);
    }

    function test_roundTrip_equalEndpoints_candidate50to03_3600() public {
        _pair("I50-F03-D3600", RATE_50, FEE_03, DURATION, DURATION, FACTOR_3600, true);
    }

    /// @dev Equal underlying half-life (1,800 s) rather than equal duration: the exponential keeps decaying past
    /// 3,600 s and only reaches the final fee at 115,200 s, so endpoints after the half point differ by design.
    function test_roundTrip_equalHalfLife_5to03() public {
        _pair("I5-F03-halfLife1800", FEE_5, FEE_03, DURATION, MAX_DURATION, FACTOR_HALF_1800, false);
    }

    /// @dev Creator buying through a proxy address and claiming versus an unrelated buyer, same state and size.
    /// Access: tokens held after the buy and claim. Profit: quote after selling everything back and claiming the
    /// sell fee. Token and quote ledgers are reported separately.
    function _creatorVersusOutsider(string memory name, uint64 initialFee, uint64 factor, bool linear) internal {
        uint256[6] memory starts = _starts();
        address proxy = makeAddr("proxy");
        for (uint256 i; i < starts.length; i++) {
            uint256 snap = vm.snapshotState();
            _useLinear(linear);
            (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p) =
                _createCurve(true, 18, DURATION, initialFee, FEE_03, factor);
            _useLinear(false);
            PoolKey memory key = inst.poolKey;
            vm.warp(START + starts[i]);
            uint64 rate = launch.feeAt(key.toPoolId(), block.timestamp);

            // Outsider.
            uint256 outsiderSnap = vm.snapshotState();
            PoolBalanceUpdate u = _buy(key, inst.token, 1e18, false);
            uint256 outsiderNet = uint128(-_tokenDelta(key, inst.token, u));
            u = _sell(key, inst.token, int128(uint128(outsiderNet)), false);
            uint256 outsiderOut = uint128(-_quoteDelta(key, inst.token, u));
            vm.revertToState(outsiderSnap);

            // Creator through a proxy, then claims to the proxy.
            ERC20(p.quoteToken).transfer(proxy, 1e18);
            vm.startPrank(proxy);
            ERC20(p.quoteToken).approve(address(swapper), type(uint256).max);
            ERC20(inst.token).approve(address(swapper), type(uint256).max);
            u = _buy(key, inst.token, 1e18, false);
            vm.stopPrank();
            uint256 proxyNet = uint128(-_tokenDelta(key, inst.token, u));
            assertEq(proxyNet, outsiderNet, "same fill for the same state");
            vm.prank(creator);
            (uint128 c0, uint128 c1) = launch.claimFees(key, proxy);
            uint256 claimedToken = key.token0 == inst.token ? c0 : c1;
            uint256 creatorHeld = ERC20(inst.token).balanceOf(proxy);
            assertEq(creatorHeld, proxyNet + claimedToken, "creator holds the gross output");
            vm.prank(proxy);
            u = _sell(key, inst.token, int128(uint128(creatorHeld)), false);
            uint256 creatorOut = uint128(-_quoteDelta(key, inst.token, u));
            vm.prank(creator);
            (c0, c1) = launch.claimFees(key, proxy);
            uint256 claimedQuote = key.token0 == inst.token ? c1 : c0;
            uint256 creatorQuote = ERC20(p.quoteToken).balanceOf(proxy);
            assertEq(creatorQuote, creatorOut + claimedQuote, "sale proceeds plus claimed quote fee");
            assertEq(ERC20(inst.token).balanceOf(proxy), 0, "all sold back");
            assertEq(ERC20(p.quoteToken).balanceOf(CORE) + creatorQuote, 1e18, "quote conservation");
            console2.log(
                string.concat(
                    "VEC|creatorAccess|pair=",
                    name,
                    "|curve=",
                    linear ? "linear" : "exponential",
                    "|t=",
                    _ustr(starts[i]),
                    "|rateQ64=",
                    _ustr(rate),
                    "|outsiderNet=",
                    _ustr(outsiderNet),
                    "|outsiderQuoteOut=",
                    _ustr(outsiderOut),
                    "|creatorGross=",
                    _ustr(creatorHeld),
                    "|creatorClaimedToken=",
                    _ustr(claimedToken),
                    "|creatorQuoteOut=",
                    _ustr(creatorOut),
                    "|creatorClaimedQuote=",
                    _ustr(claimedQuote),
                    "|creatorQuoteTotal=",
                    _ustr(creatorQuote)
                )
            );
            vm.revertToState(snap);
        }
    }

    function test_creatorAccess_5to03() public {
        _creatorVersusOutsider("I5-F03-D3600", FEE_5, FACTOR_3600, false);
        _creatorVersusOutsider("I5-F03-D3600", FEE_5, FACTOR_3600, true);
    }

    function test_creatorAccess_candidate50to03() public {
        _creatorVersusOutsider("I50-F03-D3600", RATE_50, FACTOR_3600, false);
        _creatorVersusOutsider("I50-F03-D3600", RATE_50, FACTOR_3600, true);
    }
}

/// @dev Full swap gas at identical states, timestamps and configurations, plus the isolated schedule math.
contract FeeCurveGasTest is FeeCurveBase {
    function test_gas_swapsLinearVersusExponential() public {
        uint256[5] memory at = [uint256(0), 1, 1800, 3599, 3600];
        for (uint256 v; v < 2; v++) {
            for (uint256 i; i < at.length; i++) {
                uint256 snap = vm.snapshotState();
                _useLinear(v == 0);
                (IZeroSeedLaunch.Installation memory inst,) =
                    _createCurve(true, 18, DURATION, FEE_5, FEE_03, FACTOR_3600);
                vm.warp(START + at[i]);
                uint256 g = gasleft();
                _buy(inst.poolKey, inst.token, 1e18, false);
                uint256 gFirst = g - gasleft();
                g = gasleft();
                _buy(inst.poolKey, inst.token, 1e18, false);
                uint256 gSecond = g - gasleft();
                g = gasleft();
                _buy(inst.poolKey, inst.token, 1e20, true);
                uint256 gExactOut = g - gasleft();
                g = gasleft();
                _sell(inst.poolKey, inst.token, 1e20, false);
                uint256 gSell = g - gasleft();
                console2.log(
                    string.concat(
                        "VEC|gasCurve|curve=",
                        v == 0 ? "linear" : "exponential",
                        "|t=",
                        _ustr(at[i]),
                        "|firstBuy=",
                        _ustr(gFirst),
                        "|secondBuy=",
                        _ustr(gSecond),
                        "|exactOutBuy=",
                        _ustr(gExactOut),
                        "|sell=",
                        _ustr(gSell)
                    )
                );
                vm.revertToState(snap);
            }
        }
        _useLinear(false);
    }

    function test_gas_isolatedMath() public view {
        uint256[6] memory at = [uint256(0), 1, 1800, 3599, 3600, 4294967295];
        for (uint256 i; i < at.length; i++) {
            uint256 g = gasleft();
            probe.identity(FEE_5, FEE_03, FACTOR_3600, DURATION, at[i]);
            uint256 gBase = g - gasleft();
            g = gasleft();
            probe.linear(FEE_5, FEE_03, DURATION, at[i]);
            uint256 gLinear = g - gasleft();
            g = gasleft();
            probe.exponential(FEE_5, FEE_03, FACTOR_3600, DURATION, at[i]);
            uint256 gExp = g - gasleft();
            g = gasleft();
            probe.exponential(FEE_5, FEE_03, FACTOR_HALF_1800, MAX_DURATION, at[i]);
            uint256 gExpMax = g - gasleft();
            console2.log(
                string.concat(
                    "VEC|gasMath|elapsed=",
                    _ustr(at[i]),
                    "|callBase=",
                    _ustr(gBase),
                    "|linear=",
                    _ustr(gLinear),
                    "|exponentialD3600=",
                    _ustr(gExp),
                    "|exponentialDmax=",
                    _ustr(gExpMax)
                )
            );
        }
    }
}
