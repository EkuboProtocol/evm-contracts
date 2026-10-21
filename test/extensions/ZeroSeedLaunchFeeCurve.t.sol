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
import {decayedFee, decayQ128, Q128, DECAY_ZERO_FROM} from "../../src/math/feeDecay.sol";
import {ZeroSeedLaunchBase} from "./ZeroSeedLaunch.t.sol";

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

abstract contract FeeCurveBase is ZeroSeedLaunchBase {
    using CoreLib for ICore;

    uint64 constant RATE_50 = 9223372036854775808;
    uint64 constant RATE_75 = 13835058055282163712;
    uint64 constant RATE_90 = 16602069666338596454;
    uint64 constant RATE_99 = 18262276632972456099;
    /// @dev Highest encodable rate, 2**64 - 1: refused by creation; reachable in tests only by storage injection.
    uint64 constant RATE_MAX = type(uint64).max;
    /// @dev floor(2**64 * 2**(-1/600)): the per-second factor the previous implementation was given for the
    /// canonical window, i.e. the same 600 s half-life the table now fixes.
    uint64 constant LEGACY_FACTOR = 18425445863997925462;

    address constant ROUTER = 0x03c8B90854b90AA22448b11e885F692972DA441C;
    bytes32 constant ROUTER_CODEHASH = 0x32ba8475c95ee5d9f7807f4ad9dce849929c992df9c68e9030e986d1854e726f;
    bytes32 constant CORE_CODEHASH = 0xc5f90c9d0dbc5037f8f9e248f4bb292e7c1824f584eb6550cb4cad525b38c71a;

    FeeMathProbe internal probe;

    function setUp() public virtual override {
        super.setUp();
        probe = new FeeMathProbe();
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

    /// @dev Creates a launch with an explicit schedule. `RATE_MAX` is refused by creation, so it is created at the
    /// cap and then injected into storage: research-only, never a reachable configuration.
    function _createCurve(bool tokenIs0, uint8 quoteDecimals, uint32 duration, uint64 initialFee, uint64 finalFee)
        internal
        returns (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p)
    {
        _quote(tokenIs0, quoteDecimals);
        p = _parameters(quoteDecimals == 18 ? ASK_18_18 : ASK_18_6, REQUESTED_SUPPLY, duration);
        p.initialFee = initialFee > MAX_CREATOR_FEE ? MAX_CREATOR_FEE : initialFee;
        p.finalFee = finalFee;
        _bind(p, creator);
        vm.prank(creator);
        inst = periphery.create(p);
        MintableERC20(inst.token).approve(address(swapper), type(uint256).max);
        if (initialFee > MAX_CREATOR_FEE) {
            vm.prank(creator);
            vm.expectRevert(IZeroSeedLaunch.FeeTooHigh.selector);
            periphery.create(_withInitialFee(p, initialFee));
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
        assertEq(l.controller, address(periphery), "record intact");
        assertEq(launch.feeAt(id, START), fee, "injected rate live");
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
        initialFee = uint64(bound(initialFee, 0, MAX_CREATOR_FEE));
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

    function test_exactOutput_helperAndSignedBounds_pure() public {
        // amountBeforeFee reverts rather than wrapping; the creator fee path inherits the guard.
        assertEq(probe.beforeFee(1, RATE_MAX), 1 << 64, "one unit at the maximum rate grosses up to 2**64");
        vm.expectRevert(AmountBeforeFeeOverflow.selector);
        probe.beforeFee(uint128(1) << 64, RATE_MAX);
    }
}

/// @dev High initial rates on the pinned fixture: executed swaps at 50/75/90/99% and at the injected maximum, in
/// both orders (plain ERC-20 quote above the token, native ETH below it) and at 18/6 decimals.
contract FeeCurveHighRateTest is FeeCurveBase {
    using CoreLib for ICore;

    function test_create_capAndExactHundredPercentRefused() public {
        _quote(true, 18);
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(ASK_18_18, REQUESTED_SUPPLY, DURATION);
        _bind(p, creator);
        p.initialFee = MAX_CREATOR_FEE + 1;
        vm.expectRevert(IZeroSeedLaunch.FeeTooHigh.selector);
        periphery.previewInstallation(creator, p);
        vm.prank(creator);
        vm.expectRevert(IZeroSeedLaunch.FeeTooHigh.selector);
        periphery.create(p);
        p.initialFee = RATE_MAX;
        vm.prank(creator);
        vm.expectRevert(IZeroSeedLaunch.FeeTooHigh.selector);
        periphery.create(p);
        // Exactly 100% is 2**64: not a uint64. Calldata carrying that word fails ABI decoding before any logic.
        p.initialFee = MAX_CREATOR_FEE;
        bytes memory data = abi.encodeCall(periphery.create, (p));
        uint256 offset = _wordOffset(data, bytes32(uint256(MAX_CREATOR_FEE)));
        assembly ("memory-safe") {
            mstore(add(add(data, 32), offset), 0x10000000000000000)
        }
        vm.prank(creator);
        (bool ok, bytes memory reason) = address(periphery).call(data);
        assertFalse(ok, "100% rejected");
        assertEq(reason.length, 0, "ABI decoder revert, no custom error");
        vm.prank(creator);
        periphery.create(p);
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
        (IZeroSeedLaunch.Installation memory inst,) = _createCurve(true, 18, DURATION, RATE_MAX, FEE_03);
        PoolKey memory key = inst.poolKey;
        vm.warp(START);
        bytes32 ledgerBefore = _stateDigest(key);

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
        assertEq(_stateDigest(key), ledgerBefore, "probes left nothing behind");
        _assertLedger(inst, activeQuote, 0, 0, 1);
    }

    /// @dev The deployed Base Yul router runtime against the injected maximum rate (token0 order; the native order
    /// through the same router is covered by the main suite).
    function test_router_maxRate_minOut_deadline_partial_balance() public {
        vm.etch(ROUTER, vm.parseBytes(vm.trim(vm.readFile("test/fixtures/yul-router-0x03c8-base-52449112.hex"))));
        assertEq(ROUTER.codehash, ROUTER_CODEHASH, "router fixture");
        assertEq(CORE.codehash, CORE_CODEHASH, "local Core == Base Core runtime");
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
