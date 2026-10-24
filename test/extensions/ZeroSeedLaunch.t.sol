// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IZeroSeedLaunch} from "../../src/interfaces/extensions/IZeroSeedLaunch.sol";
import {ZeroSeedLaunch, zeroSeedLaunchCallPoints, MAX_CREATOR_FEE} from "../../src/extensions/ZeroSeedLaunch.sol";
import {ZeroSeedLaunchPeriphery} from "../../src/ZeroSeedLaunchPeriphery.sol";
import {IZeroSeedLaunchPeriphery} from "../../src/interfaces/IZeroSeedLaunchPeriphery.sol";
import {NATIVE_TOKEN_ADDRESS} from "../../src/math/constants.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {MintableERC20} from "../../src/MintableERC20.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {CoreStorageLayout} from "../../src/libraries/CoreStorageLayout.sol";
import {StorageSlot} from "../../src/types/storageSlot.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolConfig} from "../../src/types/poolConfig.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {PositionId, createPositionId} from "../../src/types/positionId.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {liquidityDeltaToAmountDelta} from "../../src/math/liquidity.sol";
import {AmountBeforeFeeOverflow} from "../../src/math/fee.sol";
import {decayedFee, MAX_DECAY_PRODUCT} from "../../src/math/feeDecay.sol";
import {LaunchTestRouter} from "../LaunchTestRouter.sol";

/// @dev Plain ERC-20 for alternate token-order and decimal math coverage. The deployment quote is native ETH.
contract DecimalsToken is ERC20 {
    uint8 private immutable _DECIMALS;

    constructor(address recipient, uint8 decimals_) {
        _DECIMALS = decimals_;
        _mint(recipient, type(uint128).max);
    }

    function name() public pure override returns (string memory) {
        return "Quote";
    }

    function symbol() public pure override returns (string memory) {
        return "Q";
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }
}

/// @dev Test locker: forwarded swaps (what routers do), direct Core swaps and foreign positions (bypass attempts).
/// Settles native ETH from its own balance (the test funds it) and pays ETH outputs to the account.
contract LaunchSwapper is BaseLocker {
    using CoreLib for ICore;
    using FlashAccountantLib for *;

    uint256 constant FORWARD = 0;
    uint256 constant DIRECT = 1;
    uint256 constant POSITION = 2;

    constructor(ICore core) BaseLocker(core) {}

    function forwardSwap(PoolKey memory key, SwapParameters params) external returns (PoolBalanceUpdate) {
        return abi.decode(lock(abi.encode(FORWARD, msg.sender, key, params)), (PoolBalanceUpdate));
    }

    function directSwap(PoolKey memory key, SwapParameters params) external returns (PoolBalanceUpdate) {
        return abi.decode(lock(abi.encode(DIRECT, msg.sender, key, params)), (PoolBalanceUpdate));
    }

    function addPosition(PoolKey memory key, PositionId positionId, int128 liquidity) external {
        lock(abi.encode(POSITION, msg.sender, key, positionId, liquidity));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        uint256 kind = abi.decode(data, (uint256));
        if (kind == POSITION) {
            (,, PoolKey memory key, PositionId positionId, int128 liquidity) =
                abi.decode(data, (uint256, address, PoolKey, PositionId, int128));
            ICore(payable(address(ACCOUNTANT))).updatePosition(key, positionId, liquidity);
            return "";
        }
        (, address payer, PoolKey memory key, SwapParameters params) =
            abi.decode(data, (uint256, address, PoolKey, SwapParameters));
        PoolBalanceUpdate update;
        if (kind == FORWARD) {
            (update,) = abi.decode(
                ACCOUNTANT.forward(key.config.extension(), abi.encode(key, params)), (PoolBalanceUpdate, PoolState)
            );
        } else {
            (update,) = ICore(payable(address(ACCOUNTANT))).swap(0, key, params);
        }
        _settle(key.token0, update.delta0(), payer);
        _settle(key.token1, update.delta1(), payer);
        return abi.encode(update);
    }

    function _settle(address token, int128 delta, address account) private {
        if (delta > 0) {
            if (token == NATIVE_TOKEN_ADDRESS) SafeTransferLib.safeTransferETH(address(ACCOUNTANT), uint128(delta));
            else ACCOUNTANT.payFrom(account, token, uint128(delta));
        } else if (delta < 0) {
            ACCOUNTANT.withdraw(token, account, uint128(-delta));
        }
    }

    receive() external payable {}
}

