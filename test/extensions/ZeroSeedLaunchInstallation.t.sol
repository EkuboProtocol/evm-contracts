// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {console2} from "forge-std/console2.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IExposedStorage} from "../../src/interfaces/IExposedStorage.sol";
import {IZeroSeedLaunch} from "../../src/interfaces/extensions/IZeroSeedLaunch.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, NATIVE_TOKEN_ADDRESS} from "../../src/math/constants.sol";
import {alignLaunchRange, LAUNCH_RANGE_STEPS, MAX_LAUNCH_TICK_SPACING} from "../../src/math/launchRange.sol";
import {tickToBitmapWordAndIndex} from "../../src/math/tickBitmap.sol";
import {MAX_SUPPLY} from "../../src/extensions/ZeroSeedLaunch.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PositionId, createPositionId} from "../../src/types/positionId.sol";
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {liquidityDeltaToAmountDelta, maxLiquidity} from "../../src/math/liquidity.sol";
import {amount0DeltaSorted, amount1DeltaSorted} from "../../src/math/delta.sol";
import {ZeroSeedLaunchBase, DecimalsToken} from "./ZeroSeedLaunch.t.sol";

/// @dev Plain-pool locker: what Core itself debits for a liquidity amount at a geometry, with no extension involved.
contract DebitProbe is BaseLocker {
    using CoreLib for ICore;
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function provide(PoolKey memory key, int32 tick, PositionId positionId, int128 liquidity, address payer)
        external
        returns (int128, int128)
    {
        return abi.decode(lock(abi.encode(key, tick, positionId, liquidity, payer)), (int128, int128));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory key, int32 tick, PositionId positionId, int128 liquidity, address payer) =
            abi.decode(data, (PoolKey, int32, PositionId, int128, address));
        ICore core = ICore(payable(address(ACCOUNTANT)));
        core.initializePool(key, tick);
        PoolBalanceUpdate update = core.updatePosition(key, positionId, liquidity);
        if (update.delta0() > 0) ACCOUNTANT.payFrom(payer, key.token0, uint128(update.delta0()));
        if (update.delta1() > 0) ACCOUNTANT.payFrom(payer, key.token1, uint128(update.delta1()));
        return abi.encode(update.delta0(), update.delta1());
    }
}

