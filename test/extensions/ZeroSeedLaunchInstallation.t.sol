// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {console2} from "forge-std/console2.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IExposedStorage} from "../../src/interfaces/IExposedStorage.sol";
import {IZeroSeedLaunch} from "../../src/interfaces/extensions/IZeroSeedLaunch.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, NATIVE_TOKEN_ADDRESS} from "../../src/math/constants.sol";
import {MintableERC20} from "../../src/MintableERC20.sol";
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

/// @dev Installation math: the installed liquidity is the largest amount Core's rounded debit lets the requested
/// supply pay for, in both token orders, over the whole supported tick, spacing and supply domain. The oracle for
/// every check is Core's own debit (`liquidityDeltaToAmountDelta`, and a plain pool for the headline vectors), never
/// the installation formula; the pinned rows come from `test/vectors/zero-seed-launch-installation.py`.
contract ZeroSeedLaunchInstallationTest is ZeroSeedLaunchBase {
    using CoreLib for ICore;

    uint128 constant I128_MAX = uint128(type(int128).max);

    struct Row {
        bool tokenIs0;
        int32 ask;
        int32 upper;
        uint32 spacing;
        uint128 supply;
        uint128 liquidity;
        uint128 installed;
        bytes4 error;
    }

    function _geometry(int32 ask, int32 upper, uint32 spacing, uint128 supply)
        internal
        view
        returns (IZeroSeedLaunch.LaunchParameters memory p)
    {
        p = _parameters(ask, supply, DECAY_RATE);
        p.upperTick = upper;
        p.tickSpacing = spacing;
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
        vm.prank(creator);
        inst = periphery.create(p);
        assertEq(inst.liquidity, preview.liquidity, "create = preview liquidity");
        assertEq(inst.installedSupply, preview.installedSupply, "create = preview installed");
        assertEq(this.debitOf(inst, inst.liquidity), inst.installedSupply, "installed is Core's debit");
        assertLe(inst.installedSupply, p.supply, "affordable");
        assertTrue(_exceeds(inst, inst.liquidity + 1, p.supply), "one more liquidity unit is unaffordable");
        assertGe(inst.liquidity, _sharedHelper(inst, p.supply), "never below the shared helper");
        MintableERC20 token = MintableERC20(inst.token);
        assertEq(token.totalSupply(), p.supply, "totalSupply = requested");
        assertEq(token.balanceOf(CORE), inst.installedSupply, "Core holds the installed supply");
        assertEq(token.balanceOf(address(0)), p.supply - inst.installedSupply, "sink is the remainder");
        assertEq(token.balanceOf(address(launch)) + token.balanceOf(address(periphery)), 0, "nothing held outside");
        assertEq(_balance(activeQuote, CORE), 0, "no quote");
        assertEq(token.owner(), address(0), "mint authority renounced");
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.mint(address(this), 1);
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

    function _headline(int32 ask, int32 upper, uint32 spacing, uint128 supply, uint128 liquidity, uint128 installed)
        internal
        returns (IZeroSeedLaunch.Installation memory inst)
    {
        IZeroSeedLaunch.LaunchParameters memory p = _geometry(ask, upper, spacing, supply);
        inst = _createMaximal(p);
        assertEq(inst.poolKey.token0, inst.token, "token0 launch");
        assertEq(inst.liquidity, liquidity, "exact maximum");
        assertEq(inst.installedSupply, installed, "installed");
        // Core itself, no extension: the installed liquidity costs exactly the installed supply and one more unit
        // costs more than the whole requested supply.
        deployCodeTo("ZeroSeedLaunch.t.sol:DecimalsToken", abi.encode(address(this), uint8(18)), QUOTE_LOW);
        assertEq(_corePlainPoolDebit(ask, upper, spacing, liquidity, 0), installed, "Core debit at L");
        uint128 next = _corePlainPoolDebit(ask, upper, spacing, liquidity + 1, 1);
        assertGt(next, supply, "Core debit at L + 1 exceeds the supply");
        console2.log(
            string.concat(
                "VEC|installation|ask=",
                _str(ask),
                "|upper=",
                _str(upper),
                "|spacing=",
                _ustr(spacing),
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

    /// Low ask, 1e30 supply: the shared helper installed 106052588672 and sank 7.84% of the supply; the exact
    /// maximum 115073586432 is affordable and leaves 8589236567713153558 raw units (8.6e-12 of the supply).
    function test_lowPrice_exactMaximum() public {
        IZeroSeedLaunch.Installation memory inst =
            _headline(-88080384, -85983232, 524288, 1e30, 115073586432, 999999999991410763432286846442);
        assertEq(ERC20(inst.token).balanceOf(address(0)), 8589236567713153558);
        assertEq(_sharedHelper(inst, 1e30), 106052588672, "shared helper is unchanged and under-installs here");
        assertEq(this.debitOf(inst, 106052588672), 921606703670075887283160121070, "its sink was 7.84%");
    }

    /// The same geometry with a supply worth exactly two liquidity units: the helper installed one and sank half.
    function test_lowPrice_twoLiquidityUnits() public {
        IZeroSeedLaunch.Installation memory inst =
            _headline(-88080384, -85983232, 524288, 17380183081064167375, 2, 17380183081064167375);
        assertEq(ERC20(inst.token).balanceOf(address(0)), 0, "no sink");
        assertEq(_sharedHelper(inst, 17380183081064167375), 1);
        assertEq(this.debitOf(inst, 1), 8690091540532083688);
        assertEq(this.debitOf(inst, 3), 26070274621596251062);
    }

    /// Full supported width at spacing 1 with a supply chosen so the exact maximum debits it entirely; the helper is
    /// one unit short and sinks 18446296994052723740.
    function test_fullWidth_int128Budget() public {
        uint128 supply = 170141183460469231694794709727778658247;
        IZeroSeedLaunch.Installation memory inst =
            _headline(-88722835, 88722835, 1, supply, 9223595582101085260, supply);
        assertEq(_sharedHelper(inst, supply), 9223595582101085259);
        assertEq(this.debitOf(inst, 9223595582101085259), 170141183460469231676348412733725934507);
        assertEq(this.debitOf(inst, 9223595582101085261), 170141183460469231713241006721831381988);
        assertEq(tickToSqrtRatio(MIN_TICK).toFixed(), 18447191164202170524);
        assertEq(tickToSqrtRatio(MAX_TICK).toFixed(), 6276949602062853172742588666607187473671941430179807625216);
    }

    /// The native (token1) order of the low-ask geometry is unchanged: the single floor was already exact.
    function test_lowPrice_nativeOrderUnchanged() public {
        _quote(false, 18);
        IZeroSeedLaunch.LaunchParameters memory p = _geometry(-88080384, -85983232, 524288, 1e30);
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
        uint32 spacing,
        uint128 supply,
        uint128 liquidity,
        uint128 installed,
        bytes4 error
    ) internal {
        if (tokenIs0 != (activeQuote == QUOTE_HIGH)) _quote(tokenIs0, 18);
        IZeroSeedLaunch.LaunchParameters memory p = _geometry(ask, upper, spacing, supply);
        p.salt = keccak256(abi.encode(ask, upper, spacing, supply));
        if (error == bytes4(0)) {
            IZeroSeedLaunch.Installation memory inst = _createMaximal(p);
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
        periphery.create(p);
    }

    function _tail(bytes memory reason) internal pure returns (bytes memory out) {
        out = new bytes(reason.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = reason[i + 4];
        }
    }

    /// Pinned rows generated by the independent integer oracle (`--solidity`), both orders: fixtures, the low-ask
    /// and full-width vectors, adjacent ticks at both ends, every compact-ratio region crossing, the maximum spacing,
    /// supplies of 1 and int128.max, and the zero-liquidity and tick-cap refusals.
    function test_vectors_installation() public {
        _row(
            true,
            -13815500,
            -9210300,
            100,
            1000000000000000000000000000,
            1111119116089565312897934,
            999999999999999999999999210,
            0x00000000
        );
        _row(
            false,
            -13815500,
            -9210300,
            100,
            1000000000000000000000000000,
            1111119116089565312898036,
            999999999999999999999999422,
            0x00000000
        );
        _row(
            true,
            -41446500,
            -36841300,
            100,
            1000000000000000000000000000,
            1111138522742929536,
            999999999999999999302656786,
            0x00000000
        );
        _row(
            false,
            -41446500,
            -36841300,
            100,
            1000000000000000000000000000,
            1111138522742929536,
            999999999999999999282285400,
            0x00000000
        );
        _row(
            true,
            -88080384,
            -85983232,
            524288,
            1000000000000000000000000000000,
            115073586432,
            999999999991410763432286846442,
            0x00000000
        );
        _row(
            false,
            -88080384,
            -85983232,
            524288,
            1000000000000000000000000000000,
            115073586432,
            999999999991410763454585671556,
            0x00000000
        );
        _row(true, -88080384, -85983232, 524288, 17380183081064167375, 2, 17380183081064167375, 0x00000000);
        _row(true, -88080384, -85983232, 524288, 17380183081064167374, 1, 8690091540532083688, 0x00000000);
        _row(true, -88080384, -85983232, 524288, 8690091540532083687, 0, 0, 0x10074548);
        _row(
            true,
            -88722835,
            88722835,
            1,
            170141183460469231694794709727778658247,
            9223595582101085260,
            170141183460469231694794709727778658247,
            0x00000000
        );
        _row(
            true,
            -88722835,
            88722835,
            1,
            170141183460469231731687303715884105727,
            9223595582101085261,
            170141183460469231713241006721831381988,
            0x00000000
        );
        _row(
            false,
            -88722835,
            88722835,
            1,
            170141183460469231731687303715884105727,
            9223595582101085263,
            170141183460469231731687303715044921462,
            0x00000000
        );
        _row(
            true,
            -88722835,
            88722835,
            1,
            1000000000000000000000000000,
            54211422,
            999999990681923696940793667,
            0x00000000
        );
        _row(
            true,
            -88722835,
            -88722834,
            1,
            170141183460469231731687303715884105727,
            18447204999593076097010998,
            170141183460469231731687296059991816243,
            0x00000000
        );
        _row(
            false,
            -88722835,
            -88722834,
            1,
            170141183460469231731687303715884105727,
            18447204999593076101010948,
            170141183460469231731687297462692984201,
            0x00000000
        );
        _row(
            true,
            88722834,
            88722835,
            1,
            170141183460469231731687303715884105727,
            340282366920938463463374607431768211455,
            0,
            0x20ea795f
        );
        _row(
            false,
            88722834,
            88722835,
            1,
            170141183460469231731687303715884105727,
            340282366920938463463374607431768211455,
            0,
            0x20ea795f
        );
        _row(true, 88722834, 88722835, 1, 1, 36892603211249009589164678, 1, 0x00000000);
        _row(true, 88722834, 88722835, 1, 1000000000000, 36892603211249009589164678108647352867, 0, 0x20ea795f);
        _row(
            true,
            -44361442,
            -44361441,
            1,
            1000000000000000000000000000,
            465661575212763904543525,
            999999999999999999999999306,
            0x00000000
        );
        _row(
            true,
            -44361442,
            -44361440,
            1,
            170141183460469231731687303715884105727,
            39614115652906462714784288829449132,
            0,
            0x20ea795f
        );
        _row(
            true,
            -44361442,
            0,
            1,
            1000000000000000000000000000,
            232830613037616850,
            999999999999999996714041949,
            0x00000000
        );
        _row(true, -1, 1, 1, 1000000000000000000000000000, 1000000499999924847075404150522817, 0, 0x20ea795f);
        _row(false, -1, 1, 1, 1000000000000000000000000000, 1000000499999924847125251163448363, 0, 0x20ea795f);
        _row(
            true,
            44361441,
            44361442,
            1,
            1000000000000000000000000000,
            340282366920938463463374607431768211455,
            0,
            0x20ea795f
        );
        _row(
            false,
            44361441,
            44361442,
            1,
            1000000000000000000000000000,
            340282366920938463463374607431768211455,
            0,
            0x20ea795f
        );
        _row(
            true,
            -44361442,
            44361442,
            2,
            1000000000000000000000000000,
            232830612983406756,
            999999999999999998183904242,
            0x00000000
        );
        _row(
            false,
            -44361442,
            44361442,
            2,
            1000000000000000000000000000,
            232830612983406756,
            999999999999999998088284008,
            0x00000000
        );
        _row(
            true,
            -88722835,
            6986050,
            698605,
            1000000000000000000000000000,
            54211422,
            999999990681923696939145163,
            0x00000000
        );
        _row(
            false,
            -88722835,
            6986050,
            698605,
            1000000000000000000000000000,
            54211422,
            999999990681923696830727574,
            0x00000000
        );
        _row(
            true,
            -88722835,
            88722835,
            698605,
            170141183460469231731687303715884105727,
            9223595582101085261,
            170141183460469231713241006721831381988,
            0x00000000
        );
        _row(true, -13815500, -9210300, 100, 1, 0, 0, 0x10074548);
        _row(false, -13815500, -9210300, 100, 1, 0, 0, 0x10074548);
        _row(true, 60000000, 70000000, 100, 1, 10758806736509, 1, 0x00000000);
        _row(true, -80000000, -75394800, 100, 1, 0, 0, 0x10074548);
        _row(
            true,
            80000000,
            84605200,
            100,
            170141183460469231731687303715884105727,
            340282366920938463463374607431768211455,
            0,
            0x20ea795f
        );
        _row(
            false,
            80000000,
            84605200,
            100,
            170141183460469231731687303715884105727,
            340282366920938463463374607431768211455,
            0,
            0x20ea795f
        );
        _row(
            true,
            -13815500,
            -9210300,
            100,
            170141183460469231731687303715884105727,
            189047121377029142040373415393014291,
            0,
            0x20ea795f
        );
        _row(
            false,
            -13815500,
            -9210300,
            100,
            170141183460469231731687303715884105727,
            189047121377029142040390729623638705,
            0,
            0x20ea795f
        );
        _row(
            true,
            -13815500,
            -13815400,
            100,
            1000000000000000000000000000,
            20000684666478128866992076598,
            1000000000000000000000000000,
            0x00000000
        );
        _row(
            false,
            -13815500,
            -13815400,
            100,
            1000000000000000000000000000,
            20000684666478128870423680717,
            1000000000000000000000000000,
            0x00000000
        );
    }

    /// Whole supported domain, both orders: any aligned range at any spacing and any supported supply either installs
    /// the largest liquidity Core's rounded debit lets the supply pay for, or refuses for a reason the same debit
    /// confirms. Detects an under-installation (the next unit still affordable) as well as an over-installation.
    function testFuzz_installedLiquidityIsMaximal(uint32 spacing, int256 a, int256 b, uint128 supply, bool tokenIs0)
        public
    {
        spacing = uint32(bound(spacing, 1, MAX_TICK_SPACING));
        int256 highIndex = int256(MAX_TICK) / int256(uint256(spacing));
        a = bound(a, -highIndex, highIndex - 1);
        b = bound(b, a + 1, highIndex);
        supply = uint128(bound(supply, 1, I128_MAX));
        _quote(tokenIs0, 18);
        IZeroSeedLaunch.LaunchParameters memory p =
            _geometry(int32(a * int256(uint256(spacing))), int32(b * int256(uint256(spacing))), spacing, supply);
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
                    ? createPositionId(bytes24(0), p.askTick, p.upperTick)
                    : createPositionId(bytes24(0), -p.upperTick, -p.askTick),
                initialTick: tokenIs0 ? p.askTick : -p.askTick,
                liquidity: 0,
                installedSupply: 0
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

    /// A refused creation leaves nothing behind: no token code, no pool, no balance; the same salt then creates.
    function test_refusal_atomic_sameSaltCreatesAfterwards() public {
        IZeroSeedLaunch.LaunchParameters memory p = _geometry(-88080384, -85983232, 524288, 8690091540532083687);
        IZeroSeedLaunch.LaunchParameters memory valid = _geometry(-88080384, -85983232, 524288, 1e30);
        IZeroSeedLaunch.Installation memory preview = periphery.previewInstallation(creator, valid);
        uint256 coreBalance = ERC20(QUOTE_HIGH).balanceOf(CORE);
        vm.prank(creator);
        vm.expectRevert(IZeroSeedLaunch.ZeroLiquidity.selector);
        periphery.create(p);
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
        IZeroSeedLaunch.Installation memory inst = periphery.create(p);
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
            _measureCreate("lowAsk1e30", _geometry(-88080384, -85983232, 524288, 1e30));
            _measureCreate("lowAskTwoUnits", _geometry(-88080384, -85983232, 524288, 17380183081064167375));
            _measureCreate("fullWidth", _geometry(-88722835, 88722835, 1, 170141183460469231694794709727778658247));
            _measureCreate("adjacentBottom", _geometry(-88722835, -88722834, 1, I128_MAX));
            _measureCreate("threeRegions", _geometry(-44361442, 44361442, 2, 1e27));
        }
        _quote(true, 6);
        _measureCreate("fixture18/6", _parameters(ASK_18_6, REQUESTED_SUPPLY, DECAY_RATE));
        _quote(false, 6);
        _measureCreate("fixture18/6", _parameters(ASK_18_6, REQUESTED_SUPPLY, DECAY_RATE));
    }
}