abstract contract ZeroSeedLaunchBase is Test {
    using CoreLib for ICore;

    address payable constant CORE = payable(0x00000000000014aA86C5d3c41765bb24e11bd701);
    uint256 constant Q64 = 1 << 64;
    /// @dev floor(2**64 * 5 / 100) and floor(2**64 * 3 / 1000): 5% -> 0.3% local reference parameters.
    uint64 constant FEE_5 = 922337203685477580;
    uint64 constant FEE_03 = 55340232221128654;
    /// @dev Q32.32 ticks per second. floor(2 * ln(2) / ln(1.000001) * 2**32 / halfLife): the excess fee halves every
    /// 1,386,295.05 ticks, so these are a one-day half-life (the consumer-side default) and a 600 second half-life.
    uint64 constant DECAY_RATE = 68913100933;
    uint64 constant DECAY_RATE_600 = 9923486534471;
    uint256 constant HALF_LIFE = 86400;
    uint256 constant HALF_LIFE_600 = 600;
    uint64 constant START = 1000;
    uint32 constant SPACING = 100;
    /// @dev ln(100)/ln(1.000001) = 4605172.4, rounded up to the spacing: upper/ask = 1.000001**4605200 = 100.0028x.
    int32 constant WIDTH = 4605200;
    /// @dev 18/18: ask 1e-6 raw quote per raw token (1e-6 quote per token), tick floor(ln(1e-6)/ln(1.000001)) aligned.
    int32 constant ASK_18_18 = -13815500;
    /// @dev 18/6: ask 1e-18 raw (1e-6 six-decimal quote per 18-decimal token).
    int32 constant ASK_18_6 = -41446500;
    uint128 constant REQUESTED_SUPPLY = 1_000_000_000e18;
    /// @dev Core rounds every swap in the pool's favour, so Core holds at least principal + fees; the excess is
    /// reported in the vectors. Bound: 1e-12 of supply in raw units (1e15 of 1e27).
    uint256 constant MAX_DUST = 1e15;

    /// @dev Quote at the top of the address space makes the launch token token0; at 0x10000 it makes it token1.
    address constant QUOTE_HIGH = address(type(uint160).max);
    address constant QUOTE_LOW = address(0x10000);

    ZeroSeedLaunch launch;
    ZeroSeedLaunchPeriphery periphery;
    LaunchSwapper swapper;
    /// @dev Quote selected for the next launch in this test; `address(0)` is native ETH.
    address activeQuote;
    address creator = makeAddr("creator");
    address feeRecipient = makeAddr("feeRecipient");

    function setUp() public virtual {
        vm.warp(1);
        deployCodeTo("Core.sol:Core", CORE);
        swapper = new LaunchSwapper(ICore(CORE));
        // The swapper is the test's native purse: it pays ETH debts from this balance and receives ETH outputs.
        vm.deal(address(swapper), type(uint128).max);
        _quote(true, 18);
    }

    /// @dev Balance in `token` units. The test's native purse is this contract plus the swapper, which pays the
    /// test's ETH debts from its own balance while ETH outputs are withdrawn to this contract.
    function _balance(address token, address who) internal view returns (uint256) {
        if (token != NATIVE_TOKEN_ADDRESS) return ERC20(token).balanceOf(who);
        return who == address(this) ? address(this).balance + address(swapper).balance : who.balance;
    }

    function _approveQuote(address quote, address spender) internal {
        if (quote != NATIVE_TOKEN_ADDRESS) ERC20(quote).approve(spender, type(uint256).max);
    }

    receive() external payable {}

    function _launchTarget() internal pure returns (address) {
        return address(uint160(zeroSeedLaunchCallPoints().toUint8()) << 152);
    }

    /// @dev Artifact deployed at the extension address; a study harness may substitute a comparator variant.
    function _launchArtifact() internal view virtual returns (string memory) {
        return "ZeroSeedLaunch.sol:ZeroSeedLaunch";
    }

    /// @dev Deploys the extension at its callpoint address with `quote` selected for subsequent launches and a fresh
    /// periphery for it. A test that switches quote redeploys at the same address, so the Core registration flag is
    /// cleared first; launch storage and token addresses stay where they were.
    function _deployLaunch(address quote) internal {
        address target = _launchTarget();
        vm.store(CORE, StorageSlot.unwrap(CoreStorageLayout.isExtensionRegisteredSlot(target)), bytes32(0));
        deployCodeTo(_launchArtifact(), abi.encode(CORE), target);
        launch = ZeroSeedLaunch(target);
        periphery = new ZeroSeedLaunchPeriphery(ICore(CORE), launch);
        activeQuote = quote;
        assertEq(address(periphery.LAUNCH()), target, "periphery extension");
    }

    /// @dev Quote for the requested order: a token0 launch needs a plain ERC-20 above every token address;
    /// a token1 launch uses native ETH (`address(0)`) for 18
    /// decimals, the reference Base configuration, and the 6-decimal token at a low address otherwise. Redeploys
    /// the extension to reset the test state.
    function _quote(bool tokenIs0, uint8 quoteDecimals) internal returns (address quote) {
        if (!tokenIs0 && quoteDecimals == 18) {
            quote = NATIVE_TOKEN_ADDRESS;
        } else {
            quote = tokenIs0 ? QUOTE_HIGH : QUOTE_LOW;
            deployCodeTo("ZeroSeedLaunch.t.sol:DecimalsToken", abi.encode(address(this), quoteDecimals), quote);
            ERC20(quote).approve(address(swapper), type(uint256).max);
        }
        _deployLaunch(quote);
    }

    function _parameters(int32 ask, uint128 supply, uint64 decayRateX32)
        internal
        view
        returns (IZeroSeedLaunch.LaunchParameters memory)
    {
        return IZeroSeedLaunch.LaunchParameters({
            name: "Zero Seed",
            symbol: "ZERO",
            decimals: 18,
            supply: supply,
            quoteToken: activeQuote,
            askTick: ask,
            upperTick: ask + WIDTH,
            tickSpacing: SPACING,
            tradingStart: START,
            decayRateX32: decayRateX32,
            initialFee: FEE_5,
            finalFee: FEE_03,
            salt: bytes32(uint256(1))
        });
    }

    /// @dev Checks preview feasibility without rewriting the requested supply.
    function _bind(IZeroSeedLaunch.LaunchParameters memory p, address who) internal view {
        IZeroSeedLaunch.Installation memory preview = periphery.previewInstallation(who, p);
        assertLe(preview.installedSupply, p.supply, "installation fits supply");
    }

    function _create(bool tokenIs0, uint8 quoteDecimals, uint64 decayRateX32)
        internal
        returns (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p)
    {
        _quote(tokenIs0, quoteDecimals);
        p = _parameters(quoteDecimals == 18 ? ASK_18_18 : ASK_18_6, REQUESTED_SUPPLY, decayRateX32);
        _bind(p, creator);
        vm.prank(creator);
        inst = periphery.create(p);
        MintableERC20(inst.token).approve(address(swapper), type(uint256).max);
    }

    function _launchToken(PoolKey memory key, address quote) internal pure returns (address) {
        return key.token0 == quote ? key.token1 : key.token0;
    }

    /// @dev Buy = quote in, launch token out. exactOut flips the specified side.
    function _buy(PoolKey memory key, address token, int128 amount, bool exactOut)
        internal
        returns (PoolBalanceUpdate)
    {
        bool tokenIs1 = key.token1 == token;
        // exact input specifies quote; exact output specifies the launch token, negatively.
        bool specifiedIs1 = exactOut ? tokenIs1 : !tokenIs1;
        return
            swapper.forwardSwap(
                key, createSwapParameters(SqrtRatio.wrap(0), exactOut ? -amount : amount, specifiedIs1, 0)
            );
    }

    function _sell(PoolKey memory key, address token, int128 amount, bool exactOut)
        internal
        returns (PoolBalanceUpdate)
    {
        bool tokenIs1 = key.token1 == token;
        bool specifiedIs1 = exactOut ? !tokenIs1 : tokenIs1;
        return
            swapper.forwardSwap(
                key, createSwapParameters(SqrtRatio.wrap(0), exactOut ? -amount : amount, specifiedIs1, 0)
            );
    }

    function _tokenDelta(PoolKey memory key, address token, PoolBalanceUpdate u) internal pure returns (int128) {
        return key.token0 == token ? u.delta0() : u.delta1();
    }

    function _quoteDelta(PoolKey memory key, address token, PoolBalanceUpdate u) internal pure returns (int128) {
        return key.token0 == token ? u.delta1() : u.delta0();
    }

    function _principal(IZeroSeedLaunch.Installation memory inst)
        internal
        view
        returns (uint128 amount0, uint128 amount1)
    {
        PoolId id = inst.poolKey.toPoolId();
        uint128 liquidity = ICore(CORE).poolPositions(id, address(launch), inst.positionId).liquidity;
        (int128 d0, int128 d1) = liquidityDeltaToAmountDelta(
            ICore(CORE).poolState(id).sqrtRatio(),
            -int128(liquidity),
            tickToSqrtRatio(inst.positionId.tickLower()),
            tickToSqrtRatio(inst.positionId.tickUpper())
        );
        amount0 = uint128(-d0);
        amount1 = uint128(-d1);
    }

    /// @dev Token: Core holds principal + fee ledger + rounding dust, and Core + everyone else = supply.
    /// Quote: Core holds exactly what was paid in minus paid out, = principal + fee ledger + dust.
    function _assertLedger(
        IZeroSeedLaunch.Installation memory inst,
        address quote,
        uint256 quoteIn,
        uint256 quoteOut,
        uint256 maxDust
    ) internal view returns (uint256 tokenDust, uint256 quoteDust) {
        PoolKey memory key = inst.poolKey;
        bool tokenIs0 = key.token0 == inst.token;
        (uint128 p0, uint128 p1) = _principal(inst);
        (uint128 f0, uint128 f1) = launch.creatorFees(key);
        uint256 coreToken = ERC20(inst.token).balanceOf(CORE);
        uint256 coreQuote = _balance(quote, CORE);
        assertEq(
            ERC20(inst.token).totalSupply(),
            inst.installedSupply + ERC20(inst.token).balanceOf(address(0)),
            "fixed supply"
        );
        uint256 outside = ERC20(inst.token).balanceOf(address(this)) + ERC20(inst.token).balanceOf(feeRecipient)
            + ERC20(inst.token).balanceOf(creator);
        assertEq(coreToken + outside, inst.installedSupply, "token conservation");
        assertEq(coreQuote + quoteOut, quoteIn, "quote conservation");
        uint256 tokenBooked = uint256(tokenIs0 ? p0 : p1) + (tokenIs0 ? f0 : f1);
        uint256 quoteBooked = uint256(tokenIs0 ? p1 : p0) + (tokenIs0 ? f1 : f0);
        assertLe(tokenBooked, coreToken, "token principal+fees <= Core");
        assertLe(quoteBooked, coreQuote, "quote principal+fees <= Core");
        tokenDust = coreToken - tokenBooked;
        quoteDust = coreQuote - quoteBooked;
        assertLe(tokenDust, maxDust, "token dust");
        assertLe(quoteDust, maxDust, "quote dust");
        assertLe(uint256(tokenIs0 ? p0 : p1), inst.installedSupply, "x <= S");
        assertEq(ERC20(inst.token).balanceOf(address(launch)), 0, "no custody token: extension");
        assertEq(ERC20(inst.token).balanceOf(address(periphery)), 0, "no custody token: periphery");
        assertEq(ERC20(inst.token).balanceOf(address(swapper)), 0, "no custody token: swapper");
        assertEq(_balance(quote, address(launch)), 0, "no custody quote: extension");
        assertEq(_balance(quote, address(periphery)), 0, "no custody quote: periphery");
        if (quote != NATIVE_TOKEN_ADDRESS) assertEq(_balance(quote, address(swapper)), 0, "no custody quote: swapper");
    }

    /// @dev Timestamp clamp plus the shared decay math; exact values are pinned by the vectors tests and the Python
    /// reference, which recomputes the tick chain and the floor independently.
    function _referenceFee(uint64 initialFee, uint64 finalFee, uint256 start, uint64 decayRateX32, uint256 t)
        internal
        pure
        returns (uint64)
    {
        if (t <= start) return initialFee;
        return decayedFee(initialFee, finalFee, decayRateX32, t - start);
    }

    /// @dev Last elapsed second whose accumulated tick magnitude the helper still supports; one second later the
    /// schedule saturates to `finalFee`.
    function _saturationSecond(uint64 decayRateX32) internal pure returns (uint256) {
        return MAX_DECAY_PRODUCT / decayRateX32;
    }

    function _str(int256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }

    function _ustr(uint256 v) internal pure returns (string memory) {
        return vm.toString(v);
    }
}