/// @dev Installation math: the spacing and bounds follow the shared alignment rule, and the installed liquidity is
/// the largest amount Core's rounded debit lets the requested supply pay for, in both token orders, over the whole
/// supported tick and supply domain. The oracle for every check is Core's own debit (`liquidityDeltaToAmountDelta`,
/// and a plain pool for the headline vectors) and Core's own bitmap geometry, never the installation formula; the
/// pinned rows come from `test/vectors/zero-seed-launch-installation.py`.
contract ZeroSeedLaunchInstallationTest is ZeroSeedLaunchBase {
    using CoreLib for ICore;

    function _geometry(int32 ask, int32 upper, uint128 supply)
        internal
        view
        returns (IZeroSeedLaunch.LaunchParameters memory p)
    {
        p = _parameters(ask, supply, DECAY_RATE);
        p.upperTick = upper;
    }

    /// @dev Core's bitmap words holding a position's two ticks: the rule keeps them within two adjacent words.
    function _bitmapWords(PositionId positionId, uint32 spacing) internal pure returns (uint256) {
        (uint256 lowerWord,) = tickToBitmapWordAndIndex(positionId.tickLower(), spacing);
        (uint256 upperWord,) = tickToBitmapWordAndIndex(positionId.tickUpper(), spacing);
        return upperWord - lowerWord + 1;
    }

    /// @dev The preview's spacing and bounds are the shared rule's, inside the request, each bound moved by less than
    /// one spacing, the range at most `LAUNCH_RANGE_STEPS` steps and at most two bitmap words in the pool's order.
    function _assertAligned(IZeroSeedLaunch.LaunchParameters memory p, IZeroSeedLaunch.Installation memory inst)
        internal
        pure
    {
        (uint32 spacing, int32 ask, int32 upper) = alignLaunchRange(p.askTick, p.upperTick);
        assertEq(inst.tickSpacing, spacing, "rule spacing");
        assertEq(inst.askTick, ask, "rule ask");
        assertEq(inst.upperTick, upper, "rule upper");
        assertEq(inst.poolKey.config.concentratedTickSpacing(), spacing, "pool spacing");
        uint256 width = uint256(int256(p.upperTick) - int256(p.askTick));
        assertEq(spacing, (width + LAUNCH_RANGE_STEPS - 1) / LAUNCH_RANGE_STEPS, "ceil(width / 256)");
        assertLe(spacing, MAX_LAUNCH_TICK_SPACING, "below the rule's maximum");
        assertTrue(ask >= p.askTick && upper <= p.upperTick && ask < upper, "inside the request, ordered");
        assertLt(uint256(int256(ask) - int256(p.askTick)), spacing, "ask moves less than one spacing");
        assertLt(uint256(int256(p.upperTick) - int256(upper)), spacing, "upper moves less than one spacing");
        assertEq(ask % int32(spacing), 0, "ask aligned");
        assertEq(upper % int32(spacing), 0, "upper aligned");
        assertLe(uint256(int256(upper) - int256(ask)) / spacing, LAUNCH_RANGE_STEPS, "at most 256 steps");
        bool tokenIs0 = inst.poolKey.token0 == inst.token;
        assertEq(inst.positionId.tickLower(), tokenIs0 ? ask : -upper, "pool lower");
        assertEq(inst.positionId.tickUpper(), tokenIs0 ? upper : -ask, "pool upper");
        assertLe(_bitmapWords(inst.positionId, spacing), 2, "two bitmap words");
    }

    /// @dev Core's debit on the launch token for `liquidity` at the installation price; reverts above the signed
    /// amount range, which also exceeds any supported supply.
    function debitOf(IZeroSeedLaunch.Installation memory inst, uint128 liquidity) external pure returns (uint128) {
        (int128 d0, int128 d1) = liquidityDeltaToAmountDelta(
            tickToSqrtRatio(inst.initialTick),
            int128(liquidity),
            tickToSqrtRatio(inst.positionId.tickLower()),
            tickToSqrtRatio(inst.positionId.tickUpper())
        );
        bool tokenIs0 = inst.poolKey.token0 == inst.token;
        require((tokenIs0 ? d1 : d0) == 0, "quote debit");
        return uint128(tokenIs0 ? d0 : d1);
    }

    /// @dev Core's rounded-up debit for any `uint128` liquidity through the sorted delta functions Core's position
    /// update calls; reverts above the `uint128` amount range, which also exceeds any supported supply.
    function sortedDebitOf(IZeroSeedLaunch.Installation memory inst, uint128 liquidity)
        external
        pure
        returns (uint128)
    {
        uint256 lower = tickToSqrtRatio(inst.positionId.tickLower()).toFixed();
        uint256 upper = tickToSqrtRatio(inst.positionId.tickUpper()).toFixed();
        return inst.poolKey.token0 == inst.token
            ? amount0DeltaSorted(lower, upper, liquidity, true)
            : amount1DeltaSorted(lower, upper, liquidity, true);
    }

    /// @dev Whether Core would debit more than `supply` for `liquidity` (an unrepresentable amount counts as more).
    function _exceeds(IZeroSeedLaunch.Installation memory inst, uint128 liquidity, uint128 supply)
        internal
        view
        returns (bool)
    {
        try this.sortedDebitOf(inst, liquidity) returns (uint128 debit) {
            return debit > supply;
        } catch {
            return true;
        }
    }

    function _sharedHelper(IZeroSeedLaunch.Installation memory inst, uint128 supply) internal pure returns (uint128) {
        bool tokenIs0 = inst.poolKey.token0 == inst.token;
        return maxLiquidity(
            tickToSqrtRatio(inst.initialTick),
            tickToSqrtRatio(inst.positionId.tickLower()),
            tickToSqrtRatio(inst.positionId.tickUpper()),
            tokenIs0 ? supply : 0,
            tokenIs0 ? 0 : supply
        );
    }

    /// @dev Preview, create and check: the installed amount is Core's debit at the installed liquidity, one more unit
    /// would exceed the supply, the whole requested supply exists as installed + sink, and nothing is spendable.
    function _createMaximal(IZeroSeedLaunch.LaunchParameters memory p)
        internal
        returns (IZeroSeedLaunch.Installation memory inst)
    {
        IZeroSeedLaunch.Installation memory preview = periphery.previewInstallation(creator, p);
        _assertAligned(p, preview);
        vm.prank(creator);
        inst = periphery.create(p, "");
        assertEq(keccak256(abi.encode(inst)), keccak256(abi.encode(preview)), "create = preview");
        assertEq(this.debitOf(inst, inst.liquidity), inst.installedSupply, "installed is Core's debit");
        assertLe(inst.installedSupply, p.supply, "affordable");
        assertTrue(_exceeds(inst, inst.liquidity + 1, p.supply), "one more liquidity unit is unaffordable");
        assertGe(inst.liquidity, _sharedHelper(inst, p.supply), "never below the shared helper");
        LaunchToken token = LaunchToken(inst.token);
        assertEq(token.totalSupply(), p.supply, "totalSupply = requested");
        assertEq(token.balanceOf(CORE), inst.installedSupply, "Core holds the installed supply");
        assertEq(token.balanceOf(address(0)), p.supply - inst.installedSupply, "sink is the remainder");
        assertEq(token.balanceOf(address(launch)) + token.balanceOf(address(periphery)), 0, "nothing held outside");
        assertEq(_balance(activeQuote, CORE), 0, "no quote");
        _assertMintClosed(inst.token);
        PoolId id = inst.poolKey.toPoolId();
        assertEq(ICore(CORE).poolPositions(id, address(launch), inst.positionId).liquidity, inst.liquidity, "position");
        assertEq(launch.getLaunch(id).controller, address(periphery), "controller");
        assertEq(periphery.launchOwner(id), creator, "owner");
        _assertNoLockDebt(inst.poolKey);
    }

    /// @dev Core's transient lock accounting after the creation lock returned: no current locker, no lock with
    /// nonzero debt and no debt in either pool token (slot derivation as in `FlashAccountant`).
    function _assertNoLockDebt(PoolKey memory key) internal view {
        uint256 debtOffset = uint256(keccak256("FlashAccountant#_DEBT_LOCKER_TOKEN_ADDRESS_OFFSET"));
        (bool ok, bytes memory words) = CORE.staticcall(
            abi.encodePacked(
                IExposedStorage.tload.selector,
                uint256(keccak256("FlashAccountant#CURRENT_LOCKER_SLOT")),
                uint256(keccak256("FlashAccountant#NONZERO_DEBT_COUNT_OFFSET")),
                debtOffset + uint256(uint160(key.token0)),
                debtOffset + uint256(uint160(key.token1))
            )
        );
        assertTrue(ok && words.length == 128, "tload");
        (uint256 locker, uint256 nonzeroDebtCount, uint256 debt0, uint256 debt1) =
            abi.decode(words, (uint256, uint256, uint256, uint256));
        assertEq(locker | nonzeroDebtCount | debt0 | debt1, 0, "lock exited with zero debt");
    }

    /// @dev Core's own debit for `liquidity` at the vector's geometry in a plain pool with no extension; a distinct
    /// fee keeps each probe on its own pool.
    function _corePlainPoolDebit(int32 lower, int32 upper, uint32 spacing, uint128 liquidity, uint64 fee)
        internal
        returns (uint128)
    {
        DebitProbe probe = new DebitProbe(ICore(CORE));
        ERC20(QUOTE_LOW).approve(address(probe), type(uint256).max);
        PoolKey memory key = PoolKey({
            token0: QUOTE_LOW, token1: QUOTE_HIGH, config: createConcentratedPoolConfig(fee, spacing, address(0))
        });
        uint256 before = ERC20(QUOTE_LOW).balanceOf(CORE);
        (int128 d0, int128 d1) =
            probe.provide(key, lower, createPositionId(bytes24(0), lower, upper), int128(liquidity), address(this));
        assertEq(d1, 0, "plain pool: token0 only");
        assertEq(ERC20(QUOTE_LOW).balanceOf(CORE) - before, uint128(d0), "plain pool: paid exactly the debit");
        return uint128(d0);
    }

    function _headline(int32 ask, int32 upper, uint128 supply, uint128 liquidity, uint128 installed)
        internal
        returns (IZeroSeedLaunch.Installation memory inst)
    {
        IZeroSeedLaunch.LaunchParameters memory p = _geometry(ask, upper, supply);
        inst = _createMaximal(p);
        assertEq(inst.poolKey.token0, inst.token, "token0 launch");
        assertEq(inst.liquidity, liquidity, "exact maximum");
        assertEq(inst.installedSupply, installed, "installed");
        // Core itself, no extension: the installed liquidity costs exactly the installed supply and one more unit
        // costs more than the whole requested supply.
        deployCodeTo("ZeroSeedLaunch.t.sol:DecimalsToken", abi.encode(address(this), uint8(18)), QUOTE_LOW);
        uint32 spacing = inst.tickSpacing;
        assertEq(_corePlainPoolDebit(inst.askTick, inst.upperTick, spacing, liquidity, 0), installed, "Core debit at L");
        uint128 next = _corePlainPoolDebit(inst.askTick, inst.upperTick, spacing, liquidity + 1, 1);
        assertGt(next, supply, "Core debit at L + 1 exceeds the supply");
        console2.log(
            string.concat(
                "VEC|installation|ask=",
                _str(ask),
                "|upper=",
                _str(upper),
                "|spacing=",
                _ustr(spacing),
                "|alignedAsk=",
                _str(inst.askTick),
                "|alignedUpper=",
                _str(inst.upperTick),
                "|supply=",
                _ustr(supply),
                "|liquidity=",
                _ustr(inst.liquidity),
                "|installed=",
                _ustr(inst.installedSupply),
                "|sink=",
                _ustr(supply - inst.installedSupply),
                "|debitAtLiquidityPlusOne=",
                _ustr(next),
                "|sharedHelper=",
                _ustr(_sharedHelper(inst, supply))
            )
        );
    }

    /// Low ask, 1e30 supply, a 2,097,152-tick range already on the derived 8,192 grid: the shared helper would install
    /// 106052588672 and sink 7.84% of the supply; the exact maximum 115073586432 is affordable and leaves
    /// 8589236567713153558 raw units (8.6e-12 of the supply).
    function test_lowPrice_exactMaximum() public {
        IZeroSeedLaunch.Installation memory inst =
            _headline(-88080384, -85983232, 1e30, 115073586432, 999999999991410763432286846442);
        assertEq(inst.tickSpacing, 8192, "derived spacing");
        assertEq(inst.askTick, -88080384, "already aligned");
        assertEq(inst.upperTick, -85983232, "already aligned");
        assertEq(ERC20(inst.token).balanceOf(address(0)), 8589236567713153558);
        assertEq(_sharedHelper(inst, 1e30), 106052588672, "shared helper under-installs here");
        assertEq(this.debitOf(inst, 106052588672), 921606703670075887283160121070, "its sink would be 7.84%");
    }

    /// The same geometry with a supply worth exactly two liquidity units: the helper would install one and sink half.
    function test_lowPrice_twoLiquidityUnits() public {
        IZeroSeedLaunch.Installation memory inst =
            _headline(-88080384, -85983232, 17380183081064167375, 2, 17380183081064167375);
        assertEq(ERC20(inst.token).balanceOf(address(0)), 0, "no sink");
        assertEq(_sharedHelper(inst, 17380183081064167375), 1);
        assertEq(this.debitOf(inst, 1), 8690091540532083688);
        assertEq(this.debitOf(inst, 3), 26070274621596251062);
    }

    /// The whole tick range at the supply cap: the rule's largest spacing, 693,148, moves both bounds inward to
    /// +-88,029,796 (254 steps, one bitmap word) and the exact maximum installs all but 1.2e-11 of the supply.
    function test_fullWidth_supplyCap() public {
        IZeroSeedLaunch.Installation memory inst =
            _headline(MIN_TICK, MAX_TICK, MAX_SUPPLY, 76662368857, 999999999987511320520150058769);
        assertEq(inst.tickSpacing, MAX_LAUNCH_TICK_SPACING, "largest derived spacing");
        assertEq(inst.tickSpacing, 693148);
        assertLe(inst.tickSpacing, MAX_TICK_SPACING, "a valid Core spacing");
        assertEq(inst.askTick, -88029796);
        assertEq(inst.upperTick, 88029796);
        assertEq(_bitmapWords(inst.positionId, inst.tickSpacing), 1, "one bitmap word");
        assertEq(ERC20(inst.token).balanceOf(address(0)), 12488679479849941231);
        assertEq(tickToSqrtRatio(MIN_TICK).toFixed(), 18447191164202170524);
        assertEq(tickToSqrtRatio(MAX_TICK).toFixed(), 6276949602062853172742588666607187473671941430179807625216);
    }

    /// The native (token1) order of the low-ask geometry: the single floor is exact.
    function test_lowPrice_nativeOrder() public {
        _quote(false, 18);
        IZeroSeedLaunch.LaunchParameters memory p = _geometry(-88080384, -85983232, 1e30);
        IZeroSeedLaunch.Installation memory inst = _createMaximal(p);
        assertEq(inst.poolKey.token1, inst.token);
        assertEq(inst.liquidity, 115073586432);
        assertEq(inst.installedSupply, 999999999991410763454585671556);
        assertEq(inst.liquidity, _sharedHelper(inst, 1e30), "token1 keeps the helper's result");
    }

    function _row(
        bool tokenIs0,
        int32 ask,
        int32 upper,
        uint128 supply,
        uint32 spacing,
        int32 alignedAsk,
        int32 alignedUpper,
        uint128 liquidity,
        uint128 installed,
        bytes4 error
    ) internal {
        if (tokenIs0 != (activeQuote == QUOTE_HIGH)) _quote(tokenIs0, 18);
        IZeroSeedLaunch.LaunchParameters memory p = _geometry(ask, upper, supply);
        p.salt = keccak256(abi.encode(ask, upper, supply));
        if (error == bytes4(0)) {
            IZeroSeedLaunch.Installation memory inst = _createMaximal(p);
            assertEq(inst.tickSpacing, spacing, "pinned spacing");
            assertEq(inst.askTick, alignedAsk, "pinned aligned ask");
            assertEq(inst.upperTick, alignedUpper, "pinned aligned upper");
            assertEq(inst.liquidity, liquidity, "pinned liquidity");
            assertEq(inst.installedSupply, installed, "pinned installed");
            return;
        }
        try periphery.previewInstallation(creator, p) {
            revert("expected refusal");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), error, "pinned refusal");
            if (error == IZeroSeedLaunch.LiquidityAboveTickCap.selector) {
                (uint128 reported, uint128 cap) = abi.decode(_tail(reason), (uint128, uint128));
                assertEq(reported, liquidity, "pinned liquidity above the cap");
                assertGt(reported, cap);
                assertEq(cap, type(uint128).max / (1 + 2 * (uint128(uint32(MAX_TICK)) / spacing)), "cap");
            }
        }
        vm.prank(creator);
        vm.expectPartialRevert(error);
        periphery.create(p, "");
    }

    function _tail(bytes memory reason) internal pure returns (bytes memory out) {
        out = new bytes(reason.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = reason[i + 4];
        }
    }

    /// Pinned rows generated by the independent integer oracle (`--solidity`), both orders: fixtures at 1e27 and at the
    /// supply cap, the cap + 1 and other parameter refusals, the low-ask vectors, the full tick range, adjacent ticks
    /// at both ends, one-word and first-rounded widths, every compact-ratio region crossing, bounds rounded at
    /// positive, negative and zero-crossing ticks, and the zero-liquidity and tick-cap refusals.
    function test_vectors_installation() public {
        _row(
            true,
            -13815500,
            -9210300,
            1000000000000000000000000000,
            17990,
            -13798330,
            -9210880,
            1121810267768648385524834,
            999999999999999999999999508,
            0x00000000
        );
        _row(
            false,
            -13815500,
            -9210300,
            1000000000000000000000000000,
            17990,
            -13798330,
            -9210880,
            1121810267768648385525007,
            999999999999999999999999559,
            0x00000000
        );
        _row(
            true,
            -41446500,
            -36841300,
            1000000000000000000000000000,
            17990,
            -41430970,
            -36843520,
            1120910338181752946,
            999999999999999999488107389,
            0x00000000
        );
        _row(
            false,
            -41446500,
            -36841300,
            1000000000000000000000000000,
            17990,
            -41430970,
            -36843520,
            1120910338181752946,
            999999999999999999449009087,
            0x00000000
        );
        _row(
            true,
            -13815500,
            -9210300,
            1000000000000000000000000000000,
            17990,
            -13798330,
            -9210880,
            1121810267768648385524834552,
            999999999999999999999999999560,
            0x00000000
        );
        _row(
            false,
            -13815500,
            -9210300,
            1000000000000000000000000000000,
            17990,
            -13798330,
            -9210880,
            1121810267768648385525007495,
            999999999999999999999999999283,
            0x00000000
        );
        _row(true, -13815500, -9210300, 1000000000000000000000000000001, 0, 0, 0, 0, 0, 0x15ae6727);
        _row(false, -13815500, -9210300, 1000000000000000000000000000001, 0, 0, 0, 0, 0, 0x15ae6727);
        _row(true, -13815500, -9210300, 0, 0, 0, 0, 0, 0, 0x15ae6727);
        _row(true, -13815500, -9210300, 340282366920938463463374607431768211455, 0, 0, 0, 0, 0, 0x15ae6727);
        _row(true, -9210300, -13815500, 1000000000000000000000000000, 0, 0, 0, 0, 0, 0x1434ed7f);
        _row(true, -13815500, -13815500, 1000000000000000000000000000, 0, 0, 0, 0, 0, 0x1434ed7f);
        _row(true, -88722836, 0, 1000000000000000000000000000, 0, 0, 0, 0, 0, 0x1434ed7f);
        _row(true, 0, 88722836, 1000000000000000000000000000, 0, 0, 0, 0, 0, 0x1434ed7f);
        _row(
            true,
            -88080384,
            -85983232,
            1000000000000000000000000000000,
            8192,
            -88080384,
            -85983232,
            115073586432,
            999999999991410763432286846442,
            0x00000000
        );
        _row(
            false,
            -88080384,
            -85983232,
            1000000000000000000000000000000,
            8192,
            -88080384,
            -85983232,
            115073586432,
            999999999991410763454585671556,
            0x00000000
        );
        _row(
            true,
            -88080384,
            -85983232,
            17380183081064167375,
            8192,
            -88080384,
            -85983232,
            2,
            17380183081064167375,
            0x00000000
        );
        _row(
            true,
            -88080384,
            -85983232,
            17380183081064167374,
            8192,
            -88080384,
            -85983232,
            1,
            8690091540532083688,
            0x00000000
        );
        _row(true, -88080384, -85983232, 8690091540532083687, 8192, -88080384, -85983232, 0, 0, 0x10074548);
        _row(
            true,
            -88722835,
            88722835,
            1000000000000000000000000000000,
            693148,
            -88029796,
            88029796,
            76662368857,
            999999999987511320520150058769,
            0x00000000
        );
        _row(
            false,
            -88722835,
            88722835,
            1000000000000000000000000000000,
            693148,
            -88029796,
            88029796,
            76662368857,
            999999999987511320481816572317,
            0x00000000
        );
        _row(
            true,
            -88722835,
            88722835,
            1000000000000000000000000000,
            693148,
            -88029796,
            88029796,
            76662368,
            999999988808623780691083208,
            0x00000000
        );
        _row(
            false,
            -88722835,
            88722835,
            1000000000000000000000000000,
            693148,
            -88029796,
            88029796,
            76662368,
            999999988808623780652749722,
            0x00000000
        );
        _row(true, -88722835, 88722835, 1, 693148, -88029796, 88029796, 0, 0, 0x10074548);
        _row(
            true,
            -88722835,
            -88722834,
            1000000000000000000000000000000,
            1,
            -88722835,
            -88722834,
            108422926327411597,
            999999999999999996344855661603,
            0x00000000
        );
        _row(
            false,
            -88722835,
            -88722834,
            1000000000000000000000000000000,
            1,
            -88722835,
            -88722834,
            108422926327411597,
            999999999999999996128023363811,
            0x00000000
        );
        _row(
            true,
            88722834,
            88722835,
            1000000000000000000000000000000,
            1,
            88722834,
            88722835,
            340282366920938463463374607431768211455,
            0,
            0x20ea795f
        );
        _row(
            false,
            88722834,
            88722835,
            1000000000000000000000000000000,
            1,
            88722834,
            88722835,
            340282366920938463463374607431768211455,
            0,
            0x20ea795f
        );
        _row(true, 88722834, 88722835, 1, 1, 88722834, 88722835, 36892603211249009589164678, 1, 0x00000000);
        _row(
            true,
            88722834,
            88722835,
            1000000000000,
            1,
            88722834,
            88722835,
            36892603211249009589164678108647352867,
            0,
            0x20ea795f
        );
        _row(
            true,
            -13815500,
            -13815244,
            1000000000000000000000000000,
            1,
            -13815500,
            -13815244,
            7813072147042959328981570090,
            1000000000000000000000000000,
            0x00000000
        );
        _row(
            false,
            -13815500,
            -13815244,
            1000000000000000000000000000,
            1,
            -13815500,
            -13815244,
            7813072147042959329398836891,
            1000000000000000000000000000,
            0x00000000
        );
        _row(
            true,
            -13815500,
            -13815244,
            1000000000000000000000000000000,
            1,
            -13815500,
            -13815244,
            7813072147042959328981570090179,
            0,
            0x20ea795f
        );
        _row(
            false,
            -13815500,
            -13815244,
            1000000000000000000000000000000,
            1,
            -13815500,
            -13815244,
            7813072147042959329398836891643,
            0,
            0x20ea795f
        );
        _row(
            true,
            -13815500,
            -13815243,
            1000000000000000000000000000,
            2,
            -13815500,
            -13815244,
            7813072147042959328981570090,
            1000000000000000000000000000,
            0x00000000
        );
        _row(
            false,
            -13815500,
            -13815243,
            1000000000000000000000000000,
            2,
            -13815500,
            -13815244,
            7813072147042959329398836891,
            1000000000000000000000000000,
            0x00000000
        );
        _row(
            true,
            -44361442,
            -44361441,
            1000000000000000000000000000,
            1,
            -44361442,
            -44361441,
            465661575212763904543525,
            999999999999999999999999306,
            0x00000000
        );
        _row(
            true,
            -44361442,
            -44361440,
            1000000000000000000000000000000,
            1,
            -44361442,
            -44361440,
            232830845814061502201641833,
            999999999999999999999999996985,
            0x00000000
        );
        _row(
            true,
            -44361442,
            0,
            1000000000000000000000000000,
            173287,
            -44188185,
            0,
            253899790408353378,
            999999999999999996725183603,
            0x00000000
        );
        _row(true, -1, 1, 1000000000000000000000000000, 1, -1, 1, 1000000499999924847075404150522817, 0, 0x20ea795f);
        _row(false, -1, 1, 1000000000000000000000000000, 1, -1, 1, 1000000499999924847125251163448363, 0, 0x20ea795f);
        _row(
            true,
            44361441,
            44361442,
            1000000000000000000000000000,
            1,
            44361441,
            44361442,
            340282366920938463463374607431768211455,
            0,
            0x20ea795f
        );
        _row(
            false,
            44361441,
            44361442,
            1000000000000000000000000000,
            1,
            44361441,
            44361442,
            340282366920938463463374607431768211455,
            0,
            0x20ea795f
        );
        _row(
            true,
            -44361442,
            44361442,
            1000000000000000000000000000,
            346574,
            -44014898,
            44014898,
            276879701057981879,
            999999999999999999201164169,
            0x00000000
        );
        _row(
            false,
            -44361442,
            44361442,
            1000000000000000000000000000,
            346574,
            -44014898,
            44014898,
            276879701057981879,
            999999999999999999193455279,
            0x00000000
        );
        _row(true, 60000000, 70000000, 1, 39063, 60000768, 69961833, 10764374391619, 1, 0x00000000);
        _row(
            false,
            60000000,
            70000000,
            1000000000000000000000000000,
            39063,
            60000768,
            69961833,
            340282366920938463463374607431768211455,
            0,
            0x20ea795f
        );
        _row(
            true,
            -70000000,
            -60000000,
            1000000000000000000000000000,
            39063,
            -69961833,
            -60000768,
            647116794065,
            999999999999124336682130621,
            0x00000000
        );
        _row(
            false,
            -70000000,
            -60000000,
            1000000000000000000000000000,
            39063,
            -69961833,
            -60000768,
            647116794065,
            999999999999124336682121692,
            0x00000000
        );
        _row(
            true,
            -5000001,
            4999999,
            1000000000000000000000000000,
            39063,
            -4961001,
            4961001,
            84291969943815295400760046,
            999999999999999999999999992,
            0x00000000
        );
        _row(
            false,
            -5000001,
            4999999,
            1000000000000000000000000000,
            39063,
            -4961001,
            4961001,
            84291969943815295401053197,
            999999999999999999999999991,
            0x00000000
        );
        _row(true, -13815500, -9210300, 1, 17990, -13798330, -9210880, 0, 0, 0x10074548);
        _row(false, -13815500, -9210300, 1, 17990, -13798330, -9210880, 0, 0, 0x10074548);
        _row(true, -80000000, -75394800, 1, 17990, -79983540, -75396090, 0, 0, 0x10074548);
        _row(
            true,
            80000000,
            84605200,
            1000000000000000000000000000000,
            17990,
            80001530,
            84588980,
            340282366920938463463374607431768211455,
            0,
            0x20ea795f
        );
        _row(
            false,
            80000000,
            84605200,
            1000000000000000000000000000000,
            17990,
            80001530,
            84588980,
            340282366920938463463374607431768211455,
            0,
            0x20ea795f
        );
        _row(
            true,
            -13815500,
            -13815400,
            1000000000000000000000000000,
            1,
            -13815500,
            -13815400,
            20000684666478128866992076598,
            1000000000000000000000000000,
            0x00000000
        );
        _row(
            false,
            -13815500,
            -13815400,
            1000000000000000000000000000,
            1,
            -13815500,
            -13815400,
            20000684666478128870423680717,
            1000000000000000000000000000,
            0x00000000
        );
        _row(
            true,
            -13815500,
            -13815400,
            1000000000000000000000000000000,
            1,
            -13815500,
            -13815400,
            20000684666478128866992076598552,
            0,
            0x20ea795f
        );
        _row(
            false,
            -13815500,
            -13815400,
            1000000000000000000000000000000,
            1,
            -13815500,
            -13815400,
            20000684666478128870423680717318,
            0,
            0x20ea795f
        );
        _row(
            true,
            -13815500,
            -13720200,
            1000000000000000000000000000000,
            373,
            -13815174,
            -13720432,
            21617631916800636468600113422,
            1000000000000000000000000000000,
            0x00000000
        );
        _row(
            false,
            -13815500,
            -13720200,
            1000000000000000000000000000000,
            373,
            -13815174,
            -13720432,
            21617631916800636468567531274,
            999999999999999999999999999957,
            0x00000000
        );
        _row(
            true,
            -13815500,
            -13122400,
            1000000000000000000000000000000,
            2708,
            -13813508,
            -13122968,
            3428443934989539259216457645,
            999999999999999999999999999964,
            0x00000000
        );
        _row(
            false,
            -13815500,
            -13122400,
            1000000000000000000000000000000,
            2708,
            -13813508,
            -13122968,
            3428443934989539259217557666,
            999999999999999999999999999931,
            0x00000000
        );
    }

    /// Whole supported domain, both orders: any requested range at any supported supply either installs the largest
    /// liquidity Core's rounded debit lets the supply pay for on the rule's aligned geometry, or refuses for a reason
    /// the same debit confirms. Detects an under-installation (the next unit still affordable) as well as an
    /// over-installation.
    function testFuzz_installedLiquidityIsMaximal(int256 a, int256 b, uint128 supply, bool tokenIs0) public {
        a = bound(a, MIN_TICK, MAX_TICK - 1);
        b = bound(b, a + 1, MAX_TICK);
        supply = uint128(bound(supply, 1, MAX_SUPPLY));
        _quote(tokenIs0, 18);
        IZeroSeedLaunch.LaunchParameters memory p = _geometry(int32(a), int32(b), supply);
        (uint32 spacing, int32 ask, int32 upper) = alignLaunchRange(p.askTick, p.upperTick);
        try periphery.previewInstallation(creator, p) returns (IZeroSeedLaunch.Installation memory preview) {
            IZeroSeedLaunch.Installation memory inst = _createMaximal(p);
            assertEq(inst.liquidity, preview.liquidity);
        } catch (bytes memory reason) {
            // Only the geometry matters to `debitOf`; a sentinel token address never equals the native quote.
            IZeroSeedLaunch.Installation memory shape = IZeroSeedLaunch.Installation({
                token: address(1),
                poolKey: PoolKey({
                    token0: tokenIs0 ? address(1) : activeQuote,
                    token1: tokenIs0 ? activeQuote : address(1),
                    config: createConcentratedPoolConfig(0, spacing, address(launch))
                }),
                positionId: tokenIs0
                    ? createPositionId(bytes24(0), ask, upper)
                    : createPositionId(bytes24(0), -upper, -ask),
                initialTick: tokenIs0 ? ask : -ask,
                liquidity: 0,
                installedSupply: 0,
                tickSpacing: spacing,
                askTick: ask,
                upperTick: upper
            });
            if (bytes4(reason) == IZeroSeedLaunch.ZeroLiquidity.selector) {
                assertTrue(_exceeds(shape, 1, supply), "zero liquidity: one unit is unaffordable");
            } else {
                assertEq(bytes4(reason), IZeroSeedLaunch.LiquidityAboveTickCap.selector, "only the two refusals");
                (uint128 liquidity, uint128 cap) = abi.decode(_tail(reason), (uint128, uint128));
                assertGt(liquidity, cap, "refused above the cap");
                if (liquidity != type(uint128).max) {
                    assertFalse(_exceeds(shape, liquidity, supply), "the refused liquidity is affordable");
                    assertTrue(_exceeds(shape, liquidity + 1, supply), "and maximal");
                }
            }
        }
    }

    /// The alignment rule alone, over every ordered tick pair: spacing `ceil(width / 256)`, never above the rule's
    /// maximum or Core's, bounds inside the request on the grid, each moved by less than one spacing, at most 256
    /// steps, and at most two bitmap words in both token orders.
    function testFuzz_alignmentRule(int256 a, int256 b) public pure {
        a = bound(a, MIN_TICK, MAX_TICK - 1);
        b = bound(b, a + 1, MAX_TICK);
        (uint32 spacing, int32 ask, int32 upper) = alignLaunchRange(int32(a), int32(b));
        uint256 width = uint256(b - a);
        assertEq(spacing, (width + LAUNCH_RANGE_STEPS - 1) / LAUNCH_RANGE_STEPS, "ceil(width / 256)");
        assertTrue(spacing >= 1 && spacing <= MAX_LAUNCH_TICK_SPACING && spacing <= MAX_TICK_SPACING, "spacing");
        if (width <= LAUNCH_RANGE_STEPS) {
            assertEq(spacing, 1, "no rounding within one word");
            assertEq(ask, int32(a));
            assertEq(upper, int32(b));
        } else {
            assertLt(spacing, width, "spacing below the width");
        }
        assertTrue(ask >= a && upper <= b && ask < upper, "inside the request, ordered");
        assertLt(uint256(int256(ask) - a), spacing, "ask moves less than one spacing");
        assertLt(uint256(b - int256(upper)), spacing, "upper moves less than one spacing");
        assertEq(ask % int32(spacing), 0, "ask on the grid");
        assertEq(upper % int32(spacing), 0, "upper on the grid");
        uint256 steps = uint256(int256(upper) - int256(ask)) / spacing;
        assertTrue(steps >= 1 && steps <= LAUNCH_RANGE_STEPS, "1..256 steps");
        assertLe(_bitmapWords(createPositionId(bytes24(0), ask, upper), spacing), 2, "token0 order: two words");
        assertLe(_bitmapWords(createPositionId(bytes24(0), -upper, -ask), spacing), 2, "token1 order: two words");
    }

    function test_alignmentRule_extremes() public pure {
        (uint32 spacing, int32 ask, int32 upper) = alignLaunchRange(MIN_TICK, MAX_TICK);
        assertEq(spacing, 693148, "ceil(177445670 / 256)");
        assertEq(spacing, MAX_LAUNCH_TICK_SPACING);
        assertLt(MAX_LAUNCH_TICK_SPACING, MAX_TICK_SPACING, "never needs Core's clamp");
        assertEq(ask, -88029796);
        assertEq(upper, 88029796);
        (spacing, ask, upper) = alignLaunchRange(MIN_TICK, MIN_TICK + 1);
        assertEq(spacing, 1);
        assertEq(ask, MIN_TICK);
        assertEq(upper, MIN_TICK + 1);
        (spacing, ask, upper) = alignLaunchRange(MAX_TICK - 256, MAX_TICK);
        assertEq(spacing, 1, "256 ticks is one word");
        assertEq(ask, MAX_TICK - 256);
        (spacing, ask, upper) = alignLaunchRange(MAX_TICK - 257, MAX_TICK);
        assertEq(spacing, 2, "257 ticks is the first rounded width");
        assertEq(ask, MAX_TICK - 257, "even ask stays aligned");
        assertEq(upper, MAX_TICK - 1, "odd upper rounds down");
        // Signs: a positive ask rounds away from zero, a negative one toward zero; the upper bound the reverse.
        (spacing, ask, upper) = alignLaunchRange(60_000_000, 70_000_000);
        assertEq(spacing, 39063);
        assertEq(ask, 60_000_768);
        assertEq(upper, 69_961_833);
        (spacing, ask, upper) = alignLaunchRange(-70_000_000, -60_000_000);
        assertEq(spacing, 39063);
        assertEq(ask, -69_961_833);
        assertEq(upper, -60_000_768);
        (spacing, ask, upper) = alignLaunchRange(-5_000_001, 4_999_999);
        assertEq(spacing, 39063);
        assertEq(ask, -4_961_001);
        assertEq(upper, 4_961_001);
        // The fixture.
        (spacing, ask, upper) = alignLaunchRange(-13815500, -9210300);
        assertEq(spacing, 17990);
        assertEq(ask, -13798330);
        assertEq(upper, -9210880);
    }

    /// A refused creation leaves nothing behind: no token code, no pool, no balance; the same salt then creates.
    function test_refusal_atomic_sameSaltCreatesAfterwards() public {
        IZeroSeedLaunch.LaunchParameters memory p = _geometry(-88080384, -85983232, 8690091540532083687);
        IZeroSeedLaunch.LaunchParameters memory valid = _geometry(-88080384, -85983232, 1e30);
        IZeroSeedLaunch.Installation memory preview = periphery.previewInstallation(creator, valid);
        uint256 coreBalance = ERC20(QUOTE_HIGH).balanceOf(CORE);
        vm.prank(creator);
        vm.expectRevert(IZeroSeedLaunch.ZeroLiquidity.selector);
        periphery.create(p, "");
        assertEq(preview.token.code.length, 0, "no token deployed");
        assertEq(SqrtRatio.unwrap(ICore(CORE).poolState(preview.poolKey.toPoolId()).sqrtRatio()), 0, "no pool");
        assertEq(ERC20(QUOTE_HIGH).balanceOf(CORE), coreBalance);
        assertEq(launch.getLaunch(preview.poolKey.toPoolId()).controller, address(0), "no launch record");
        IZeroSeedLaunch.Installation memory inst = _createMaximal(valid);
        assertEq(inst.token, preview.token, "same salt creates afterwards");
    }

    function _measureCreate(string memory label, IZeroSeedLaunch.LaunchParameters memory p) internal {
        uint256 snap = vm.snapshotState();
        periphery.previewInstallation(creator, p);
        uint256 g = gasleft();
        IZeroSeedLaunch.Installation memory preview = periphery.previewInstallation(creator, p);
        uint256 previewGas = g - gasleft();
        vm.prank(creator);
        g = gasleft();
        IZeroSeedLaunch.Installation memory inst = periphery.create(p, "");
        uint256 createGas = g - gasleft();
        console2.log(
            string.concat(
                "GAS|installation|",
                label,
                "|order=",
                inst.poolKey.token0 == inst.token ? "t0" : "t1",
                "|preview=",
                _ustr(previewGas),
                "|create=",
                _ustr(createGas),
                "|spacing=",
                _ustr(inst.tickSpacing),
                "|liquidity=",
                _ustr(preview.liquidity),
                "|sink=",
                _ustr(p.supply - inst.installedSupply)
            )
        );
        vm.revertToState(snap);
    }

    /// Creation gas through the periphery (warm preview, then create) for the fixtures and the boundary geometries
    /// in both orders. Values are compared across revisions, not asserted.
    function test_gas_creationGeometries() public {
        for (uint256 o; o < 2; o++) {
            bool tokenIs0 = o == 0;
            _quote(tokenIs0, 18);
            _measureCreate("fixture18/18", _parameters(ASK_18_18, REQUESTED_SUPPLY, DECAY_RATE));
            _measureCreate("fixture18/18cap", _parameters(ASK_18_18, MAX_SUPPLY, DECAY_RATE));
            _measureCreate("lowAsk1e30", _geometry(-88080384, -85983232, 1e30));
            _measureCreate("lowAskTwoUnits", _geometry(-88080384, -85983232, 17380183081064167375));
            _measureCreate("fullWidth", _geometry(MIN_TICK, MAX_TICK, MAX_SUPPLY));
            _measureCreate("adjacentBottom", _geometry(MIN_TICK, MIN_TICK + 1, MAX_SUPPLY));
            _measureCreate("threeRegions", _geometry(-44361442, 44361442, 1e27));
        }
        _quote(true, 6);
        _measureCreate("fixture18/6", _parameters(ASK_18_6, REQUESTED_SUPPLY, DECAY_RATE));
        _quote(false, 6);
        _measureCreate("fixture18/6", _parameters(ASK_18_6, REQUESTED_SUPPLY, DECAY_RATE));
    }
}
