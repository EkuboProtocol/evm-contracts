// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

// EKU-648 evidence: migration price bounds vs pending TWAMM virtual execution.
// Review-only harness against PR #371 head 6767d6cc9f131649d6494033a37cd4cabd143b92.

import {console2} from "forge-std/console2.sol";
import {ScheduledLaunchTest, TwammTrader, OtherLP} from "./ScheduledLaunch.t.sol";
import {TestToken} from "../TestToken.sol";
import {ScheduledLaunch} from "../../src/extensions/ScheduledLaunch.sol";
import {LockedLaunchLiquidity} from "../../src/LockedLaunchLiquidity.sol";
import {MintableERC20} from "../../src/MintableERC20.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {ITWAMM} from "../../src/interfaces/extensions/ITWAMM.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {TWAMMLib} from "../../src/libraries/TWAMMLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {Position} from "../../src/types/position.sol";
import {OrderKey} from "../../src/types/orderKey.sol";
import {createOrderConfig} from "../../src/types/orderConfig.sol";
import {SqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../../src/types/sqrtRatio.sol";
import {amount0Delta, amount1Delta} from "../../src/math/delta.sol";
import {LaunchLiquidityMath} from "../../src/math/launchLiquidity.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract ScheduledLaunchTwammBoundsTest is ScheduledLaunchTest {
    using CoreLib for *;
    using TWAMMLib for *;

    // Pool-level enums (token0/token1 of the terminal pool, independent of which is the launch token).
    uint8 constant FUND_TOKEN0 = 0;
    uint8 constant FUND_TOKEN1 = 1;
    uint8 constant FUND_BALANCED = 2;
    uint8 constant FLOW_NONE = 0;
    uint8 constant FLOW_SELL_TOKEN0 = 1; // pushes price down
    uint8 constant FLOW_SELL_TOKEN1 = 2; // pushes price up

    int32 constant BOUND_TICKS = 2_000; // +/-0.2% around the launch price
    uint64 constant ORDER_START = 1280;
    uint64 constant ORDER_END = 1792;
    uint64 constant PENDING = 120; // seconds of unexecuted virtual flow at migrate()
    int112 constant SALE_RATE = 2e29; // ~5.6e21 tokens per 120s vs ~1e24 pool liquidity
    uint128 constant FUNDING = 1_000e18;
    uint128 constant BALANCED_LIQUIDITY = 1e21;

    enum Outcome {
        Deferred,
        DepositedInBounds,
        DepositedOutOfBounds,
        Reverted
    }

    struct Snap {
        uint256 timestamp;
        uint256 twammLastExecution;
        SqrtRatio sqrtRatio;
        int32 tick;
        uint128 poolLiquidity;
        uint128 ownLiquidity;
        uint128 reserve0;
        uint128 reserve1;
        uint128 creatorFee0;
        uint128 creatorFee1;
        uint128 positionFee0;
        uint128 positionFee1;
    }

    struct Case {
        PoolKey key;
        PoolKey terminal;
        PoolId launchId;
        SqrtRatio lower;
        SqrtRatio upper;
        Snap pre;
        SqrtRatio executedOnlyPrice; // price if virtual orders are executed first, before migrate()
        int32 executedOnlyTick;
        Snap post;
        bool reverted;
        bytes4 selector;
        Outcome outcome;
        int256 incrementalValueDelta; // new position value + reserve change, valued at the pre (validated) price
    }

    // ---------------------------------------------------------------------------------------------
    // Scenario driver
    // ---------------------------------------------------------------------------------------------

    function _setupLaunch(bool tokenIs0) internal returns (Case memory c) {
        ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
        config.quoteAmount = SUPPLY;
        config.migrationTickLower = -BOUND_TICKS;
        config.migrationTickUpper = BOUND_TICKS;
        c.key = actor.create(extension, config);
        _finish(c.key); // empty terminal pool -> locked full-range position at ~tick 0
        c.terminal = extension.terminalPool(c.key);
        c.launchId = c.key.toPoolId();
        LockedLaunchLiquidity.Terminal memory t = vault.getTerminal(c.launchId);
        c.lower = t.lower;
        c.upper = t.upper;
        assertGt(_locked(c.key), 0, "initial migration locked liquidity");
        _tokens(c.key);
    }

    function _tokens(PoolKey memory key) internal {
        // The launch token has fixed supply held by Core; give the test inventory for funding/orders.
        address launchToken = extension.getLaunch(key.toPoolId()).token;
        deal(launchToken, address(this), 1e27);
        MintableERC20(launchToken).approve(address(actor), type(uint256).max);
        MintableERC20(launchToken).approve(address(router), type(uint256).max);
    }

    function _placeFlow(Case memory c, uint8 flow) internal {
        vm.warp(ORDER_START);
        if (flow == FLOW_NONE) return;
        TwammTrader trader = new TwammTrader(core);
        bool sell1 = flow == FLOW_SELL_TOKEN1;
        address sell = sell1 ? c.terminal.token1 : c.terminal.token0;
        TestToken(sell).approve(address(trader), type(uint256).max);
        OrderKey memory order = OrderKey({
            token0: c.terminal.token0,
            token1: c.terminal.token1,
            config: createOrderConfig({_fee: FINAL_FEE, _isToken1: sell1, _startTime: ORDER_START, _endTime: ORDER_END})
        });
        assertGt(trader.placeOrder(twamm, bytes32(uint256(1)), order, SALE_RATE, address(this)), 0);
    }

    function _fund(Case memory c, uint8 funding) internal {
        if (funding == FUND_TOKEN0) {
            actor.fund(vault, c.launchId, FUNDING, 0);
        } else if (funding == FUND_TOKEN1) {
            actor.fund(vault, c.launchId, 0, FUNDING);
        } else {
            // Exact full-range deposit amounts for BALANCED_LIQUIDITY at the current (pre-flow) price.
            SqrtRatio p = core.poolState(c.terminal.toPoolId()).sqrtRatio();
            (uint128 r0, uint128 r1) = _balances(address(vault), c.key, PoolId.unwrap(c.launchId));
            uint128 n0 = amount0Delta(p, MAX_SQRT_RATIO, BALANCED_LIQUIDITY, true);
            uint128 n1 = amount1Delta(MIN_SQRT_RATIO, p, BALANCED_LIQUIDITY, true);
            // Residual dust from the initial migration is topped up so the totals are the exact pair.
            actor.fund(vault, c.launchId, n0 > r0 ? n0 - r0 : 0, n1 > r1 ? n1 - r1 : 0);
        }
    }

    function _snap(Case memory c) internal view returns (Snap memory s) {
        PoolId pid = c.terminal.toPoolId();
        PoolState st = core.poolState(pid);
        s.timestamp = block.timestamp;
        s.twammLastExecution = ITWAMM(address(twamm)).poolState(pid).realLastVirtualOrderExecutionTime();
        s.sqrtRatio = st.sqrtRatio();
        s.tick = st.tick();
        s.poolLiquidity = st.liquidity();
        Position memory own = core.poolPositions(pid, address(vault), vault.positionId(c.launchId));
        s.ownLiquidity = own.liquidity;
        (s.positionFee0, s.positionFee1) = own.fees(core.getPoolFeesPerLiquidity(pid));
        (s.reserve0, s.reserve1) = _balances(address(vault), c.key, PoolId.unwrap(c.launchId));
        (s.creatorFee0, s.creatorFee1) = _balances(address(vault), c.key, vault.creatorFeeSalt(c.launchId));
    }

    function _market(Case memory c) internal view returns (LaunchLiquidityMath.Market memory) {
        PoolId pid = c.terminal.toPoolId();
        PoolState st = core.poolState(pid);
        (uint128 r0, uint128 r1) = _balances(address(vault), c.key, PoolId.unwrap(c.launchId));
        return LaunchLiquidityMath.Market(
            st.sqrtRatio(),
            c.lower,
            c.upper,
            st.liquidity(),
            c.terminal.config.fee(),
            r0,
            r1,
            core.poolPositions(pid, address(vault), vault.positionId(c.launchId)).liquidity
        );
    }

    function _value(SqrtRatio price, uint256 a0, uint256 a1) internal pure returns (uint256) {
        uint256 s = price.toFixed();
        return FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(a0, s, 1 << 128), s, 1 << 128) + a1;
    }

    function _run(bool tokenIs0, uint8 funding, uint8 flow) internal returns (Case memory c) {
        c = _setupLaunch(tokenIs0);
        _placeFlow(c, flow);
        _fund(c, funding);
        vm.warp(ORDER_START + PENDING);

        c.pre = _snap(c);
        if (funding == FUND_BALANCED) {
            (, uint128 swapAmount) = LaunchLiquidityMath.optimalSwap(_market(c));
            assertEq(swapAmount, 0, "balanced precondition: optimalSwap returns zero");
        }

        // Counterfactual: what the price becomes once pending virtual orders run, before migrate's own actions.
        uint256 snapshot = vm.snapshotState();
        twamm.lockAndExecuteVirtualOrders(c.terminal);
        c.executedOnlyPrice = core.poolState(c.terminal.toPoolId()).sqrtRatio();
        c.executedOnlyTick = core.poolState(c.terminal.toPoolId()).tick();
        vm.revertToState(snapshot);

        try vault.migrate(c.launchId) {}
        catch (bytes memory err) {
            c.reverted = true;
            c.selector = bytes4(err);
        }
        c.post = _snap(c);

        if (c.reverted) {
            c.outcome = Outcome.Reverted;
        } else if (c.post.ownLiquidity == c.pre.ownLiquidity) {
            c.outcome = Outcome.Deferred;
        } else if (c.post.sqrtRatio < c.lower || c.post.sqrtRatio > c.upper) {
            c.outcome = Outcome.DepositedOutOfBounds;
        } else {
            c.outcome = Outcome.DepositedInBounds;
        }

        // Value of the incremental migration at the pre-migration (validated) price.
        if (!c.reverted) {
            uint128 dL = c.post.ownLiquidity - c.pre.ownLiquidity;
            uint256 pos = _value(
                c.pre.sqrtRatio,
                amount0Delta(c.pre.sqrtRatio, MAX_SQRT_RATIO, dL, false),
                amount1Delta(MIN_SQRT_RATIO, c.pre.sqrtRatio, dL, false)
            );
            int256 reserveChange = int256(_value(c.pre.sqrtRatio, c.post.reserve0, c.post.reserve1))
                - int256(_value(c.pre.sqrtRatio, c.pre.reserve0, c.pre.reserve1));
            // pre reserves already include the funding, so this is the principal value change of migrate()
            c.incrementalValueDelta = int256(pos) + reserveChange;
        }
        _log(tokenIs0, funding, flow, c);
    }

    // ---------------------------------------------------------------------------------------------
    // Logging
    // ---------------------------------------------------------------------------------------------

    function _name(uint8 funding, uint8 flow) internal pure returns (string memory) {
        string memory f =
            funding == FUND_TOKEN0 ? "fund=token0" : funding == FUND_TOKEN1 ? "fund=token1" : "fund=balanced";
        string memory o =
            flow == FLOW_NONE ? "flow=none" : flow == FLOW_SELL_TOKEN0 ? "flow=sell0(down)" : "flow=sell1(up)";
        return string.concat(f, " ", o);
    }

    function _outcome(Outcome o) internal pure returns (string memory) {
        if (o == Outcome.Deferred) return "DEFERRED";
        if (o == Outcome.DepositedInBounds) return "DEPOSITED_IN_BOUNDS";
        if (o == Outcome.DepositedOutOfBounds) return "DEPOSITED_OUT_OF_BOUNDS";
        return "REVERTED";
    }

    function _logSnap(string memory label, Snap memory s) internal pure {
        console2.log(label);
        console2.log("  block.timestamp", s.timestamp);
        console2.log("  twamm lastVirtualOrderExecution", s.twammLastExecution);
        console2.log("  sqrtRatio(fixed)", s.sqrtRatio.toFixed());
        console2.log("  tick", int256(s.tick));
        console2.log("  pool liquidity", s.poolLiquidity);
        console2.log("  own position liquidity", s.ownLiquidity);
        console2.log("  principal reserve0", s.reserve0);
        console2.log("  principal reserve1", s.reserve1);
        console2.log("  creator fee ledger0", s.creatorFee0);
        console2.log("  creator fee ledger1", s.creatorFee1);
        console2.log("  uncollected position fee0", s.positionFee0);
        console2.log("  uncollected position fee1", s.positionFee1);
    }

    function _log(bool tokenIs0, uint8 funding, uint8 flow, Case memory c) internal pure {
        console2.log("==== case", tokenIs0 ? "launch=token0" : "launch=token1", _name(funding, flow));
        console2.log("  bounds lower(fixed)", c.lower.toFixed());
        console2.log("  bounds upper(fixed)", c.upper.toFixed());
        console2.log("  bounds ticks +/-", int256(BOUND_TICKS));
        _logSnap(" pre", c.pre);
        console2.log(" virtual-execution-only tick (counterfactual)", int256(c.executedOnlyTick));
        console2.log(
            " virtual-execution-only in bounds", !(c.executedOnlyPrice < c.lower || c.executedOnlyPrice > c.upper)
        );
        _logSnap(" post", c.post);
        console2.log(" outcome", _outcome(c.outcome));
        if (c.reverted) console2.logBytes4(c.selector);
        console2.log(" incremental value delta @pre price (token1 units, + gain / - loss)", c.incrementalValueDelta);
    }

    function _bothOrders(uint8 funding, uint8 flow) internal returns (Case[2] memory cases) {
        for (uint256 i; i < 2; i++) {
            uint256 snapshot = vm.snapshotState();
            cases[i] = _run(i == 0, funding, flow);
            vm.revertToState(snapshot);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Controls: no open TWAMM order
    // ---------------------------------------------------------------------------------------------

    function test_eku648_control_noOrder() public {
        for (uint8 funding; funding < 3; funding++) {
            Case[2] memory cases = _bothOrders(funding, FLOW_NONE);
            for (uint256 i; i < 2; i++) {
                assertEq(uint8(cases[i].outcome), uint8(Outcome.DepositedInBounds), "control deposits in bounds");
                assertEq(cases[i].pre.timestamp, cases[i].post.timestamp);
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Witnesses: these PASS by asserting the observed (adverse) behaviour at this SHA
    // ---------------------------------------------------------------------------------------------

    /// Single-sided funding whose rebalance direction is opposite to the pending flow:
    /// stale price passes the bound check, virtual execution (inside collectFees) moves price far
    /// outside, the stale-sized swap only partially reverses it, and principal is deposited out of bounds.
    function test_eku648_witness_crossingFlowDepositsPrincipalOutsideBounds() public {
        Case[2] memory a = _bothOrders(FUND_TOKEN1, FLOW_SELL_TOKEN0);
        Case[2] memory b = _bothOrders(FUND_TOKEN0, FLOW_SELL_TOKEN1);
        for (uint256 i; i < 2; i++) {
            assertTrue(a[i].pre.sqrtRatio >= a[i].lower && a[i].pre.sqrtRatio <= a[i].upper, "stale in bounds");
            assertLt(SqrtRatio.unwrap(a[i].executedOnlyPrice), SqrtRatio.unwrap(a[i].lower), "flow exits below");
            assertEq(uint8(a[i].outcome), uint8(Outcome.DepositedOutOfBounds));
            assertLt(SqrtRatio.unwrap(a[i].post.sqrtRatio), SqrtRatio.unwrap(a[i].lower));

            assertTrue(b[i].pre.sqrtRatio >= b[i].lower && b[i].pre.sqrtRatio <= b[i].upper, "stale in bounds");
            assertGt(SqrtRatio.unwrap(b[i].executedOnlyPrice), SqrtRatio.unwrap(b[i].upper), "flow exits above");
            assertEq(uint8(b[i].outcome), uint8(Outcome.DepositedOutOfBounds));
            assertGt(SqrtRatio.unwrap(b[i].post.sqrtRatio), SqrtRatio.unwrap(b[i].upper));
        }
    }

    /// Single-sided funding whose swap direction matches the pending flow: after virtual execution the
    /// price is already beyond the swap limit (the bound), so Core rejects the limit direction.
    function test_eku648_witness_sameDirectionFlowRevertsMigration() public {
        Case[2] memory a = _bothOrders(FUND_TOKEN1, FLOW_SELL_TOKEN1);
        Case[2] memory b = _bothOrders(FUND_TOKEN0, FLOW_SELL_TOKEN0);
        for (uint256 i; i < 2; i++) {
            assertEq(uint8(a[i].outcome), uint8(Outcome.Reverted));
            assertEq(a[i].selector, ICore.SqrtRatioLimitWrongDirection.selector);
            assertEq(uint8(b[i].outcome), uint8(Outcome.Reverted));
            assertEq(b[i].selector, ICore.SqrtRatioLimitWrongDirection.selector);
            // revert rolls back virtual execution as well: principal untouched
            assertEq(a[i].post.reserve0, a[i].pre.reserve0);
            assertEq(a[i].post.reserve1, a[i].pre.reserve1);
            assertEq(a[i].post.ownLiquidity, a[i].pre.ownLiquidity);
        }
    }

    /// Exactly balanced reserves: optimalSwap is zero, collection is skipped, _deposit sizes liquidity from
    /// the stale price, then updatePosition executes virtual orders and needs more of one token than saved.
    function test_eku648_witness_balancedPendingFlowRevertsDeposit() public {
        Case[2] memory a = _bothOrders(FUND_BALANCED, FLOW_SELL_TOKEN0);
        Case[2] memory b = _bothOrders(FUND_BALANCED, FLOW_SELL_TOKEN1);
        for (uint256 i; i < 2; i++) {
            assertEq(uint8(a[i].outcome), uint8(Outcome.Reverted));
            assertEq(uint8(b[i].outcome), uint8(Outcome.Reverted));
            assertEq(a[i].post.ownLiquidity, a[i].pre.ownLiquidity);
            assertEq(b[i].post.ownLiquidity, b[i].pre.ownLiquidity);
        }
    }

    /// Recovery path for the revert cases: executing virtual orders first makes migrate observe the
    /// out-of-bounds price and defer, with principal retained.
    function test_eku648_recovery_executeVirtualOrdersThenMigrateDefers() public {
        for (uint256 i; i < 2; i++) {
            uint256 snapshot = vm.snapshotState();
            Case memory c = _setupLaunch(i == 0);
            _placeFlow(c, FLOW_SELL_TOKEN1);
            _fund(c, FUND_TOKEN1);
            vm.warp(ORDER_START + PENDING);
            uint128 liquidityBefore = _locked(c.key);
            twamm.lockAndExecuteVirtualOrders(c.terminal);
            vault.migrate(c.launchId);
            assertEq(_locked(c.key), liquidityBefore, "deferred");
            assertGt(core.poolState(c.terminal.toPoolId()).sqrtRatio().toFixed(), c.upper.toFixed());
            vm.revertToState(snapshot);
        }
    }

    /// advance() at endTime calls migrate(); pending flow on a pre-seeded terminal pool makes the
    /// whole advance revert until someone executes virtual orders separately.
    function test_eku648_witness_advanceRevertsWithPendingFlowThenRecovers() public {
        for (uint256 i; i < 2; i++) {
            uint256 snapshot = vm.snapshotState();
            bool tokenIs0 = i == 0;
            ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
            config.quoteAmount = SUPPLY;
            config.migrationTickLower = -BOUND_TICKS;
            config.migrationTickUpper = BOUND_TICKS;
            PoolKey memory key = actor.create(extension, config);
            _tokens(key);
            PoolKey memory terminal = extension.terminalPool(key);
            _seedTerminal(key, 0, 1e24);
            // Order placed before endTime; pending flow accumulates until advance().
            TwammTrader trader = new TwammTrader(core);
            TestToken(terminal.token1).approve(address(trader), type(uint256).max);
            vm.warp(1024);
            OrderKey memory order = OrderKey({
                token0: terminal.token0,
                token1: terminal.token1,
                config: createOrderConfig({_fee: FINAL_FEE, _isToken1: true, _startTime: 1024, _endTime: 1280})
            });
            trader.placeOrder(twamm, bytes32(uint256(1)), order, SALE_RATE, address(this));
            vm.warp(END + 20);
            vm.expectRevert();
            extension.advance(key);
            assertFalse(extension.getLaunch(key.toPoolId()).complete);
            console2.log(
                "advance reverted with pending flow; stale tick", int256(core.poolState(terminal.toPoolId()).tick())
            );
            twamm.lockAndExecuteVirtualOrders(terminal);
            extension.advance(key);
            assertTrue(extension.getLaunch(key.toPoolId()).complete);
            console2.log(
                "after executing virtual orders, advance completed; tick",
                int256(core.poolState(terminal.toPoolId()).tick())
            );
            console2.log("locked liquidity", _locked(key));
            vm.revertToState(snapshot);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Economic impact: first migration (advance at endTime) into an attacker-seeded terminal pool.
    // All trades are transfers, so valuing every party at the fixed reference price P0 (tick 0,
    // price 1 in raw units) conserves total value: attacker P&L = -(launch principal delta +
    // creator fee delta). Launch principal before = SUPPLY launch tokens + quoteAmount quote.
    // ---------------------------------------------------------------------------------------------

    struct Econ {
        int256 tickAfterMigration;
        bool outOfBounds;
        uint128 liquidity;
        int256 principalDelta; // position (withdrawable at P0) + residual reserves - original principal
        int256 creatorFees;
        int256 attackerPnl;
    }

    function _econ(bool tokenIs0, int112 rate, uint128 lpLiquidity, uint128 quoteAmount, bool sellQuote)
        internal
        returns (Econ memory e)
    {
        ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
        config.quoteAmount = quoteAmount;
        config.migrationTickLower = -BOUND_TICKS;
        config.migrationTickUpper = BOUND_TICKS;
        PoolKey memory key = actor.create(extension, config);
        _tokens(key);
        PoolKey memory terminal = extension.terminalPool(key);
        _seedTerminal(key, 0, lpLiquidity); // attacker-owned liquidity at the reference price
        address launchToken = extension.getLaunch(key.toPoolId()).token;
        if (rate != 0) {
            // Crossing flow: the launch's balancing swap and the attacker's pending TWAMM sale point in
            // opposite directions (excess quote + attacker sells launch tokens, or vice versa).
            TwammTrader trader = new TwammTrader(core);
            MintableERC20(launchToken).approve(address(trader), type(uint256).max);
            TestToken(tokenIs0 ? terminal.token1 : terminal.token0).approve(address(trader), type(uint256).max);
            vm.warp(1024);
            OrderKey memory order = OrderKey({
                token0: terminal.token0,
                token1: terminal.token1,
                config: createOrderConfig({
                    _fee: FINAL_FEE, _isToken1: sellQuote ? tokenIs0 : !tokenIs0, _startTime: 1024, _endTime: 1280
                })
            });
            trader.placeOrder(twamm, bytes32(uint256(1)), order, rate, address(this));
        }
        vm.warp(END + 20);
        SqrtRatio p0 = core.poolState(terminal.toPoolId()).sqrtRatio();
        extension.advance(key);
        PoolId launchId = key.toPoolId();
        e.tickAfterMigration = core.poolState(terminal.toPoolId()).tick();
        SqrtRatio pm = core.poolState(terminal.toPoolId()).sqrtRatio();
        LockedLaunchLiquidity.Terminal memory t = vault.getTerminal(launchId);
        e.outOfBounds = pm < t.lower || pm > t.upper;
        e.liquidity = _locked(key);
        // Attacker arbitrages the pool back to P0 in the same block.
        if (pm != p0) {
            router.swapAllowPartialFill(terminal, pm < p0, type(int128).max, p0, 0);
        }
        assertEq(SqrtRatio.unwrap(core.poolState(terminal.toPoolId()).sqrtRatio()), SqrtRatio.unwrap(p0));
        (uint128 r0, uint128 r1) = _balances(address(vault), key, PoolId.unwrap(launchId));
        uint256 after_ = _value(
            p0,
            uint256(amount0Delta(p0, MAX_SQRT_RATIO, e.liquidity, false)) + r0,
            uint256(amount1Delta(MIN_SQRT_RATIO, p0, e.liquidity, false)) + r1
        );
        uint256 before = tokenIs0 ? _value(p0, SUPPLY, quoteAmount) : _value(p0, quoteAmount, SUPPLY);
        e.principalDelta = int256(after_) - int256(before);
        Position memory own = core.poolPositions(terminal.toPoolId(), address(vault), vault.positionId(launchId));
        (uint128 f0, uint128 f1) = own.fees(core.getPoolFeesPerLiquidity(terminal.toPoolId()));
        (uint128 c0, uint128 c1) = _balances(address(vault), key, vault.creatorFeeSalt(launchId));
        (uint128 x0, uint128 x1) = _fees(key);
        e.creatorFees = int256(_value(p0, uint256(f0) + c0 + x0, uint256(f1) + c1 + x1));
        e.attackerPnl = -(e.principalDelta + e.creatorFees);
        console2.log("==== econ", tokenIs0 ? "launch=token0" : "launch=token1");
        console2.log("  saleRate", int256(rate));
        console2.log("  attacker sells", sellQuote ? "quote" : "launch token");
        console2.log("  attacker TWAMM tokens sold by migration (rate*96s/2^32)", uint256(uint112(rate)) * 96 >> 32);
        console2.log("  attacker LP liquidity", lpLiquidity);
        console2.log("  quoteAmount", quoteAmount);
        console2.log("  tick at deposit", e.tickAfterMigration);
        console2.log("  deposit out of bounds", e.outOfBounds);
        console2.log("  locked liquidity", e.liquidity);
        console2.log("  principal delta @P0 (after arbitrage back)", e.principalDelta);
        console2.log("  creator fees @P0", e.creatorFees);
        console2.log("  attacker P&L @P0 (conservation)", e.attackerPnl);
    }

    function _econSweep(uint128 quoteAmount, bool sellQuote) internal {
        int112[4] memory rates = [int112(0), int112(1e30), int112(4e30), int112(1.6e31)];
        uint128[2] memory lps = [uint128(1e23), uint128(1e24)];
        for (uint256 o; o < 2; o++) {
            for (uint256 l; l < 2; l++) {
                for (uint256 r; r < 4; r++) {
                    uint256 snapshot = vm.snapshotState();
                    _econ(o == 0, rates[r], lps[l], quoteAmount, sellQuote);
                    vm.revertToState(snapshot);
                }
            }
        }
    }

    /// 1% excess quote: the stale-sized swap is large enough to pull price back to the bound.
    function test_eku648_economics_imbalancedPrincipal() public {
        _econSweep(SUPPLY + SUPPLY / 100, false);
    }

    /// 0.0001% excess quote: optimalSwap is nonzero (so collectFees executes the flow) but too small
    /// to pull price back; principal is deposited at the manipulated price.
    function test_eku648_economics_nearBalancedPrincipal() public {
        _econSweep(SUPPLY + SUPPLY / 1_000_000, false);
    }

    /// Same attack with quote-only attacker capital: principal has a tiny launch-token excess (so the
    /// launch sells launch tokens) and the attacker's TWAMM order sells quote, pushing price up.
    function test_eku648_economics_nearBalancedPrincipalQuoteOnlyAttacker() public {
        _econSweep(SUPPLY - SUPPLY / 1_000_000, true);
    }

    // ---------------------------------------------------------------------------------------------
    // Property over the full matrix: EXPECTED TO FAIL at this SHA if any deposit lands out of bounds.
    // ---------------------------------------------------------------------------------------------

    function test_eku648_property_everyPrincipalDepositRespectsBoundsAfterVirtualExecution() public {
        uint256 violations;
        uint256 reverts;
        for (uint8 funding; funding < 3; funding++) {
            for (uint8 flow; flow < 3; flow++) {
                Case[2] memory cases = _bothOrders(funding, flow);
                for (uint256 i; i < 2; i++) {
                    if (cases[i].outcome == Outcome.DepositedOutOfBounds) violations++;
                    if (cases[i].outcome == Outcome.Reverted) reverts++;
                }
            }
        }
        console2.log("matrix cases", uint256(18));
        console2.log("out-of-bounds principal deposits", violations);
        console2.log("reverts (liveness)", reverts);
        assertEq(violations, 0, "principal deposited outside immutable migration bounds");
    }
}