contract ZeroSeedLaunchCreationTest is ZeroSeedLaunchBase {
    using CoreLib for ICore;

    function _checkCreation(bool tokenIs0, uint8 quoteDecimals) internal {
        (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p) =
            _create(tokenIs0, quoteDecimals, DECAY_RATE);
        PoolKey memory key = inst.poolKey;
        PoolId id = key.toPoolId();
        assertEq(key.token0 == inst.token, tokenIs0, "order");
        assertEq(key.config.fee(), 0, "core fee zero");
        assertEq(key.config.extension(), address(launch), "extension");
        assertEq(
            inst.installedSupply + ERC20(inst.token).balanceOf(address(0)), p.supply, "requested == installed + sunk"
        );
        assertLe(p.supply, REQUESTED_SUPPLY, "installable <= requested");
        assertGt(inst.liquidity, 0, "computed liquidity");
        assertEq(MintableERC20(inst.token).totalSupply(), p.supply, "minted == requested");
        assertEq(MintableERC20(inst.token).owner(), address(0), "mint authority renounced");
        assertEq(MintableERC20(inst.token).decimals(), 18, "decimals");
        assertEq(ERC20(inst.token).balanceOf(CORE), inst.installedSupply, "installed supply in Core");
        assertEq(_balance(activeQuote, CORE), 0, "actual quote = 0");
        PoolState state = ICore(CORE).poolState(id);
        int32 economicAsk = tokenIs0 ? state.tick() : -state.tick();
        assertEq(economicAsk, p.askTick, "starts at ask");
        assertEq(state.tick(), inst.initialTick, "initial tick");
        assertEq(ICore(CORE).poolPositions(id, address(launch), inst.positionId).liquidity, inst.liquidity, "liquidity");
        assertEq(inst.positionId.tickLower(), tokenIs0 ? p.askTick : -p.upperTick, "tickLower");
        assertEq(inst.positionId.tickUpper(), tokenIs0 ? p.upperTick : -p.askTick, "tickUpper");
        (uint128 p0, uint128 p1) = _principal(inst);
        assertEq(tokenIs0 ? p1 : p0, 0, "principal quote = 0");
        // Withdrawable principal rounds down: at most the installation rounding below S.
        assertLe(inst.installedSupply - (tokenIs0 ? p0 : p1), 1, "principal token ~ installed");
        (uint128 f0, uint128 f1) = launch.creatorFees(key);
        assertEq(f0 + f1, 0, "no fees");
        IZeroSeedLaunch.Launch memory l = launch.getLaunch(id);
        assertEq(l.controller, address(periphery), "controller is the periphery");
        assertEq(periphery.launchOwner(id), creator, "owner is the creator");
        console2.log(
            string.concat(
                "VEC|create|order=",
                tokenIs0 ? "t0" : "t1",
                "|dec=18/",
                _ustr(quoteDecimals),
                "|ask=",
                _str(p.askTick),
                "|upper=",
                _str(p.upperTick),
                "|requested=",
                _ustr(REQUESTED_SUPPLY),
                "|installed=",
                _ustr(inst.installedSupply),
                "|liquidity=",
                _ustr(inst.liquidity),
                "|tickLower=",
                _str(inst.positionId.tickLower()),
                "|tickUpper=",
                _str(inst.positionId.tickUpper()),
                "|initialTick=",
                _str(inst.initialTick),
                "|withdrawable=",
                _ustr(tokenIs0 ? p0 : p1)
            )
        );
    }

    function test_create_token0_18_18() public {
        _checkCreation(true, 18);
    }

    function test_create_token1_18_18() public {
        _checkCreation(false, 18);
    }

    function test_create_token0_18_6() public {
        _checkCreation(true, 6);
    }

    function test_create_token1_18_6() public {
        _checkCreation(false, 6);
    }

    function test_create_roundSupplySinksRemainderBothOrders() public {
        for (uint256 i; i < 2; i++) {
            bool tokenIs0 = i == 0;
            _quote(tokenIs0, 18);
            IZeroSeedLaunch.LaunchParameters memory p = _parameters(ASK_18_18, REQUESTED_SUPPLY, DECAY_RATE);
            IZeroSeedLaunch.Installation memory preview = periphery.previewInstallation(creator, p);
            assertTrue(preview.installedSupply != p.supply, "requested is not exact");
            vm.prank(creator);
            IZeroSeedLaunch.Installation memory installed = periphery.create(p);
            assertEq(installed.liquidity, preview.liquidity);
            assertEq(ERC20(installed.token).totalSupply(), REQUESTED_SUPPLY);
            assertEq(ERC20(installed.token).balanceOf(CORE), preview.installedSupply);
            assertEq(ERC20(installed.token).balanceOf(address(0)), p.supply - preview.installedSupply);
            assertEq(ERC20(installed.token).balanceOf(address(launch)), 0);
            assertEq(MintableERC20(installed.token).owner(), address(0));
        }
    }

    function test_create_refusesInvalidParameters() public {
        _quote(true, 18);
        IZeroSeedLaunch.LaunchParameters memory base = _parameters(ASK_18_18, REQUESTED_SUPPLY, DECAY_RATE);
        _bind(base, creator);
        IZeroSeedLaunch.LaunchParameters memory p;

        p = _copy(base);
        p.name = "abcdefghijklmnopqrstuvwxyz012345"; // 32 bytes
        _expectCreateRevert(p, abi.encodeWithSelector(IZeroSeedLaunch.MetadataTooLong.selector));
        p = _copy(base);
        p.symbol = "abcdefghijklmnopqrstuvwxyz012345";
        _expectCreateRevert(p, abi.encodeWithSelector(IZeroSeedLaunch.MetadataTooLong.selector));
        p = _copy(base);
        p.supply = 0;
        _expectCreateRevert(p, abi.encodeWithSelector(IZeroSeedLaunch.InvalidParameters.selector));
        p = _copy(base);
        p.supply = uint128(type(int128).max) + 1;
        _expectCreateRevert(p, abi.encodeWithSelector(IZeroSeedLaunch.InvalidParameters.selector));
        p = _copy(base);
        p.upperTick = p.askTick;
        _expectCreateRevert(p, abi.encodeWithSelector(IZeroSeedLaunch.InvalidParameters.selector));
        p = _copy(base);
        p.tickSpacing = 0;
        _expectCreateRevert(p, abi.encodeWithSelector(IZeroSeedLaunch.InvalidParameters.selector));
        // No rate ceiling below the type: the only schedule rule is final <= initial; any decay rate is accepted.
        p = _copy(base);
        p.finalFee = p.initialFee + 1;
        _expectCreateRevert(p, abi.encodeWithSelector(IZeroSeedLaunch.InvalidFeeSchedule.selector));
        p = _copy(base);
        p.initialFee = type(uint64).max - 1;
        p.finalFee = type(uint64).max;
        _expectCreateRevert(p, abi.encodeWithSelector(IZeroSeedLaunch.InvalidFeeSchedule.selector));
        p = _copy(base);
        p.initialFee = 0;
        p.finalFee = 1;
        _expectCreateRevert(p, abi.encodeWithSelector(IZeroSeedLaunch.InvalidFeeSchedule.selector));
        p = _copy(base);
        p.finalFee = p.initialFee + 1;
        p.decayRateX32 = 0;
        _expectCreateRevert(p, abi.encodeWithSelector(IZeroSeedLaunch.InvalidFeeSchedule.selector));
        vm.expectRevert(IZeroSeedLaunch.InvalidFeeSchedule.selector);
        periphery.previewInstallation(creator, p);
        vm.warp(START + 1);
        _expectCreateRevert(base, abi.encodeWithSelector(IZeroSeedLaunch.InvalidTradingStart.selector));
        vm.warp(1);
        p = _copy(base);
        p.askTick += 1; // misaligned bound
        p.upperTick += 1;
        vm.prank(creator);
        vm.expectRevert();
        periphery.create(p);
        // The whole uint64 range is accepted at both ends of the schedule, as are the fastest and the slowest decay
        // rates and a zero rate; the full maximum-rate matrix is in ZeroSeedLaunchFeeCurve.t.sol.
        assertEq(MAX_CREATOR_FEE, type(uint64).max, "ceiling is the type maximum");
        p = _copy(base);
        p.initialFee = MAX_CREATOR_FEE;
        p.decayRateX32 = type(uint64).max;
        vm.prank(creator);
        IZeroSeedLaunch.Installation memory inst = periphery.create(p);
        assertEq(launch.getLaunch(inst.poolKey.toPoolId()).initialFee, MAX_CREATOR_FEE, "stored as given");
        assertEq(launch.getLaunch(inst.poolKey.toPoolId()).decayRateX32, type(uint64).max, "stored rate");
        assertEq(launch.feeAt(inst.poolKey.toPoolId(), START), MAX_CREATOR_FEE, "initial at the start");
        assertEq(launch.feeAt(inst.poolKey.toPoolId(), START + 1), FEE_03, "fastest rate saturates in one second");
        p = _copy(base);
        p.salt = bytes32(uint256(2));
        p.initialFee = MAX_CREATOR_FEE;
        p.finalFee = MAX_CREATOR_FEE;
        p.decayRateX32 = 1;
        vm.prank(creator);
        inst = periphery.create(p);
        assertEq(launch.getLaunch(inst.poolKey.toPoolId()).finalFee, MAX_CREATOR_FEE, "stored as given");
        assertEq(launch.feeAt(inst.poolKey.toPoolId(), type(uint256).max), MAX_CREATOR_FEE, "flat at equal fees");
        p = _copy(base);
        p.salt = bytes32(uint256(3));
        p.initialFee = 0;
        p.finalFee = 0;
        vm.prank(creator);
        inst = periphery.create(p);
        assertEq(launch.feeAt(inst.poolKey.toPoolId(), START + 1), 0, "zero schedule");
        p = _copy(base);
        p.salt = bytes32(uint256(4));
        p.decayRateX32 = 0;
        vm.prank(creator);
        inst = periphery.create(p);
        assertEq(launch.feeAt(inst.poolKey.toPoolId(), START + 1), FEE_5, "zero rate: flat at the initial fee");
        assertEq(launch.feeAt(inst.poolKey.toPoolId(), type(uint256).max), FEE_5, "zero rate never reaches the floor");
    }

    function testFuzz_roundSupplyConservation(uint128 supply, bool tokenIs0) public {
        supply = uint128(bound(supply, 1e18, 1_000_000_000_000e18));
        _quote(tokenIs0, 18);
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(ASK_18_18, supply, DECAY_RATE);
        IZeroSeedLaunch.Installation memory preview = periphery.previewInstallation(creator, p);
        vm.prank(creator);
        IZeroSeedLaunch.Installation memory inst = periphery.create(p);
        assertEq(inst.liquidity, preview.liquidity);
        assertEq(inst.installedSupply, preview.installedSupply);
        assertEq(ERC20(inst.token).totalSupply(), supply);
        assertEq(ERC20(inst.token).balanceOf(CORE) + ERC20(inst.token).balanceOf(address(0)), supply);
        assertEq(ERC20(inst.token).balanceOf(CORE), inst.installedSupply);
        (SqrtRatio initial, SqrtRatio lower, SqrtRatio upper) = (
            tickToSqrtRatio(inst.initialTick),
            tickToSqrtRatio(inst.positionId.tickLower()),
            tickToSqrtRatio(inst.positionId.tickUpper())
        );
        (int128 next0, int128 next1) = liquidityDeltaToAmountDelta(initial, int128(inst.liquidity + 1), lower, upper);
        assertGt(uint128(tokenIs0 ? next0 : next1), supply, "next liquidity unit exceeds budget");
    }

    function test_create_maxSupportedSupply() public {
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(-80_000_000, uint128(type(int128).max), DECAY_RATE);
        vm.prank(creator);
        IZeroSeedLaunch.Installation memory inst = periphery.create(p);
        assertEq(ERC20(inst.token).totalSupply(), p.supply);
        assertEq(inst.installedSupply + ERC20(inst.token).balanceOf(address(0)), p.supply);
    }

    function test_create_refusesLiquidityAboveTickCapBothOrders() public {
        for (uint256 i; i < 2; i++) {
            _quote(i == 0, 18);
            IZeroSeedLaunch.LaunchParameters memory p = _parameters(80_000_000, uint128(type(int128).max), DECAY_RATE);
            vm.expectRevert();
            periphery.previewInstallation(creator, p);
            vm.prank(creator);
            vm.expectPartialRevert(IZeroSeedLaunch.LiquidityAboveTickCap.selector);
            periphery.create(p);
            try periphery.previewInstallation(creator, p) {}
            catch (bytes memory reason) {
                assertEq(bytes4(reason), IZeroSeedLaunch.LiquidityAboveTickCap.selector, "tick cap");
            }
        }
    }

    function test_create_refusesZeroLiquidity() public {
        _quote(true, 18);
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(-80_000_000, 1, DECAY_RATE);
        vm.expectRevert(IZeroSeedLaunch.ZeroLiquidity.selector);
        periphery.previewInstallation(creator, p);
        vm.prank(creator);
        vm.expectRevert(IZeroSeedLaunch.ZeroLiquidity.selector);
        periphery.create(p);
    }

    function test_create_sameSaltSameCreatorRefused_otherCreatorIndependent() public {
        (IZeroSeedLaunch.Installation memory first, IZeroSeedLaunch.LaunchParameters memory p) =
            _create(true, 18, DECAY_RATE);
        bytes memory exists = abi.encodeWithSelector(IZeroSeedLaunch.LaunchTokenExists.selector, first.token);
        vm.expectRevert(exists);
        periphery.previewInstallation(creator, p);
        vm.prank(creator);
        vm.expectRevert(exists);
        periphery.create(p);
        // Another creator with the same parameters gets a different token address and its own pool.
        address other = makeAddr("other");
        p.supply = REQUESTED_SUPPLY;
        _bind(p, other);
        vm.prank(other);
        IZeroSeedLaunch.Installation memory inst = periphery.create(p);
        assertEq(periphery.launchOwner(inst.poolKey.toPoolId()), other, "other owner");
        assertEq(launch.getLaunch(inst.poolKey.toPoolId()).controller, address(periphery), "same controller");
    }

    function _copy(IZeroSeedLaunch.LaunchParameters memory p)
        internal
        pure
        returns (IZeroSeedLaunch.LaunchParameters memory c)
    {
        c = abi.decode(abi.encode(p), (IZeroSeedLaunch.LaunchParameters));
    }

    function _expectCreateRevert(IZeroSeedLaunch.LaunchParameters memory p, bytes memory reason) internal {
        vm.prank(creator);
        vm.expectRevert(reason);
        periphery.create(p);
    }
}

