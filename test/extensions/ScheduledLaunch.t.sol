// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {
    ScheduledLaunch,
    scheduledLaunchCallPoints,
    MAX_MIGRATION_TICK_WIDTH
} from "../../src/extensions/ScheduledLaunch.sol";
import {TWAMM, twammCallPoints} from "../../src/extensions/TWAMM.sol";
import {OrderKey} from "../../src/types/orderKey.sol";
import {createOrderConfig} from "../../src/types/orderConfig.sol";
import {LockedLaunchLiquidity} from "../../src/LockedLaunchLiquidity.sol";
import {LaunchRouter} from "../../src/LaunchRouter.sol";
import {MintableERC20} from "../../src/MintableERC20.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {BaseForwardee} from "../../src/base/BaseForwardee.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {PositionId, createPositionId} from "../../src/types/positionId.sol";
import {Position} from "../../src/types/position.sol";
import {Locker} from "../../src/types/locker.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../../src/types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {computeFee} from "../../src/math/fee.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Router} from "../../src/Router.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @dev Test-only forwarded-swap locker: the same Core.forward(extension, abi.encode(PoolKey, SwapParameters))
/// hop a production router makes for any forward-only extension. Production routers apply slippage limits.
contract LaunchActor is BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function swap(ScheduledLaunch extension, PoolKey memory key, SwapParameters params)
        external
        payable
        returns (PoolBalanceUpdate)
    {
        return abi.decode(lock(abi.encode(extension, key, params, msg.sender)), (PoolBalanceUpdate));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (ScheduledLaunch extension, PoolKey memory key, SwapParameters params, address payer) =
            abi.decode(data, (ScheduledLaunch, PoolKey, SwapParameters, address));
        (PoolBalanceUpdate update,) =
            abi.decode(ACCOUNTANT.forward(address(extension), abi.encode(key, params)), (PoolBalanceUpdate, PoolState));
        _settle(payer, key.token0, update.delta0());
        _settle(payer, key.token1, update.delta1());
        return abi.encode(update);
    }

    function _settle(address payer, address token, int128 delta) private {
        if (delta < 0) {
            ACCOUNTANT.withdraw(token, payer, uint128(-delta));
        } else if (delta > 0) {
            if (token == address(0)) SafeTransferLib.safeTransferETH(address(ACCOUNTANT), uint128(delta));
            else ACCOUNTANT.payFrom(payer, token, uint128(delta));
        }
    }
}

contract OtherLP is BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function deposit(PoolKey memory key, uint128 liquidity) external {
        lock(abi.encode(key, liquidity, msg.sender));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory key, uint128 liquidity, address payer) = abi.decode(data, (PoolKey, uint128, address));
        PoolBalanceUpdate update = ICore(payable(address(ACCOUNTANT)))
            .updatePosition(key, createPositionId(bytes24(0), MIN_TICK, MAX_TICK), int128(liquidity));
        if (update.delta0() != 0) ACCOUNTANT.payFrom(payer, key.token0, uint128(update.delta0()));
        if (update.delta1() != 0) ACCOUNTANT.payFrom(payer, key.token1, uint128(update.delta1()));
        return "";
    }
}

contract TwammTrader is BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function placeOrder(TWAMM twammX, bytes32 salt, OrderKey memory key, int112 delta, address payer)
        external
        returns (int256 amountDelta)
    {
        return abi.decode(lock(abi.encode(twammX, salt, key, delta, payer)), (int256));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (TWAMM twammX, bytes32 salt, OrderKey memory key, int112 delta, address payer) =
            abi.decode(data, (TWAMM, bytes32, OrderKey, int112, address));
        int256 amountDelta =
            abi.decode(ACCOUNTANT.forward(address(twammX), abi.encode(uint256(0), salt, key, delta)), (int256));
        address sell = key.config.isToken1() ? key.token1 : key.token0;
        if (amountDelta > 0) ACCOUNTANT.payFrom(payer, sell, uint256(amountDelta));
        else if (amountDelta < 0) ACCOUNTANT.withdraw(sell, payer, uint128(uint256(-amountDelta)));
        return abi.encode(amountDelta);
    }
}