contract ZeroSeedLaunchSecurityTest is ZeroSeedLaunchBase {
    using CoreLib for ICore;

    function test_bypass_directCoreSwapRefused() public {
        for (uint256 i; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            (IZeroSeedLaunch.Installation memory inst,) = _create(i == 0, 18, DECAY_RATE);
            vm.warp(START);
            bool tokenIs1 = inst.poolKey.token1 == inst.token;
            vm.expectRevert(IZeroSeedLaunch.SwapsThroughForwardOnly.selector);
            swapper.directSwap(
                inst.poolKey, createSwapParameters(SqrtRatio.wrap(0), 1e18, !tokenIs1, 0).withDefaultSqrtRatioLimit()
            );
            vm.revertToState(snap);
        }
    }

    function test_bypass_foreignPositionRefused() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, DECAY_RATE);
        vm.expectRevert(IZeroSeedLaunch.PositionsThroughCreateOnly.selector);
        swapper.addPosition(inst.poolKey, createPositionId(bytes24(0), -1_000_000, 1_000_000), 1e18);
        // Same bounds as the launch position, different owner: still refused.
        vm.expectRevert(IZeroSeedLaunch.PositionsThroughCreateOnly.selector);
        swapper.addPosition(inst.poolKey, inst.positionId, 1);
    }

    function test_bypass_foreignInitializeRefused() public {
        address quote = _quote(true, 18);
        PoolKey memory key = PoolKey({token0: address(0x1234), token1: quote, config: launchConfig(address(launch))});
        vm.expectRevert(IZeroSeedLaunch.InitializeThroughCreateOnly.selector);
        ICore(CORE).initializePool(key, 0);
    }

    function launchConfig(address ext) internal pure returns (PoolConfig) {
        return PoolConfig.wrap(bytes32((uint256(uint160(ext)) << 96) | 0x80000000 | uint256(SPACING)));
    }

    function test_forward_unknownLaunchAndBeforeStartRefused() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, DECAY_RATE);
        PoolKey memory unknown = PoolKey(address(0x1234), inst.poolKey.token1, inst.poolKey.config);
        vm.expectRevert(IZeroSeedLaunch.UnknownLaunch.selector);
        swapper.forwardSwap(unknown, createSwapParameters(SqrtRatio.wrap(0), 1e18, true, 0));
        vm.warp(START - 1);
        vm.expectRevert(IZeroSeedLaunch.TradingNotStarted.selector);
        _buy(inst.poolKey, inst.token, 1e18, false);
        vm.warp(START);
        _buy(inst.poolKey, inst.token, 1e18, false);
    }

    function test_forwardee_onlyCore() public {
        (bool ok,) = address(launch).call(abi.encodeWithSelector(bytes4(uint32(1)), bytes32(0)));
        assertFalse(ok, "forwarded() only from Core");
    }

    function test_claim_authenticationAndRecipient() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, DECAY_RATE);
        vm.warp(START);
        _buy(inst.poolKey, inst.token, 1e18, false);
        vm.expectRevert(IZeroSeedLaunchPeriphery.OwnerOnly.selector);
        periphery.claimFees(inst.poolKey, address(this));
        address[6] memory sinks =
            [address(0), CORE, address(launch), address(periphery), inst.poolKey.token0, inst.poolKey.token1];
        for (uint256 i; i < sinks.length; i++) {
            vm.prank(creator);
            vm.expectRevert(IZeroSeedLaunchPeriphery.InvalidRecipient.selector);
            periphery.claimFees(inst.poolKey, sinks[i]);
        }
        PoolKey memory unknown = PoolKey(address(0x1234), inst.poolKey.token1, inst.poolKey.config);
        vm.prank(creator);
        vm.expectRevert(IZeroSeedLaunchPeriphery.OwnerOnly.selector);
        periphery.claimFees(unknown, feeRecipient);
    }

    function test_claim_cannotTouchPrincipal() public {
        (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p) =
            _create(false, 18, DECAY_RATE);
        vm.warp(START);
        PoolBalanceUpdate u = _buy(inst.poolKey, inst.token, 5e18, false);
        uint256 quoteIn = uint128(_quoteDelta(inst.poolKey, inst.token, u));
        u = _sell(inst.poolKey, inst.token, 1_000_000e18, false);
        uint256 quoteOut = uint128(-_quoteDelta(inst.poolKey, inst.token, u));
        PoolId id = inst.poolKey.toPoolId();
        uint128 liquidityBefore = ICore(CORE).poolPositions(id, address(launch), inst.positionId).liquidity;
        PoolState stateBefore = ICore(CORE).poolState(id);
        (uint128 p0, uint128 p1) = _principal(inst);
        (uint128 f0, uint128 f1) = launch.creatorFees(inst.poolKey);
        assertGt(f0, 0, "fee0");
        assertGt(f1, 0, "fee1");
        vm.prank(creator);
        (uint128 c0, uint128 c1) = periphery.claimFees(inst.poolKey, feeRecipient);
        assertEq(c0, f0, "claimed0");
        assertEq(c1, f1, "claimed1");
        assertEq(_balance(inst.poolKey.token0, feeRecipient), f0, "recipient0");
        assertEq(_balance(inst.poolKey.token1, feeRecipient), f1, "recipient1");
        (uint128 q0, uint128 q1) = _principal(inst);
        assertEq(q0, p0, "principal0 unchanged");
        assertEq(q1, p1, "principal1 unchanged");
        assertEq(ICore(CORE).poolPositions(id, address(launch), inst.positionId).liquidity, liquidityBefore, "L");
        assertEq(PoolState.unwrap(ICore(CORE).poolState(id)), PoolState.unwrap(stateBefore), "pool state");
        (f0, f1) = launch.creatorFees(inst.poolKey);
        assertEq(f0 + f1, 0, "ledger emptied");
        uint256 claimedQuote = inst.poolKey.token0 == activeQuote ? c0 : c1;
        vm.prank(creator);
        (c0, c1) = periphery.claimFees(inst.poolKey, feeRecipient);
        assertEq(c0 + c1, 0, "second claim empty");
        _assertLedger(inst, activeQuote, quoteIn, quoteOut + claimedQuote, MAX_DUST);
    }

    /// @dev The creator buys first and is refunded its own fee through the claim: the fee is no protection
    /// against the creator, who pays only price impact.
    function test_creatorRecaptureDemonstration() public {
        (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p) =
            _create(true, 18, DECAY_RATE);
        ERC20(activeQuote).transfer(creator, 10e18);
        vm.startPrank(creator);
        ERC20(activeQuote).approve(address(swapper), type(uint256).max);
        vm.warp(START);
        PoolBalanceUpdate u = swapper.forwardSwap(inst.poolKey, createSwapParameters(SqrtRatio.wrap(0), 10e18, true, 0));
        uint256 bought = uint128(-u.delta0());
        periphery.claimFees(inst.poolKey, creator);
        vm.stopPrank();
        uint256 held = ERC20(inst.token).balanceOf(creator);
        assertGt(held, bought, "creator recovers its own fee");
        console2.log(
            string.concat("VEC|recapture|t0|quoteIn=10e18|netOfFee=", _ustr(bought), "|afterClaim=", _ustr(held))
        );
    }
}

contract ZeroSeedLaunchTradingTest is ZeroSeedLaunchBase {
    using CoreLib for ICore;

    struct Flow {
        uint256 quoteIn;
        uint256 quoteOut;
    }

    function _record(Flow memory f, PoolKey memory key, address token, PoolBalanceUpdate u) internal pure {
        int128 q = _quoteDelta(key, token, u);
        if (q > 0) f.quoteIn += uint128(q);
        else f.quoteOut += uint128(-q);
    }

    function _scenario(bool tokenIs0, uint8 quoteDecimals) internal {
        (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p) =
            _create(tokenIs0, quoteDecimals, DECAY_RATE);
        PoolKey memory key = inst.poolKey;
        address token = inst.token;
        address quote = activeQuote;
        Flow memory f;
        string memory tag = string.concat("VEC|trade|order=", tokenIs0 ? "t0" : "t1", "|dec=18/", _ustr(quoteDecimals));
        int128 unit = int128(uint128(10 ** quoteDecimals));
        vm.warp(START);

        // Sell before any buy: no bid, zero fill, no fee, nothing moves.
        PoolState s0 = ICore(CORE).poolState(key.toPoolId());
        PoolBalanceUpdate u = _sell(key, token, 1, false);
        assertEq(u.delta0(), 0, "no bid 0");
        assertEq(u.delta1(), 0, "no bid 1");
        assertEq(PoolState.unwrap(ICore(CORE).poolState(key.toPoolId())), PoolState.unwrap(s0), "unmoved");

        // First exact-input buy at 5%: fee in the launch token on the actual output.
        u = _buy(key, token, unit, false);
        _record(f, key, token, u);
        (uint128 f0, uint128 f1) = launch.creatorFees(key);
        uint128 feeToken = tokenIs0 ? f0 : f1;
        uint128 net = uint128(-_tokenDelta(key, token, u));
        uint128 gross = net + feeToken;
        assertEq(feeToken, uint128((uint256(gross) * FEE_5 + Q64 - 1) >> 64), "exact-in fee = ceil(gross*5%)");
        console2.log(
            string.concat(
                tag,
                "|buyExactIn|quoteIn=",
                _ustr(uint128(unit)),
                "|gross=",
                _ustr(gross),
                "|fee=",
                _ustr(feeToken),
                "|net=",
                _ustr(net)
            )
        );

        // Exact-output buy: gross-up in quote on the actual input.
        (f0, f1) = launch.creatorFees(key);
        uint128 feeQuoteBefore = tokenIs0 ? f1 : f0;
        int128 want = int128(net);
        u = _buy(key, token, want, true);
        _record(f, key, token, u);
        assertEq(uint128(-_tokenDelta(key, token, u)), uint128(want), "exact-out filled");
        (f0, f1) = launch.creatorFees(key);
        uint128 feeQuote = (tokenIs0 ? f1 : f0) - feeQuoteBefore;
        uint128 paid = uint128(_quoteDelta(key, token, u));
        uint128 calc = paid - feeQuote;
        uint256 grossUp = (uint256(calc) << 64);
        uint256 d = Q64 - FEE_5;
        assertEq(paid, uint128(grossUp / d + (grossUp % d == 0 ? 0 : 1)), "exact-out gross-up");
        console2.log(
            string.concat(
                tag,
                "|buyExactOut|tokenOut=",
                _ustr(uint128(want)),
                "|calcQuote=",
                _ustr(calc),
                "|fee=",
                _ustr(feeQuote),
                "|paid=",
                _ustr(paid)
            )
        );

        // Sell back half the holdings, exact input, fee in quote on actual output.
        uint256 held = ERC20(token).balanceOf(address(this));
        u = _sell(key, token, int128(uint128(held / 2)), false);
        _record(f, key, token, u);
        console2.log(
            string.concat(
                tag, "|sellExactIn|tokenIn=", _ustr(held / 2), "|quoteOut=", _ustr(uint128(-_quoteDelta(key, token, u)))
            )
        );
        _assertLedger(inst, quote, f.quoteIn, f.quoteOut, MAX_DUST);

        // Reverse to the lower bound: sell everything held; the sell can return at most the real quote.
        held = ERC20(token).balanceOf(address(this));
        u = _sell(key, token, int128(uint128(held)), false);
        _record(f, key, token, u);
        PoolState st = ICore(CORE).poolState(key.toPoolId());
        int32 econTick = tokenIs0 ? st.tick() : -st.tick();
        assertGe(econTick, p.askTick - 1, "never below ask");
        // After returning to the ask nothing more can be sold: no bid.
        uint256 left = ERC20(token).balanceOf(address(this));
        if (left > 0) {
            u = _sell(key, token, int128(uint128(left)), false);
            _record(f, key, token, u);
        }
        (uint128 a0, uint128 a1) = _principal(inst);
        console2.log(
            string.concat(
                tag,
                "|reverse|leftHeld=",
                _ustr(ERC20(token).balanceOf(address(this))),
                "|principalQuote=",
                _ustr(tokenIs0 ? a1 : a0),
                "|principalToken=",
                _ustr(tokenIs0 ? a0 : a1)
            )
        );
        (uint256 tokenDust, uint256 quoteDust) = _assertLedger(inst, quote, f.quoteIn, f.quoteOut, MAX_DUST);
        console2.log(string.concat(tag, "|dust|token=", _ustr(tokenDust), "|quote=", _ustr(quoteDust)));

        // Upper exhaustion: an exact-output buy above remaining inventory fills only to the upper bound.
        (a0, a1) = _principal(inst);
        uint128 remaining = tokenIs0 ? a0 : a1;
        u = _buy(key, token, int128(remaining + 1e18), true);
        _record(f, key, token, u);
        uint128 got = uint128(-_tokenDelta(key, token, u));
        assertLt(got, remaining + 1e18, "partial");
        st = ICore(CORE).poolState(key.toPoolId());
        assertEq(
            SqrtRatio.unwrap(st.sqrtRatio()),
            SqrtRatio.unwrap(tickToSqrtRatio(tokenIs0 ? inst.positionId.tickUpper() : inst.positionId.tickLower())),
            "stopped at upper bound"
        );
        // Further buys fill nothing and pay nothing.
        u = _buy(key, token, unit, false);
        assertEq(u.delta0(), 0, "exhausted 0");
        assertEq(u.delta1(), 0, "exhausted 1");
        (a0, a1) = _principal(inst);
        console2.log(
            string.concat(
                tag,
                "|exhaust|requested=",
                _ustr(remaining + 1e18),
                "|got=",
                _ustr(got),
                "|principalToken=",
                _ustr(tokenIs0 ? a0 : a1),
                "|principalQuote=",
                _ustr(tokenIs0 ? a1 : a0)
            )
        );
        // Two different metrics, both in raw units. Upper-bound residue: launch tokens the position held before
        // the exhausting buy that the buyer did not receive (that buy's fee is in quote). Core unbooked dust: Core
        // balance minus position amount minus fee ledger, accumulated over every swap so far; the residue is part
        // of it. Neither is owned or claimable by the creator.
        uint256 residue = remaining - got;
        (uint256 tokenDustExhausted, uint256 quoteDustExhausted) =
            _assertLedger(inst, quote, f.quoteIn, f.quoteOut, MAX_DUST);
        assertEq(tokenDustExhausted, tokenDust + residue, "residue is booked as new token dust");
        console2.log(
            string.concat(
                tag,
                "|upperResidue|positionTokenBefore=",
                _ustr(remaining),
                "|delivered=",
                _ustr(got),
                "|residueToken=",
                _ustr(residue)
            )
        );
        console2.log(
            string.concat(tag, "|dustExhausted|token=", _ustr(tokenDustExhausted), "|quote=", _ustr(quoteDustExhausted))
        );
    }

    function test_trade_token0_18_18() public {
        _scenario(true, 18);
    }

    function test_trade_token1_18_18() public {
        _scenario(false, 18);
    }

    function test_trade_token0_18_6() public {
        _scenario(true, 6);
    }

    function test_trade_token1_18_6() public {
        _scenario(false, 6);
    }

    function test_noDemand_afterSaturation() public {
        (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p) =
            _create(true, 18, DECAY_RATE);
        assertLt(_saturationSecond(DECAY_RATE), 365 days, "the default rate saturates within 64 days");
        vm.warp(START + 365 days);
        (uint128 p0, uint128 p1) = _principal(inst);
        assertEq(p1, 0, "quote reserve zero");
        assertLe(inst.installedSupply - p0, 1, "inventory installed");
        assertEq(launch.feeAt(inst.poolKey.toPoolId(), block.timestamp), FEE_03, "saturated at the floor");
        _assertLedger(inst, activeQuote, 0, 0, 1);
    }

    function test_dust_exactInputOneUnit() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, DECAY_RATE);
        vm.warp(START);
        // 1 raw quote unit buys ~1e6 raw tokens at 1e-6; fee rounds up.
        PoolBalanceUpdate u = _buy(inst.poolKey, inst.token, 1, false);
        (uint128 f0,) = launch.creatorFees(inst.poolKey);
        console2.log(string.concat("VEC|dust|t0|quoteIn=1|net=", _ustr(uint128(-u.delta0())), "|fee=", _ustr(f0)));
        assertGe(f0, 1, "fee rounds up");
    }

    function test_exactOutputGrossUpOverflowGuard() public pure {
        // amountBeforeFee reverts rather than wrapping; the creator fee path inherits the guard.
        uint256 v = uint256(type(uint128).max) << 64;
        uint256 dd = Q64 - FEE_5;
        assertGt(v / dd, type(uint128).max, "would overflow");
    }

    /// @dev Random buy/sell sequences in both orders keep conservation, x <= S and the price inside the range.
    function testFuzz_sequenceInvariants(uint256 seed, bool tokenIs0) public {
        (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p) =
            _create(tokenIs0, 18, DECAY_RATE);
        PoolKey memory key = inst.poolKey;
        Flow memory f;
        vm.warp(START);
        for (uint256 i; i < 12; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + (seed % 900));
            uint256 op = (seed >> 8) % 4;
            uint256 size = (seed >> 16) % 1e21 + 1;
            PoolBalanceUpdate u;
            if (op == 0) {
                u = _buy(key, inst.token, int128(uint128(size)), false);
            } else if (op == 1) {
                u = _buy(key, inst.token, int128(uint128(size * 1e6)), true);
            } else {
                uint256 held = ERC20(inst.token).balanceOf(address(this));
                if (held == 0) continue;
                uint256 amount = size % held + 1;
                if (op == 2) {
                    u = _sell(key, inst.token, int128(uint128(amount)), false);
                } else {
                    u = _sell(key, inst.token, int128(uint128(amount / 1e7 + 1)), true);
                }
            }
            _record(f, key, inst.token, u);
            PoolState st = ICore(CORE).poolState(key.toPoolId());
            assertGe(SqrtRatio.unwrap(st.sqrtRatio()), SqrtRatio.unwrap(tickToSqrtRatio(inst.positionId.tickLower())));
            assertLe(SqrtRatio.unwrap(st.sqrtRatio()), SqrtRatio.unwrap(tickToSqrtRatio(inst.positionId.tickUpper())));
            assertEq(
                ICore(CORE).poolPositions(key.toPoolId(), address(launch), inst.positionId).liquidity,
                inst.liquidity,
                "L constant"
            );
            _assertLedger(inst, activeQuote, f.quoteIn, f.quoteOut, MAX_DUST);
        }
    }
}