contract ScheduledLaunchTest is FullTest {
    using CoreLib for *;

    ScheduledLaunch extension;
    LockedLaunchLiquidity vault;
    LaunchRouter launchRouter;
    LaunchActor actor;
    /// @dev Every token a launch here touched, checked by _assertNoCustody.
    address[] custodyTokens;
    /// @dev The unmodified Router, deployed with the launch extension as its forward-only extension.
    Router forwardingRouter;
    TWAMM twamm;
    address constant LOW_QUOTE = address(0x10000);
    address constant HIGH_QUOTE = address(type(uint160).max);
    uint128 constant SUPPLY = 1_000_000e18;
    uint64 constant START = 100;
    uint64 constant END = 1100;
    uint64 constant INITIAL_FEE = uint64(uint256(1 << 64) / 10);
    uint64 constant FINAL_FEE = uint64(uint256(1 << 64) / 100);
    // Migration price ticks, in raw quote units per launch token. The default window is centred on the target.
    // A 10_000e18 buy at START + 100 leaves principal of about 1 quote per 99 launch tokens.
    int32 constant SMALL_BUY_TICK = -4_595_000;
    // Principal of quote alone against the full supply: ln(quote / SUPPLY) * 1e6.
    int32 constant QUOTE_1E18_TICK = -13_815_511;
    int32 constant QUOTE_7E18_TICK = -11_869_600;
    int32 constant QUOTE_100E18_TICK = -9_210_340;
    int32 constant QUOTE_100_000E18_TICK = -2_302_585;

    function setUp() public virtual override {
        super.setUp();
        vm.warp(1);
        address target = address(uint160(scheduledLaunchCallPoints().toUint8()) << 152);
        address twammTarget = address(uint160(twammCallPoints().toUint8()) << 152);
        deployCodeTo("TWAMM.sol", abi.encode(core), twammTarget);
        twamm = TWAMM(twammTarget);
        deployCodeTo("ScheduledLaunch.sol", abi.encode(core, twammTarget), target);
        extension = ScheduledLaunch(target);
        vault = extension.LIQUIDITY();
        launchRouter = new LaunchRouter(core, extension);
        actor = new LaunchActor(core);
        forwardingRouter = new Router(core, address(extension), address(0));
        deployCodeTo("TestToken.sol", abi.encode(address(this)), LOW_QUOTE);
        deployCodeTo("TestToken.sol", abi.encode(address(this)), HIGH_QUOTE);
        address[4] memory spenders = [address(actor), address(router), address(forwardingRouter), address(launchRouter)];
        for (uint256 i; i < spenders.length; i++) {
            TestToken(LOW_QUOTE).approve(spenders[i], type(uint256).max);
            TestToken(HIGH_QUOTE).approve(spenders[i], type(uint256).max);
        }
        custodyTokens.push(LOW_QUOTE);
        custodyTokens.push(HIGH_QUOTE);
    }

    /// @dev Neither launch contract nor the periphery ever holds ETH or an ERC-20, even between steps.
    function _assertNoCustody() internal view {
        address[3] memory holders = [address(extension), address(vault), address(launchRouter)];
        for (uint256 h; h < holders.length; h++) {
            assertEq(holders[h].balance, 0, "holds ETH");
            for (uint256 t; t < custodyTokens.length; t++) {
                assertEq(MintableERC20(custodyTokens[t]).balanceOf(holders[h]), 0, "holds ERC-20");
            }
        }
    }

    function _config(address quote) internal view returns (ScheduledLaunch.LaunchConfig memory) {
        return ScheduledLaunch.LaunchConfig({
            owner: address(this),
            quoteToken: quote,
            name: "Launch",
            symbol: "LAUNCH",
            decimals: 18,
            totalSupply: SUPPLY,
            startTime: START,
            endTime: END,
            targetTick: 0,
            upperTick: 100_000,
            tickSpacing: 100,
            initialFee: INITIAL_FEE,
            finalFee: FINAL_FEE,
            migrationTickLower: -MAX_MIGRATION_TICK_WIDTH / 2,
            migrationTickUpper: MAX_MIGRATION_TICK_WIDTH - MAX_MIGRATION_TICK_WIDTH / 2
        });
    }

    /// @dev Centres the widest allowed migration window on `tick`.
    function _migrateNear(ScheduledLaunch.LaunchConfig memory config, int32 tick)
        internal
        pure
        returns (ScheduledLaunch.LaunchConfig memory)
    {
        config.migrationTickLower = tick - MAX_MIGRATION_TICK_WIDTH / 2;
        config.migrationTickUpper = config.migrationTickLower + MAX_MIGRATION_TICK_WIDTH;
        return config;
    }

    function _create(bool tokenIs0) internal returns (PoolKey memory key) {
        return _create(tokenIs0, 0);
    }

    function _create(bool tokenIs0, int32 migrationTick) internal returns (PoolKey memory key) {
        key = _launch(_migrateNear(_config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE), migrationTick));
        assertEq(extension.getLaunch(key.toPoolId()).token == key.token0, tokenIs0);
    }

    /// @dev Creates through LaunchRouter, which becomes owner of record with this contract as creator, and
    /// approves the new token to the swap and funding paths.
    function _launch(ScheduledLaunch.LaunchConfig memory config) internal returns (PoolKey memory key) {
        address token;
        (key, token) = launchRouter.create(config);
        _track(token);
        MintableERC20(token).approve(address(actor), type(uint256).max);
        MintableERC20(token).approve(address(router), type(uint256).max);
        MintableERC20(token).approve(address(forwardingRouter), type(uint256).max);
        MintableERC20(token).approve(address(launchRouter), type(uint256).max);
        _assertNoCustody();
    }

    function _track(address token) internal {
        if (token != address(0)) custodyTokens.push(token);
    }

    /// @dev Funds locked principal through LaunchRouter, paying exact msg.value for a native token0.
    function _fund(PoolKey memory key, uint128 amount0, uint128 amount1) internal {
        vm.deal(address(this), address(this).balance + (key.token0 == address(0) ? amount0 : 0));
        launchRouter.fund{value: key.token0 == address(0) ? amount0 : 0}(key.toPoolId(), amount0, amount1);
        _assertNoCustody();
    }

    /// @dev Funds `quoteAmount` of the quote token into locked principal.
    function _fundQuote(PoolKey memory key, uint128 quoteAmount) internal {
        bool tokenIs0 = extension.getLaunch(key.toPoolId()).token == key.token0;
        _fund(key, tokenIs0 ? 0 : quoteAmount, tokenIs0 ? quoteAmount : 0);
    }

    /// @dev Ends a launch with no further trades, funds `quoteAmount` of quote and migrates. This is how a
    /// launch reaches the state the removed creation seed produced: SUPPLY launch tokens plus quote.
    function _finishFunded(PoolKey memory key, uint128 quoteAmount) internal {
        _finish(key);
        _fundQuote(key, quoteAmount);
        vault.migrate(key.toPoolId());
        _assertNoCustody();
    }

    /// @dev Creator claim of both fee ledgers through LaunchRouter.
    function _claimFees(PoolKey memory key, address recipient) internal {
        launchRouter.claimFees(key, recipient);
        _assertNoCustody();
    }

    function _balances(address holder, PoolKey memory key, bytes32 salt) internal view returns (uint128, uint128) {
        return core.savedBalances(holder, key.token0, key.token1, salt);
    }

    function _fees(PoolKey memory key) internal view returns (uint128, uint128) {
        return _balances(address(extension), key, extension.creatorFeeSalt(key.toPoolId()));
    }

    function _buy(PoolKey memory key, uint128 amount) internal returns (uint128) {
        bool tokenIs0 = extension.getLaunch(key.toPoolId()).token == key.token0;
        PoolBalanceUpdate update =
            actor.swap(extension, key, createSwapParameters(SqrtRatio.wrap(0), int128(amount), tokenIs0, 0));
        _assertNoCustody();
        return uint128(-(tokenIs0 ? update.delta0() : update.delta1()));
    }

    function _finish(PoolKey memory key) internal {
        vm.warp(END);
        extension.advance(key);
        _assertNoCustody();
        assertTrue(extension.getLaunch(key.toPoolId()).complete);
        assertEq(
            core.poolPositions(key.toPoolId(), address(extension), extension.getLaunch(key.toPoolId()).positionId)
            .liquidity,
            0
        );
    }

    function _locked(PoolKey memory key) internal view returns (uint128) {
        PoolKey memory terminal = extension.terminalPool(key);
        return core.poolPositions(terminal.toPoolId(), address(vault), vault.positionId(key.toPoolId())).liquidity;
    }

    function _seedTerminal(PoolKey memory key, int32 tick, uint128 liquidity) internal returns (OtherLP lp) {
        PoolKey memory terminal = extension.terminalPool(key);
        core.initializePool(terminal, tick);
        lp = new OtherLP(core);
        MintableERC20(key.token0).approve(address(lp), type(uint256).max);
        MintableERC20(key.token1).approve(address(lp), type(uint256).max);
        lp.deposit(terminal, liquidity);
    }

    function testFuzz_creationAndFeeSchedule(bool tokenIs0, uint64 elapsed) public {
        PoolKey memory key = _create(tokenIs0);
        ScheduledLaunch.Launch memory launch = extension.getLaunch(key.toPoolId());
        assertEq(launch.owner, address(launchRouter));
        assertEq(launchRouter.creator(key.toPoolId()), address(this));
        assertEq(MintableERC20(launch.token).owner(), address(0));
        assertEq(MintableERC20(launch.token).totalSupply(), SUPPLY);
        assertEq(MintableERC20(launch.token).name(), "Launch");
        assertEq(MintableERC20(launch.token).symbol(), "LAUNCH");
        assertEq(MintableERC20(launch.token).balanceOf(address(core)), SUPPLY);
        assertEq(key.config.fee(), 0);
        assertEq(extension.feeAt(key.toPoolId()), INITIAL_FEE);
        elapsed = uint64(bound(elapsed, 0, END - START));
        vm.warp(START + elapsed);
        assertEq(
            extension.feeAt(key.toPoolId()),
            INITIAL_FEE - uint64(uint256(INITIAL_FEE - FINAL_FEE) * elapsed / (END - START))
        );
        assertEq(extension.released(key.toPoolId()), uint128(uint256(SUPPLY) * elapsed / (END - START)));
        PoolKey memory terminal = extension.terminalPool(key);
        assertEq(terminal.config.fee(), FINAL_FEE);
        assertEq(terminal.config.extension(), address(twamm));
        assertTrue(terminal.config.isFullRange());
        vm.expectRevert(Ownable.Unauthorized.selector);
        MintableERC20(launch.token).mint(address(this), 1);
    }

    function testFuzz_externalFeesAndInternalExemption(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.warp(START + 100);
        uint128 bought = _buy(key, 10_000e18);
        (uint128 fee0, uint128 fee1) = _fees(key);
        uint128 fee = tokenIs0 ? fee0 : fee1;
        assertGt(fee, 0);
        assertEq(fee, computeFee(bought + fee, extension.feeAt(key.toPoolId())));
        vm.warp(START + 200);
        extension.advance(key);
        assertEq(SqrtRatio.unwrap(core.poolState(key.toPoolId()).sqrtRatio()), SqrtRatio.unwrap(tickToSqrtRatio(0)));
        (uint128 after0, uint128 after1) = _fees(key);
        assertEq(fee0, after0);
        assertEq(fee1, after1);
        (uint128 r0, uint128 r1) = _balances(address(extension), key, PoolId.unwrap(key.toPoolId()));
        uint128 deployed = extension.getLaunch(key.toPoolId()).deployed;
        assertEq(tokenIs0 ? r0 : r1, SUPPLY - deployed);
        assertGt(tokenIs0 ? r1 : r0, 0);
        _claimFees(key, address(777));
        assertEq(MintableERC20(extension.getLaunch(key.toPoolId()).token).balanceOf(address(777)), fee);
        (after0, after1) = _fees(key);
        assertEq(after0, 0);
        assertEq(after1, 0);
        assertEq(extension.getLaunch(key.toPoolId()).deployed, deployed);
    }

    function testFuzz_exactOutputAndPartialInput(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.warp(START + 100);
        uint128 tokenBefore = uint128(MintableERC20(extension.getLaunch(key.toPoolId()).token).balanceOf(address(this)));
        actor.swap(extension, key, createSwapParameters(SqrtRatio.wrap(0), -int128(100e18), !tokenIs0, 0));
        assertEq(
            MintableERC20(extension.getLaunch(key.toPoolId()).token).balanceOf(address(this)) - tokenBefore, 100e18
        );
        (uint128 fee0, uint128 fee1) = _fees(key);
        assertGt(tokenIs0 ? fee1 : fee0, 0);
        int32 limit = tokenIs0 ? int32(1000) : int32(-1000);
        PoolBalanceUpdate update =
            actor.swap(extension, key, createSwapParameters(tickToSqrtRatio(limit), int128(1_000_000e18), tokenIs0, 0));
        assertLt(uint128(tokenIs0 ? update.delta1() : update.delta0()), 1_000_000e18);
        assertGt(uint128(-(tokenIs0 ? update.delta0() : update.delta1())), 0);
    }

    function test_directCallsAndOutsideScheduleRevert() public {
        PoolKey memory key = _create(true);
        PoolKey memory otherKey =
            PoolKey(LOW_QUOTE, HIGH_QUOTE, createConcentratedPoolConfig(0, 100, address(extension)));
        vm.expectRevert(ScheduledLaunch.InitializationThroughForwardOnly.selector);
        core.initializePool(otherKey, 0);
        vm.expectRevert(ScheduledLaunch.SwapsThroughForwardOnly.selector);
        router.swapAllowPartialFill(key, true, 1e18, SqrtRatio.wrap(0), 0);
        vm.expectRevert(ScheduledLaunch.LaunchNotStarted.selector);
        actor.swap(extension, key, createSwapParameters(SqrtRatio.wrap(0), 1e18, true, 0));
        vm.warp(END);
        vm.expectRevert(ScheduledLaunch.LaunchEnded.selector);
        actor.swap(extension, key, createSwapParameters(SqrtRatio.wrap(0), 1e18, true, 0));
        vm.expectRevert(BaseForwardee.BaseForwardeeAccountantOnly.selector);
        extension.forwarded_2374103877(Locker.wrap(bytes32(0)));
        vm.expectRevert(BaseLocker.BaseLockerAccountantOnly.selector);
        extension.locked_6416899205(0);
        vm.expectRevert(LockedLaunchLiquidity.ExtensionOnly.selector);
        vault.createToken("x", "x", 18, 1);
    }

    function testFuzz_freshMigrationLocksPrincipal(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0, SMALL_BUY_TICK);
        vm.warp(START + 100);
        _buy(key, 10_000e18);
        vm.warp(START + 200);
        extension.advance(key);
        _finish(key);
        assertGt(_locked(key), 0);
        PoolKey memory terminal = extension.terminalPool(key);
        assertTrue(core.poolState(terminal.toPoolId()).isInitialized());
        uint128 liquidity = _locked(key);
        _claimFees(key, address(this));
        assertEq(_locked(key), liquidity);
        (bool success,) = address(extension)
            .call(abi.encodeWithSignature("withdraw((address,address,bytes32),address)", key, address(this)));
        assertFalse(success);
        (success,) =
            address(vault).call(abi.encodeWithSignature("withdraw(bytes32,address)", key.toPoolId(), address(this)));
        assertFalse(success);
        // The removed direct entry points: claims and funding are forwards only.
        (success,) = address(extension)
            .call(abi.encodeWithSignature("claimFees((address,address,bytes32),address)", key, address(this)));
        assertFalse(success);
        (success,) =
            address(vault).call(abi.encodeWithSignature("claimFees(bytes32,address)", key.toPoolId(), address(this)));
        assertFalse(success);
        (success,) = address(vault)
            .call(abi.encodeWithSignature("fund(bytes32,uint128,uint128)", key.toPoolId(), uint128(0), uint128(1)));
        assertFalse(success);
        extension.advance(key);
        assertEq(_locked(key), liquidity);
    }

    function testFuzz_noBuyersWaitsForFunding(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0, QUOTE_1E18_TICK);
        _finish(key);
        assertEq(_locked(key), 0);
        (uint128 a0, uint128 a1) = _balances(address(vault), key, PoolId.unwrap(key.toPoolId()));
        assertEq(tokenIs0 ? a0 : a1, SUPPLY);
        assertEq(tokenIs0 ? a1 : a0, 0);
        _fundQuote(key, 1e18);
        vault.migrate(key.toPoolId());
        assertGt(_locked(key), 0);
        _assertNoCustody();
    }

    /// Creation takes no quote; quote funded after endTime migrates with the unsold supply.
    function testFuzz_noBuyersFundedAfterEndMigrates(bool tokenIs0) public {
        ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
        _migrateNear(config, QUOTE_100_000E18_TICK);
        PoolKey memory key = _launch(config);
        (uint128 r0, uint128 r1) = _balances(address(extension), key, PoolId.unwrap(key.toPoolId()));
        assertEq(tokenIs0 ? r1 : r0, 0);
        _finishFunded(key, 100_000e18);
        assertGt(_locked(key), 0);
        (uint128 f0, uint128 f1) = _fees(key);
        assertEq(f0, 0);
        assertEq(f1, 0);
    }

    function testFuzz_existingPoolBalancesAndCreatorGetsOnlyOwnFees(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0, SMALL_BUY_TICK);
        vm.warp(START + 100);
        _buy(key, 10_000e18);
        // The existing pool trades inside the migration window, away from the principal's own ratio.
        int32 seedTick = SMALL_BUY_TICK + 500_000;
        OtherLP lp = _seedTerminal(key, tokenIs0 ? seedTick : -seedTick, 1_000e18);
        _finish(key);
        assertGt(_locked(key), 0);
        (uint128 residual0, uint128 residual1) = _balances(address(vault), key, PoolId.unwrap(key.toPoolId()));
        assertLe(residual0, 10_000);
        assertLe(residual1, 10_000);
        PoolKey memory terminal = extension.terminalPool(key);
        router.swapAllowPartialFill(terminal, tokenIs0, int128(100e18), SqrtRatio.wrap(0), 0);
        Position memory own = core.poolPositions(terminal.toPoolId(), address(vault), vault.positionId(key.toPoolId()));
        Position memory other =
            core.poolPositions(terminal.toPoolId(), address(lp), createPositionId(bytes24(0), MIN_TICK, MAX_TICK));
        (uint128 own0, uint128 own1) = own.fees(core.getPoolFeesPerLiquidity(terminal.toPoolId()));
        (uint128 other0, uint128 other1) = other.fees(core.getPoolFeesPerLiquidity(terminal.toPoolId()));
        assertGt(tokenIs0 ? own1 : own0, 0);
        assertGt(tokenIs0 ? other1 : other0, 0);
        // One creator claim releases the extension's trading fees and the locked position's own fees.
        (uint128 x0, uint128 x1) = _fees(key);
        (uint128 c0, uint128 c1) = _balances(address(vault), key, vault.creatorFeeSalt(key.toPoolId()));
        _claimFees(key, address(777));
        assertEq(MintableERC20(key.token0).balanceOf(address(777)), uint256(own0) + x0 + c0);
        assertEq(MintableERC20(key.token1).balanceOf(address(777)), uint256(own1) + x1 + c1);
        assertEq(_locked(key), own.liquidity);
        other = core.poolPositions(terminal.toPoolId(), address(lp), createPositionId(bytes24(0), MIN_TICK, MAX_TICK));
        (uint128 after0, uint128 after1) = other.fees(core.getPoolFeesPerLiquidity(terminal.toPoolId()));
        assertEq(after0, other0);
        assertEq(after1, other1);
    }

    function testFuzz_emptyDestinationPriceCannotGrief(bool tokenIs0) public {
        PoolKey memory key = _launch(_config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE));
        core.initializePool(extension.terminalPool(key), 5_000_000);
        _finishFunded(key, SUPPLY);
        assertGt(_locked(key), 0);
        assertApproxEqAbs(core.poolState(extension.terminalPool(key).toPoolId()).tick(), 0, 1);
    }

    function testFuzz_outsideMigrationBoundsRetainsLockedFunds(bool tokenIs0) public {
        ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
        config.migrationTickLower = -10_000;
        config.migrationTickUpper = 10_000;
        PoolKey memory key = _launch(config);
        vm.warp(START + 100);
        _buy(key, 10_000e18);
        _seedTerminal(key, tokenIs0 ? int32(200_000) : int32(-200_000), 100e18);
        _finish(key);
        assertEq(_locked(key), 0);
        (uint128 a0, uint128 a1) = _balances(address(vault), key, PoolId.unwrap(key.toPoolId()));
        assertGt(a0, 0);
        assertGt(a1, 0);
        vm.prank(address(123));
        vm.expectRevert(LaunchRouter.CreatorOnly.selector);
        launchRouter.claimFees(key, address(123));
        _assertNoCustody();
    }

    function test_nativeQuoteMigration() public {
        ScheduledLaunch.LaunchConfig memory config = _config(address(0));
        _migrateNear(config, QUOTE_1E18_TICK);
        PoolKey memory key = _launch(config);
        _finishFunded(key, 1 ether);
        assertGt(_locked(key), 0);
        vm.deal(address(this), 1 ether);
        router.swapAllowPartialFill{value: 1e15}(extension.terminalPool(key), false, int128(1e15), SqrtRatio.wrap(0), 0);
        uint128 principal = _locked(key);
        _claimFees(key, address(777));
        assertGt(address(777).balance, 0);
        assertEq(_locked(key), principal);
    }

    function testFuzz_migrationWindowWidthCap(bool tokenIs0, int32 lower) public {
        lower = int32(bound(lower, MIN_TICK, MAX_TICK - MAX_MIGRATION_TICK_WIDTH - 1));
        ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
        config.migrationTickLower = lower;
        config.migrationTickUpper = lower + MAX_MIGRATION_TICK_WIDTH + 1;
        vm.expectRevert(ScheduledLaunch.InvalidLaunch.selector);
        launchRouter.create(config);
        config.migrationTickUpper = lower + MAX_MIGRATION_TICK_WIDTH;
        PoolKey memory key = _launch(config);
        ScheduledLaunch.Launch memory launch = extension.getLaunch(key.toPoolId());
        assertEq(launch.token == key.token0, tokenIs0);
        int32 poolLower = tokenIs0 ? config.migrationTickLower : -config.migrationTickUpper;
        int32 poolUpper = tokenIs0 ? config.migrationTickUpper : -config.migrationTickLower;
        assertEq(SqrtRatio.unwrap(launch.migrationLower), SqrtRatio.unwrap(tickToSqrtRatio(poolLower)));
        assertEq(SqrtRatio.unwrap(launch.migrationUpper), SqrtRatio.unwrap(tickToSqrtRatio(poolUpper)));
    }

    function test_migrationWindowWidthCapAtTheExtremes() public {
        for (uint256 i; i < 2; i++) {
            ScheduledLaunch.LaunchConfig memory config = _config(i == 0 ? HIGH_QUOTE : LOW_QUOTE);
            config.migrationTickLower = MIN_TICK;
            config.migrationTickUpper = MIN_TICK + MAX_MIGRATION_TICK_WIDTH + 1;
            vm.expectRevert(ScheduledLaunch.InvalidLaunch.selector);
            launchRouter.create(config);
            config.migrationTickUpper = MAX_TICK;
            vm.expectRevert(ScheduledLaunch.InvalidLaunch.selector);
            launchRouter.create(config);
            config.migrationTickUpper = MIN_TICK + MAX_MIGRATION_TICK_WIDTH;
            _launch(config);
            config.migrationTickLower = MAX_TICK - MAX_MIGRATION_TICK_WIDTH - 1;
            config.migrationTickUpper = MAX_TICK;
            vm.expectRevert(ScheduledLaunch.InvalidLaunch.selector);
            launchRouter.create(config);
            config.migrationTickLower = MAX_TICK - MAX_MIGRATION_TICK_WIDTH;
            _launch(config);
        }
    }

    function test_invalidConfigurationAndRollback() public {
        ScheduledLaunch.LaunchConfig memory config = _config(HIGH_QUOTE);
        config.finalFee = config.initialFee + 1;
        vm.expectRevert(ScheduledLaunch.InvalidLaunch.selector);
        launchRouter.create(config);
        config = _config(HIGH_QUOTE);
        config.migrationTickLower = config.migrationTickUpper;
        vm.expectRevert(ScheduledLaunch.InvalidLaunch.selector);
        launchRouter.create(config);
        // A failure after the token is deployed and its supply minted to Core rolls both back.
        config = _config(HIGH_QUOTE);
        uint64 nonce = vm.getNonce(address(vault));
        address predicted = vm.computeCreateAddress(address(vault), nonce);
        config.quoteToken = predicted;
        vm.expectRevert(ScheduledLaunch.InvalidLaunch.selector);
        launchRouter.create(config);
        assertEq(predicted.code.length, 0);
        assertEq(vm.getNonce(address(vault)), nonce);
    }

    function testFuzz_launchIsolation(bool tokenIs0) public {
        ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
        _migrateNear(config, QUOTE_100E18_TICK);
        PoolKey memory a = _launch(config);
        PoolKey memory b = _launch(config);
        _finishFunded(a, 100e18);
        assertGt(_locked(a), 0);
        assertFalse(extension.getLaunch(b.toPoolId()).complete);
        (uint128 r0, uint128 r1) = _balances(address(extension), b, PoolId.unwrap(b.toPoolId()));
        assertEq(tokenIs0 ? r0 : r1, SUPPLY);
        assertEq(tokenIs0 ? r1 : r0, 0);
        assertEq(vault.getTerminal(b.toPoolId()).owner, address(0));
    }

    function testFuzz_releasesBelowTargetStillWork(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.warp(START + 100);
        uint128 bought = _buy(key, 10_000e18);
        vm.warp(START + 200);
        extension.advance(key);
        actor.swap(
            extension,
            key,
            createSwapParameters(tickToSqrtRatio(tokenIs0 ? int32(-1000) : int32(1000)), int128(bought), !tokenIs0, 0)
        );
        uint128 deployed = extension.getLaunch(key.toPoolId()).deployed;
        vm.warp(START + 300);
        extension.advance(key);
        assertGt(extension.getLaunch(key.toPoolId()).deployed, deployed);
        assertEq(core.poolState(key.toPoolId()).tick(), tokenIs0 ? int32(-1000) : int32(1000));
    }

    function testFuzz_largeLaunchMigrationCanFinishInChunks(bool tokenIs0) public {
        ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
        config.targetTick = 50_000_000;
        config.upperTick = 50_100_000;
        // Three maximum buys leave principal at tick 33_866_279 (measured).
        _migrateNear(config, 33_866_000);
        PoolKey memory key = _launch(config);
        vm.warp(START + 100);
        for (uint256 i = 0; i < 3; i++) {
            _buy(key, uint128(type(int128).max));
        }
        vm.warp(END);
        for (uint256 i = 0; i < 8; i++) {
            extension.advance(key);
        }
        assertTrue(extension.getLaunch(key.toPoolId()).complete);
        assertEq(
            core.poolPositions(key.toPoolId(), address(extension), extension.getLaunch(key.toPoolId()).positionId)
            .liquidity,
            0
        );
        assertGt(_locked(key), 0);
    }

    function testFuzz_rebalanceFeesRecycleIntoPrincipal(bool tokenIs0) public {
        PoolKey memory key = _launch(_config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE));
        _finishFunded(key, SUPPLY);
        uint128 before = _locked(key);
        // Donation and rebalancing against our own LP must not turn principal into creator fees.
        _fundQuote(key, 1000e18);
        vault.migrate(key.toPoolId());
        assertGt(_locked(key), before);
        (uint128 residue0, uint128 residue1) = _balances(address(vault), key, PoolId.unwrap(key.toPoolId()));
        // Near price 1, Core's compact ratio has ~62 fractional bits. At this
        // position size one representable price step can leave sub-token dust.
        uint128 roundingBound = SUPPLY / (1 << 60) + 100;
        assertLe(residue0, roundingBound);
        assertLe(residue1, roundingBound);
        _claimFees(key, address(777));
        assertEq(MintableERC20(key.token0).balanceOf(address(777)), 0);
        assertEq(MintableERC20(key.token1).balanceOf(address(777)), 0);
    }

    function testFuzz_rebalancePreservesPreviouslyEarnedCreatorFees(bool tokenIs0) public {
        PoolKey memory key = _launch(_config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE));
        _finishFunded(key, SUPPLY);
        PoolKey memory terminal = extension.terminalPool(key);
        router.swapAllowPartialFill(terminal, tokenIs0, int128(100e18), SqrtRatio.wrap(0), 0);
        Position memory position =
            core.poolPositions(terminal.toPoolId(), address(vault), vault.positionId(key.toPoolId()));
        (uint128 before0, uint128 before1) = position.fees(core.getPoolFeesPerLiquidity(terminal.toPoolId()));
        assertGt(tokenIs0 ? before1 : before0, 0);
        _fundQuote(key, 1000e18);
        vault.migrate(key.toPoolId());
        _claimFees(key, address(777));
        assertEq(MintableERC20(key.token0).balanceOf(address(777)), before0);
        assertEq(MintableERC20(key.token1).balanceOf(address(777)), before1);
    }

    function testFuzz_migrationWithLiveTwammOrders(bool tokenIs0) public {
        PoolKey memory key = _launch(_config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE));
        _finishFunded(key, SUPPLY);
        uint128 lockedBefore = _locked(key);
        assertGt(lockedBefore, 0);
        PoolKey memory terminal = extension.terminalPool(key);
        // Sell the quote token through TWAMM while migration runs.
        TwammTrader trader = new TwammTrader(core);
        address quote = tokenIs0 ? key.token1 : key.token0;
        TestToken(quote).approve(address(trader), type(uint256).max);
        vm.warp(1280);
        OrderKey memory order = OrderKey({
            token0: terminal.token0,
            token1: terminal.token1,
            config: createOrderConfig({_fee: FINAL_FEE, _isToken1: tokenIs0, _startTime: 1280, _endTime: 1792})
        });
        assertGt(trader.placeOrder(twamm, bytes32(uint256(1)), order, int112(1e30), address(this)), 0);
        // Fund single-sided so migration must rebalance against live virtual flow.
        _fundQuote(key, 1000e18);
        vm.warp(1400);
        vault.migrate(key.toPoolId());
        // Virtual execution moved the canonical price and migration still locked more.
        assertTrue(core.poolState(terminal.toPoolId()).tick() != 0);
        assertGt(_locked(key), lockedBefore);
    }

    function _mineSalt(bytes32 initHash) internal view returns (bytes32) {
        uint256 salt;
        uint8 prefix = scheduledLaunchCallPoints().toUint8();
        while (true) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), initHash))))
            );
            if (uint8(uint160(predicted) >> 152) == prefix) return bytes32(salt);
            salt++;
        }
    }

    function test_constructorRevertsForZeroTwamm() public {
        bytes32 initHash = keccak256(abi.encodePacked(type(ScheduledLaunch).creationCode, abi.encode(core, address(0))));
        bytes32 salt = _mineSalt(initHash);
        vm.expectRevert(ScheduledLaunch.InvalidTwamm.selector);
        new ScheduledLaunch{salt: salt}(core, address(0));
    }

    function test_deployWithMinedHookPrefix() public {
        bytes32 initHash = keccak256(abi.encodePacked(type(ScheduledLaunch).creationCode, abi.encode(core, twamm)));
        bytes32 salt = _mineSalt(initHash);
        ScheduledLaunch deployed = new ScheduledLaunch{salt: salt}(core, address(twamm));
        assertTrue(core.isExtensionRegistered(address(deployed)));
        assertEq(deployed.LIQUIDITY().EXTENSION(), address(deployed));
        assertLe(address(deployed).code.length, 24_576);
        assertLe(address(deployed.LIQUIDITY()).code.length, 24_576);
        assertLe(type(ScheduledLaunch).creationCode.length + 32, 49_152);
    }
}