contract ZeroSeedLaunchTimeTest is ZeroSeedLaunchBase {
    using CoreLib for ICore;

    /// @dev The live schedule at a decay rate against the shared math at the start, around the half-life, far out
    /// and at the saturation boundary; time alone changes nothing in Core, and swaps settle at the floor after
    /// saturation. The fee at exactly one half-life is identical for both rates: both accumulate 1,386,295 ticks
    /// there, and the one-second quantization is what makes it 2.650000064% rather than 2.65% of the excess.
    function _schedule(uint64 decayRateX32, uint256 halfLife) internal {
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, decayRateX32);
        PoolId id = inst.poolKey.toPoolId();
        uint256 saturation = _saturationSecond(decayRateX32);
        uint256[11] memory ts = [
            uint256(START - 1),
            START,
            START + 1,
            START + halfLife / 2,
            START + halfLife - 1,
            START + halfLife,
            START + halfLife + 1,
            START + saturation,
            START + saturation + 1,
            START + 10 * 365 days,
            uint256(type(uint64).max)
        ];
        PoolState state = ICore(CORE).poolState(id);
        uint64 previous = type(uint64).max;
        for (uint256 i; i < ts.length; i++) {
            uint64 fee = launch.feeAt(id, ts[i]);
            assertEq(fee, _referenceFee(FEE_5, FEE_03, START, decayRateX32, ts[i]), "reference schedule");
            assertLe(fee, previous, "non-increasing");
            assertGe(fee, FEE_03, "never below the floor");
            previous = fee;
            console2.log(
                string.concat(
                    "VEC|fee|decayRateX32=",
                    _ustr(decayRateX32),
                    "|t=start+",
                    i == 0 ? "-1" : _ustr(ts[i] - START),
                    "|feeQ64=",
                    _ustr(fee)
                )
            );
            // Time alone changes nothing in Core.
            if (ts[i] < type(uint64).max) {
                vm.warp(ts[i]);
                assertEq(PoolState.unwrap(ICore(CORE).poolState(id)), PoolState.unwrap(state), "pool unchanged");
                assertEq(ICore(CORE).poolPositions(id, address(launch), inst.positionId).liquidity, inst.liquidity, "L");
            }
        }
        assertEq(launch.feeAt(id, START + halfLife), 488838729715618946, "one half-life (Python)");
        // On this fixture the floored excess is already zero before the helper's range ends (the span is below
        // 2**60); the nonzero residual at the minimum tick needs the full uint64 span, see ZeroSeedLaunchFeeCurve.
        assertEq(launch.feeAt(id, START + saturation), FEE_03, "at the floor by rounding before saturation");
        assertEq(launch.feeAt(id, START + saturation + 1), FEE_03, "saturated");
        // A live swap right after saturation settles at the floor; trading never ends.
        vm.warp(START + saturation + 1);
        PoolBalanceUpdate u = _buy(inst.poolKey, inst.token, 1e18, false);
        (uint128 f0,) = launch.creatorFees(inst.poolKey);
        uint128 net = uint128(-u.delta0());
        assertEq(f0, uint128((uint256(net + f0) * FEE_03 + Q64 - 1) >> 64), "floor-fee swap");
        vm.warp(START + 10 * 365 days);
        _buy(inst.poolKey, inst.token, 1e18, false); // no end-time revert, same pool
        assertEq(ICore(CORE).poolPositions(id, address(launch), inst.positionId).liquidity, inst.liquidity, "L");
    }

    function test_schedule_oneDayHalfLife() public {
        _schedule(DECAY_RATE, HALF_LIFE);
    }

    function test_schedule_600sHalfLife() public {
        _schedule(DECAY_RATE_600, HALF_LIFE_600);
    }
}

/// @dev Locally compiled test locker exercises forwarding, native settlement and route constraints.
contract ZeroSeedLaunchRouterTest is ZeroSeedLaunchBase {
    address ROUTER;

    function setUp() public override {
        super.setUp();
        ROUTER = address(new LaunchTestRouter(ICore(CORE)));
    }

    /// @dev Standard ABI for the test-only single-hop locker.
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

    /// @dev Native input is attached as `value`: the exact input, or the maximum input of an exact-output route. The
    /// router refunds whatever the route does not spend.
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

    /// @dev Both orders through the test router: a plain ERC-20 quote above the token (t0) and native ETH (t1). For
    /// the native order every buy attaches `value`, the router refunds the unspent part, and sells pay ETH out.
    function test_router_bothOrders_deadline_minOut_partial() public {
        for (uint256 i; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            bool tokenIs0 = i == 0;
            (IZeroSeedLaunch.Installation memory inst,) = _create(tokenIs0, 18, DECAY_RATE);
            bool native = activeQuote == NATIVE_TOKEN_ADDRESS;
            assertEq(native, !tokenIs0, "t1 order is the native quote");
            _approveQuote(activeQuote, ROUTER);
            ERC20(inst.token).approve(ROUTER, type(uint256).max);
            vm.deal(address(this), 1e30 + 10e18);
            PoolKey memory key = inst.poolKey;
            vm.warp(START);
            uint32 nowTs = uint32(block.timestamp);
            uint256 value = native ? 1e18 : 0;

            int256 quoted = _routerQuote(_route(key, activeQuote, inst.token, 1e18, 1, false, nowTs));
            (bool ok,,) =
                _callWithValue(_route(key, activeQuote, inst.token, 1e18, int128(quoted + 1), false, nowTs), value);
            assertFalse(ok, "minOut above quote refused");
            (ok,,) = _callWithValue(_route(key, activeQuote, inst.token, 1e18, 1, false, nowTs - 1), value);
            assertFalse(ok, "expired deadline refused");
            uint256 quoteBefore = _balance(activeQuote, address(this));
            if (native) quoteBefore = address(this).balance;
            (bool ok2, int256 paid, int256 got) =
                _callWithValue(_route(key, activeQuote, inst.token, 1e18, int128(quoted), false, nowTs), value);
            assertTrue(ok2, "inclusive deadline, minOut == quote");
            assertEq(got, quoted, "quote == execution");
            assertEq(paid, 1e18, "exact input");
            assertEq(ERC20(inst.token).balanceOf(address(this)), uint256(got), "received");
            if (native) assertEq(quoteBefore - address(this).balance, 1e18, "paid exactly the input in ETH");
            console2.log(
                string.concat("VEC|router|order=", tokenIs0 ? "t0" : "t1", "|paid=", _str(paid), "|got=", _str(got))
            );

            // Exact-output buy: a native route attaches a maximum input and gets the difference back.
            int256 qOut = _routerQuote(_route(key, inst.token, activeQuote, -1e20, type(int128).min, false, nowTs));
            uint256 ethBefore = address(this).balance;
            (bool okOut, int256 specOut, int256 calcOut) = _callWithValue(
                _route(key, inst.token, activeQuote, -1e20, type(int128).min, false, nowTs), native ? 10e18 : 0
            );
            assertTrue(okOut, "exact output");
            assertEq(specOut, -1e20, "exact output filled");
            assertEq(calcOut, qOut, "exact-out quote == execution");
            if (native) assertEq(ethBefore - address(this).balance, uint256(-calcOut), "unspent ETH refunded");

            // Sell-before-other-buyers path is a real sell now; exact sell to the router quote.
            int256 q2 = _routerQuote(_route(key, inst.token, activeQuote, int128(got / 2), 1, false, nowTs));
            ethBefore = address(this).balance;
            (bool ok3,, int256 got3) =
                _call(_route(key, inst.token, activeQuote, int128(got / 2), int128(q2), false, nowTs));
            assertTrue(ok3, "sell");
            assertEq(got3, q2, "sell quote == execution");
            if (native) assertEq(address(this).balance - ethBefore, uint256(got3), "ETH paid out to the recipient");

            // Full-fill route beyond the upper bound is refused; the partial route fills to the bound.
            (bool ok4,,) =
                _callWithValue(_route(key, activeQuote, inst.token, 1e30, 1, false, nowTs), native ? 1e30 : 0);
            assertFalse(ok4, "full fill beyond inventory refused");
            ethBefore = address(this).balance;
            (bool ok5, int256 paid5,) =
                _callWithValue(_route(key, activeQuote, inst.token, 1e30, 1, true, nowTs), native ? 1e30 : 0);
            assertTrue(ok5, "partial fill");
            assertLt(paid5, 1e30, "refund of unused input");
            if (native) assertEq(ethBefore - address(this).balance, uint256(paid5), "only the fill is paid in ETH");
            assertEq(address(launch).balance, 0, "extension holds no ETH");
            assertEq(address(periphery).balance, 0, "periphery holds no ETH");
            assertEq(ROUTER.balance, 0, "router holds no ETH");
            vm.revertToState(snap);
        }
    }

    function test_router_zeroMinOutNotNeededAndPositiveMinRequired() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, DECAY_RATE);
        ERC20(inst.token).approve(ROUTER, type(uint256).max);
        vm.warp(START);
        // Sell before any buy: nothing to sell into; a positive minimum output refuses the no-bid fill.
        (bool ok,,) = _call(_route(inst.poolKey, inst.token, activeQuote, 1, 1, false, uint32(block.timestamp)));
        assertFalse(ok, "no bid refused with positive minOut");
    }
}

contract ZeroSeedLaunchGasTest is ZeroSeedLaunchBase {
    function test_gas_vectors() public {
        for (uint256 i; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            bool tokenIs0 = i == 0;
            _quote(tokenIs0, 18);
            IZeroSeedLaunch.LaunchParameters memory p = _parameters(ASK_18_18, REQUESTED_SUPPLY, DECAY_RATE);
            _bind(p, creator);
            vm.prank(creator);
            uint256 g = gasleft();
            IZeroSeedLaunch.Installation memory inst = periphery.create(p);
            uint256 gCreate = g - gasleft();
            MintableERC20(inst.token).approve(address(swapper), type(uint256).max);
            vm.warp(START);
            g = gasleft();
            _buy(inst.poolKey, inst.token, 1e18, false);
            uint256 gFirst = g - gasleft();
            g = gasleft();
            _buy(inst.poolKey, inst.token, 1e18, false);
            uint256 gSecond = g - gasleft();
            g = gasleft();
            _sell(inst.poolKey, inst.token, 1e20, false);
            uint256 gSell = g - gasleft();
            vm.prank(creator);
            g = gasleft();
            periphery.claimFees(inst.poolKey, feeRecipient);
            uint256 gClaim = g - gasleft();
            console2.log(
                string.concat(
                    "VEC|gas|order=",
                    tokenIs0 ? "t0" : "t1",
                    "|create=",
                    _ustr(gCreate),
                    "|firstBuy=",
                    _ustr(gFirst),
                    "|secondBuy=",
                    _ustr(gSecond),
                    "|sell=",
                    _ustr(gSell),
                    "|claim=",
                    _ustr(gClaim)
                )
            );
            vm.revertToState(snap);
        }
    }
}

/// @dev Frozen canonical integer vectors (also in test/vectors/zero-seed-launch.json). Any change to geometry,
/// rounding, fee or Core math changes one of these.
contract ZeroSeedLaunchVectorsTest is ZeroSeedLaunchBase {
    struct Expected {
        bool tokenIs0;
        uint8 quoteDecimals;
        uint128 installed;
        uint128 liquidity;
        uint128 buyNet;
        uint128 buyFee;
        uint128 exactOutPaid;
        uint128 exactOutFee;
    }

    function _check(Expected memory e) internal {
        uint256 snap = vm.snapshotState();
        (IZeroSeedLaunch.Installation memory inst,) = _create(e.tokenIs0, e.quoteDecimals, DECAY_RATE);
        assertEq(inst.installedSupply, e.installed, "installed");
        assertEq(inst.liquidity, e.liquidity, "liquidity");
        vm.warp(START);
        int128 unit = int128(uint128(10 ** e.quoteDecimals));
        PoolBalanceUpdate u = _buy(inst.poolKey, inst.token, unit, false);
        assertEq(uint128(-_tokenDelta(inst.poolKey, inst.token, u)), e.buyNet, "buy net");
        (uint128 f0, uint128 f1) = launch.creatorFees(inst.poolKey);
        assertEq(e.tokenIs0 ? f0 : f1, e.buyFee, "buy fee (token)");
        u = _buy(inst.poolKey, inst.token, int128(e.buyNet), true);
        assertEq(uint128(_quoteDelta(inst.poolKey, inst.token, u)), e.exactOutPaid, "exact-out paid");
        (f0, f1) = launch.creatorFees(inst.poolKey);
        assertEq(e.tokenIs0 ? f1 : f0, e.exactOutFee, "exact-out fee (quote)");
        vm.revertToState(snap);
    }

    function test_vectors_creationAndFirstTrades() public {
        _check(
            Expected(
                true,
                18,
                999999999999999999999999210,
                1111119116089565312897934,
                949129205049968737676762,
                49954168686840459832116,
                1001756473791402152,
                50087823689570108
            )
        );
        _check(
            Expected(
                false,
                18,
                999999999999999999999999422,
                1111119116089565312898036,
                949129205049968737430728,
                49954168686840459819167,
                1001756473791402152,
                50087823689570108
            )
        );
        _check(
            Expected(
                true,
                6,
                999999999999999999302656786,
                1111138522742929536,
                949096081008880750943258,
                49952425316256881582986,
                1001757,
                50088
            )
        );
        _check(
            Expected(
                false,
                6,
                999999999999999999282285400,
                1111138522742929536,
                949095741048369739117185,
                49952407423598407276350,
                1001757,
                50088
            )
        );
    }

    /// @dev Default one-day half-life on the fixture (5% -> 0.3%), pinned by the Python oracle.
    function test_vectors_feeSchedule() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, DECAY_RATE);
        PoolId id = inst.poolKey.toPoolId();
        assertEq(launch.feeAt(id, START - 1), 922337203685477580);
        assertEq(launch.feeAt(id, START), 922337203685477580);
        assertEq(launch.feeAt(id, START + 1), 922330267740917652);
        assertEq(launch.feeAt(id, START + 10), 922267846736753839);
        assertEq(launch.feeAt(id, START + 60), 921920278629180106);
        assertEq(launch.feeAt(id, START + 600), 918173943809149156);
        assertEq(launch.feeAt(id, START + 1800), 909907303121253143);
        assertEq(launch.feeAt(id, START + 3600), 897655606672062181);
        assertEq(launch.feeAt(id, START + 43200), 668399831593786699);
        assertEq(launch.feeAt(id, START + 86399), 488842197715736884);
        assertEq(launch.feeAt(id, START + 86400), 488838729715618946);
        assertEq(launch.feeAt(id, START + 86401), 488835261743244884);
        assertEq(launch.feeAt(id, START + 172800), 272089486849531874);
        assertEq(launch.feeAt(id, START + 7 days), 62113647347197278);
        assertEq(launch.feeAt(id, START + 30 days), 55340233028582759);
        assertEq(launch.feeAt(id, START + 5529597), 55340232221128654);
        assertEq(launch.feeAt(id, START + 5529598), 55340232221128654);
        assertEq(launch.feeAt(id, type(uint64).max), 55340232221128654);
        assertEq(launch.feeAt(id, type(uint256).max), 55340232221128654);
    }

    /// @dev 600 second half-life on the fixture, pinned by the Python oracle; saturates after 38,399 s.
    function test_vectors_feeSchedule600() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, DECAY_RATE_600);
        PoolId id = inst.poolKey.toPoolId();
        assertEq(launch.feeAt(id, START), 922337203685477580);
        assertEq(launch.feeAt(id, START + 1), 921336400758785753);
        assertEq(launch.feeAt(id, START + 10), 912379287313991670);
        assertEq(launch.feeAt(id, START + 60), 864277214588907100);
        assertEq(launch.feeAt(id, START + 600), 488838729715618946);
        assertEq(launch.feeAt(id, START + 1800), 163714862475909380);
        assertEq(launch.feeAt(id, START + 3600), 68887062105693473);
        assertEq(launch.feeAt(id, START + 38399), 55340232221128654);
        assertEq(launch.feeAt(id, START + 38400), 55340232221128654);
        assertEq(launch.feeAt(id, START + 43200), 55340232221128654);
    }
}
