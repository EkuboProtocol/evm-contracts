// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

// Capital-accounted attacker economics for the EKU-648 attack (EKU-645 gate P2). The attacker starts with
// quote only and gets launch tokens through a LaunchRouter buy, never a cheatcode. It seeds the TWAMM
// terminal pool, leaves pending TWAMM flow across endTime, lets advance() migrate, arbitrages back to the
// reference price and unwinds everything. Each attack is compared with a matched control without the order.

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {ScheduledLaunchTest} from "./ScheduledLaunch.t.sol";
import {TestToken} from "../TestToken.sol";
import {LaunchRouter} from "../../src/LaunchRouter.sol";
import {ScheduledLaunch, MAX_MIGRATION_TICK_WIDTH} from "../../src/extensions/ScheduledLaunch.sol";
import {LockedLaunchLiquidity} from "../../src/LockedLaunchLiquidity.sol";
import {Positions} from "../../src/Positions.sol";
import {Orders} from "../../src/Orders.sol";
import {MintableERC20} from "../../src/MintableERC20.sol";
import {ITWAMM} from "../../src/interfaces/extensions/ITWAMM.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {Position} from "../../src/types/position.sol";
import {OrderKey} from "../../src/types/orderKey.sol";
import {createOrderConfig} from "../../src/types/orderConfig.sol";
import {createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {amount0Delta, amount1Delta} from "../../src/math/delta.sol";
import {computeFee} from "../../src/math/fee.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract ScheduledLaunchCapitalAccountedTest is ScheduledLaunchTest {
    using CoreLib for *;

    address constant ATTACKER = address(0xA77AC4E5);
    uint128 constant ATTACKER_QUOTE = 1e24;
    uint128 constant BUY_QUOTE = 1e22;
    uint64 constant BUY_TIME = 1000;
    uint64 constant ORDER_START = 1024;
    uint64 constant ORDER_END = 1280;
    uint64 constant MIGRATE_TIME = END + 20; // 96 seconds of pending flow
    int32 constant BOUND_TICKS = 2_000; // +/-0.2% around the reference price
    // Principal holds this much more launch token than quote at the reference price, so migration sells
    // launch token while the attacker's order sells quote: the crossing case of EKU-648.
    uint128 constant LAUNCH_EXCESS = SUPPLY / 1_000_000;
    // Core rounds amounts in its own favor at sqrt-price precision, about 1e-18 of liquidity per operation.
    // One part in 1e15 of supply bounds that residue with a wide margin and is far below any fee.
    uint256 constant ROUNDING = SUPPLY / 1e15;

    // Migration window of the run, in raw quote units per launch token.
    int32 boundLower = -BOUND_TICKS;
    int32 boundUpper = BOUND_TICKS;
    // Tenths of the bought launch tokens seeded into the terminal pool; the rest funds the arbitrage back.
    uint256 seedTenths = 9;
    // Principal holds this many launch tokens per quote unit, beyond LAUNCH_EXCESS.
    uint256 principalDivisor = 1;

    LaunchRouter launchRouter;
    Positions lpPositions;
    Orders orders;

    struct Run {
        bool tokenIs0;
        uint128 orderAmount;
        PoolKey key;
        PoolKey terminal;
        // Attacker capital
        uint256 tokensBought;
        uint256 quotePaid;
        uint256 lpId;
        uint128 lpLiquidity;
        uint256 lpQuote;
        uint256 lpTokens;
        uint256 orderId;
        uint112 saleRate;
        uint128 orderRefund;
        uint128 orderProceeds;
        uint128 lpOut0;
        uint128 lpOut1;
        int256 attackerPnl;
        // Launch principal at the reference price P0
        uint256 principalIn0;
        uint256 principalIn1;
        uint256 principalBefore;
        uint256 principalAtMigrationPrice;
        uint256 principalAfter;
        int256 principalDelta;
        uint256 migrationSwapFee;
        int32 migrationTick;
        bool deposited;
        uint128 lockedLiquidity;
        uint256 creatorFees;
    }

    function setUp() public override {
        super.setUp();
        launchRouter = new LaunchRouter(core, extension);
        // No protocol fees, so every fee is visible in the pool or the launch ledgers.
        lpPositions = new Positions(core, address(this), 0, 0);
        orders = new Orders(core, ITWAMM(address(twamm)), address(this));
        for (uint256 i; i < 2; i++) {
            address quote = i == 0 ? LOW_QUOTE : HIGH_QUOTE;
            TestToken(quote).transfer(ATTACKER, ATTACKER_QUOTE);
            vm.startPrank(ATTACKER);
            TestToken(quote).approve(address(launchRouter), type(uint256).max);
            TestToken(quote).approve(address(lpPositions), type(uint256).max);
            TestToken(quote).approve(address(orders), type(uint256).max);
            TestToken(quote).approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _quote(bool tokenIs0) internal pure returns (address) {
        return tokenIs0 ? HIGH_QUOTE : LOW_QUOTE;
    }

    function _p0Value(uint256 a0, uint256 a1) internal pure returns (uint256) {
        // Reference price is tick 0: one raw quote unit per raw launch unit, in either order.
        return a0 + a1;
    }

    function _config(bool tokenIs0, uint128 quoteAmount) internal view returns (ScheduledLaunch.LaunchConfig memory c) {
        c = _config(_quote(tokenIs0));
        c.quoteAmount = quoteAmount;
        c.migrationTickLower = boundLower;
        c.migrationTickUpper = boundUpper;
    }

    function _attackerBuy(PoolKey memory key, bool tokenIs0) internal returns (uint256 bought) {
        vm.warp(BUY_TIME);
        vm.prank(ATTACKER);
        PoolBalanceUpdate update = launchRouter.swap(
            key,
            createSwapParameters(SqrtRatio.wrap(0), int128(BUY_QUOTE), tokenIs0, 0),
            1,
            ATTACKER,
            vm.getBlockTimestamp()
        );
        bought = uint128(-(tokenIs0 ? update.delta0() : update.delta1()));
    }

    /// @dev The launch pool is at its target when the buy lands, so the buy fills from released launch
    /// tokens only and its output does not depend on quoteAmount. One dry run fixes quoteAmount so the
    /// principal that reaches migration holds exactly LAUNCH_EXCESS more launch token than principalDivisor
    /// times its quote.
    function _calibratedQuoteAmount(bool tokenIs0) internal returns (uint128) {
        uint256 snapshot = vm.snapshotState();
        PoolKey memory key = actor.create(extension, _config(tokenIs0, 0));
        uint256 bought = _attackerBuy(key, tokenIs0);
        (uint128 f0, uint128 f1) = _fees(key);
        uint256 fee = tokenIs0 ? f0 : f1;
        vm.revertToState(snapshot);
        return uint128((SUPPLY - bought - fee - LAUNCH_EXCESS) / principalDivisor - BUY_QUOTE);
    }

    function _run(bool tokenIs0, uint128 orderAmount) internal returns (Run memory r) {
        r.tokenIs0 = tokenIs0;
        r.orderAmount = orderAmount;
        uint128 quoteAmount = _calibratedQuoteAmount(tokenIs0);
        r.key = actor.create(extension, _config(tokenIs0, quoteAmount));
        r.terminal = extension.terminalPool(r.key);
        address launchToken = extension.getLaunch(r.key.toPoolId()).token;
        address quote = _quote(tokenIs0);
        vm.startPrank(ATTACKER);
        MintableERC20(launchToken).approve(address(lpPositions), type(uint256).max);
        MintableERC20(launchToken).approve(address(router), type(uint256).max);
        vm.stopPrank();

        // 1. Permitted launch trade: the attacker's only source of launch tokens.
        r.tokensBought = _attackerBuy(r.key, tokenIs0);
        r.quotePaid = ATTACKER_QUOTE - TestToken(quote).balanceOf(ATTACKER);
        assertEq(r.quotePaid, BUY_QUOTE);
        assertEq(MintableERC20(launchToken).balanceOf(ATTACKER), r.tokensBought);

        // 2. Seed the terminal pool at the reference price, keeping the rest of the launch tokens to
        // arbitrage the price back down if migration leaves it above the reference.
        vm.startPrank(ATTACKER);
        lpPositions.maybeInitializePool(r.terminal, 0);
        uint128 seed = uint128(r.tokensBought * seedTenths / 10);
        uint128 a0;
        uint128 a1;
        (r.lpId, r.lpLiquidity, a0, a1) = lpPositions.mintAndDeposit(r.terminal, MIN_TICK, MAX_TICK, seed, seed, 0);
        (r.lpTokens, r.lpQuote) = tokenIs0 ? (uint256(a0), uint256(a1)) : (uint256(a1), uint256(a0));

        // 3. Pending TWAMM flow selling quote across endTime. Quote is token1 when the launch is token0.
        OrderKey memory order = OrderKey({
            token0: r.terminal.token0,
            token1: r.terminal.token1,
            config: createOrderConfig({
                _fee: FINAL_FEE, _isToken1: tokenIs0, _startTime: ORDER_START, _endTime: ORDER_END
            })
        });
        if (orderAmount != 0) {
            (r.orderId, r.saleRate) = orders.mintAndIncreaseSellAmount(order, uint112(orderAmount), type(uint112).max);
        }
        vm.stopPrank();

        // 4. Anyone advances at endTime; migration executes the pending flow, balances and deposits.
        vm.warp(MIGRATE_TIME);
        SqrtRatio p0 = SqrtRatio.wrap(0);
        p0 = core.poolState(r.terminal.toPoolId()).sqrtRatio();
        vm.recordLogs();
        extension.advance(r.key);
        _readMigrationLogs(r, vm.getRecordedLogs());
        r.principalBefore = _p0Value(r.principalIn0, r.principalIn1);
        SqrtRatio pm = core.poolState(r.terminal.toPoolId()).sqrtRatio();
        r.migrationTick = core.poolState(r.terminal.toPoolId()).tick();
        r.lockedLiquidity = _locked(r.key);
        r.deposited = r.lockedLiquidity != 0;
        r.principalAtMigrationPrice = _principal(r, pm);

        // 5. Arbitrage back to the reference price, then unwind the order and the LP position.
        vm.startPrank(ATTACKER);
        if (pm != p0) router.swapAllowPartialFill(r.terminal, pm < p0, type(int128).max, p0, 0);
        assertEq(SqrtRatio.unwrap(core.poolState(r.terminal.toPoolId()).sqrtRatio()), SqrtRatio.unwrap(p0));
        if (orderAmount != 0) {
            // Collect first: cutting the sale rate to zero resets the order's reward snapshot.
            r.orderProceeds = orders.collectProceeds(r.orderId, order);
            r.orderRefund = orders.decreaseSaleRate(r.orderId, order, r.saleRate);
        }
        (r.lpOut0, r.lpOut1) = lpPositions.withdraw(r.lpId, r.terminal, MIN_TICK, MAX_TICK, r.lpLiquidity);
        vm.stopPrank();

        // Attacker P&L from its own balances, valued at P0. No conservation inference.
        uint256 attackerAfter =
            _p0Value(MintableERC20(launchToken).balanceOf(ATTACKER), TestToken(quote).balanceOf(ATTACKER));
        r.attackerPnl = int256(attackerAfter) - int256(uint256(ATTACKER_QUOTE));

        r.principalAfter = _principal(r, p0);
        r.principalDelta = int256(r.principalAfter) - int256(r.principalBefore);
        r.creatorFees = _creatorFees(r);
        _assertCoreFullyAttributed(r, p0);
        _log(r);
    }

    function _readMigrationLogs(Run memory r, Vm.Log[] memory logs) internal view {
        bytes32 received = keccak256("PrincipalReceived(bytes32,uint128,uint128)");
        PoolId terminalId = r.terminal.toPoolId();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(vault) && logs[i].topics.length != 0 && logs[i].topics[0] == received) {
                (uint128 amount0, uint128 amount1) = abi.decode(logs[i].data, (uint128, uint128));
                r.principalIn0 += amount0;
                r.principalIn1 += amount1;
            }
            // Core swap log: locker (20) | poolId (32) | balanceUpdate (32) | stateAfter (32).
            if (logs[i].emitter != address(core) || logs[i].topics.length != 0 || logs[i].data.length != 116) continue;
            bytes memory data = logs[i].data;
            address locker;
            bytes32 poolId;
            bytes32 update;
            assembly ("memory-safe") {
                locker := shr(96, mload(add(data, 32)))
                poolId := mload(add(data, 52))
                update := mload(add(data, 84))
            }
            if (locker != address(vault) || poolId != PoolId.unwrap(terminalId)) continue;
            PoolBalanceUpdate u = PoolBalanceUpdate.wrap(update);
            uint128 input = uint128(u.delta0() > 0 ? u.delta0() : u.delta1());
            r.migrationSwapFee += computeFee(input, FINAL_FEE);
        }
    }

    /// Locked principal: the vault position's withdrawable amounts at `price` plus unspent reserves, at P0.
    function _principal(Run memory r, SqrtRatio price) internal view returns (uint256) {
        uint128 liquidity = _locked(r.key);
        (uint128 reserve0, uint128 reserve1) = _balances(address(vault), r.key, PoolId.unwrap(r.key.toPoolId()));
        return _p0Value(
            uint256(amount0Delta(price, MAX_SQRT_RATIO, liquidity, false)) + reserve0,
            uint256(amount1Delta(MIN_SQRT_RATIO, price, liquidity, false)) + reserve1
        );
    }

    function _positionFees(Run memory r) internal view returns (uint128, uint128) {
        PoolId terminalId = r.terminal.toPoolId();
        Position memory own = core.poolPositions(terminalId, address(vault), vault.positionId(r.key.toPoolId()));
        return own.fees(core.getPoolFeesPerLiquidity(terminalId));
    }

    function _creatorFees(Run memory r) internal view returns (uint256) {
        (uint128 x0, uint128 x1) = _fees(r.key);
        (uint128 c0, uint128 c1) = _balances(address(vault), r.key, vault.creatorFeeSalt(r.key.toPoolId()));
        (uint128 f0, uint128 f1) = _positionFees(r);
        return _p0Value(uint256(x0) + c0 + f0, uint256(x1) + c1 + f1);
    }

    /// After the attacker unwinds, Core's balance of each token is exactly what the launch, the vault and
    /// the creator are owed, up to rounding in Core's favor. Nothing is unaccounted for.
    function _assertCoreFullyAttributed(Run memory r, SqrtRatio p0) internal view {
        uint128 liquidity = _locked(r.key);
        PoolId launchId = r.key.toPoolId();
        (uint128 v0, uint128 v1) = _balances(address(vault), r.key, PoolId.unwrap(launchId));
        (uint128 c0, uint128 c1) = _balances(address(vault), r.key, vault.creatorFeeSalt(launchId));
        (uint128 x0, uint128 x1) = _fees(r.key);
        (uint128 l0, uint128 l1) = _balances(address(extension), r.key, PoolId.unwrap(launchId));
        (uint128 f0, uint128 f1) = _positionFees(r);
        uint256 owed0 = uint256(amount0Delta(p0, MAX_SQRT_RATIO, liquidity, false)) + v0 + c0 + x0 + l0 + f0;
        uint256 owed1 = uint256(amount1Delta(MIN_SQRT_RATIO, p0, liquidity, false)) + v1 + c1 + x1 + l1 + f1;
        uint256 held0 = MintableERC20(r.terminal.token0).balanceOf(address(core));
        uint256 held1 = MintableERC20(r.terminal.token1).balanceOf(address(core));
        assertGe(held0, owed0, "core token0 covers every claim");
        assertGe(held1, owed1, "core token1 covers every claim");
        assertLe(held0 - owed0, ROUNDING, "core token0 residue is rounding");
        assertLe(held1 - owed1, ROUNDING, "core token1 residue is rounding");
    }

    function _log(Run memory r) internal pure {
        console2.log("==== capital-accounted", r.tokenIs0 ? "launch=token0" : "launch=token1");
        console2.log("  attacker TWAMM quote sold over 256s (0 = control)", r.orderAmount);
        console2.log("  attacker quote paid for launch tokens", r.quotePaid);
        console2.log("  attacker launch tokens bought", r.tokensBought);
        console2.log("  LP seed launch tokens", r.lpTokens);
        console2.log("  LP seed quote", r.lpQuote);
        console2.log("  order refund (quote)", r.orderRefund);
        console2.log("  order proceeds (launch token)", r.orderProceeds);
        console2.log("  LP unwind token0", r.lpOut0);
        console2.log("  LP unwind token1", r.lpOut1);
        console2.log("  migration tick", int256(r.migrationTick));
        console2.log("  deposited", r.deposited);
        console2.log("  principal in @P0", r.principalBefore);
        console2.log("  principal @migration price, valued @P0", r.principalAtMigrationPrice);
        console2.log("  principal after arbitrage @P0", r.principalAfter);
        console2.log("  principal delta @P0", r.principalDelta);
        console2.log("  migration swap fee paid by principal", r.migrationSwapFee);
        console2.log("  principal loss beyond fee", _beyondFee(r));
        console2.log("  creator fees @P0", r.creatorFees);
        console2.log("  attacker P&L @P0 (measured)", r.attackerPnl);
    }

    /// Principal loss at P0 beyond the migration's own swap fee; negative when the loss is under the fee.
    function _beyondFee(Run memory r) internal pure returns (int256) {
        return -r.principalDelta - int256(r.migrationSwapFee);
    }

    /// P2: principal at the reference price falls by no more than the migration's own swap fee, rounding,
    /// and the price impact of that swap. Impact is what remains in the no-attack control (about 1e-13 of
    /// principal here), so it is bounded at one part in 1e12 of principal rather than called rounding.
    function _assertGate(Run memory r) internal pure {
        assertLe(_beyondFee(r), int256(r.principalBefore / 1e12 + ROUNDING), "principal loss beyond fees");
        if (!r.deposited) {
            assertEq(r.principalAfter, r.principalBefore, "deferred migration keeps principal");
            assertEq(r.migrationSwapFee, 0, "deferred migration pays no fee");
        }
    }

    /// Runs each order size against a matched control in both token orders and returns how many deposited.
    function _attackVsMatchedControl(uint128[] memory amounts) internal returns (uint256 deposited) {
        for (uint256 o; o < 2; o++) {
            uint256 snapshot = vm.snapshotState();
            Run memory control = _run(o == 0, 0);
            vm.revertToState(snapshot);
            _assertGate(control);
            assertTrue(control.deposited, "control migrates");
            for (uint256 a; a < amounts.length; a++) {
                Run memory attack = _run(o == 0, amounts[a]);
                vm.revertToState(snapshot);
                _assertGate(attack);
                assertEq(attack.principalBefore, control.principalBefore, "matched principal");
                assertEq(attack.tokensBought, control.tokensBought, "matched buy");
                assertEq(attack.lpLiquidity, control.lpLiquidity, "matched LP");
                assertGt(attack.orderProceeds, 0, "pending flow executed");
                if (attack.deposited) deposited++;
                console2.log("  >> attack - control: principal delta", attack.principalDelta - control.principalDelta);
                console2.log("  >> attack - control: attacker P&L", attack.attackerPnl - control.attackerPnl);
            }
        }
    }

    function _widestWindow() internal {
        boundLower = -MAX_MIGRATION_TICK_WIDTH / 2;
        boundUpper = boundLower + MAX_MIGRATION_TICK_WIDTH;
        // Arbitrage back across the wider window needs more of the attacker's launch tokens.
        seedTenths = 5;
    }

    /// Order sizes run from flow that leaves the executed price near the reference, through the largest
    /// order whose executed price stays inside the +/-0.2% bounds (22e18), to orders that push it out.
    function test_capitalAccounted_attackVsMatchedControl() public {
        uint128[] memory amounts = new uint128[](5);
        (amounts[0], amounts[1], amounts[2], amounts[3], amounts[4]) = (1e18, 1e19, 22e18, 24e18, 1e21);
        assertEq(_attackVsMatchedControl(amounts), 6, "in-bounds attacks deposit");
    }

    /// The same attack within the widest window the extension accepts, about 10x centred on P0. 1.02e22 is
    /// the largest order whose executed price stays inside it; 1.03e22 pushes it out. Principal balanced at
    /// P0 rebalances against the pushed price in its own favour, so it gains and the gate holds.
    function test_capitalAccounted_widestWindow_attackVsMatchedControl() public {
        _widestWindow();
        uint128[] memory amounts = new uint128[](6);
        (amounts[0], amounts[1], amounts[2], amounts[3], amounts[4], amounts[5]) =
        (1e18, 1e20, 1e21, 1e22, 1.02e22, 1.03e22);
        assertEq(_attackVsMatchedControl(amounts), 10, "in-bounds attacks deposit");
    }

    /// What the width costs: principal whose own ratio is a third of P0 (tick -1_098_612) lies inside the
    /// widest window but outside +/-0.2%. Migration deposits as far from P0 as the window lets it, and arbitrage
    /// back to P0 takes the divergence loss 1 - 2 * sqrt(k) / (1 + k), with no attacker order at all. With
    /// +/-0.2% bounds it rebalances only to the bound, keeping the rest as reserves: at most (0.002)^2 / 8 =
    /// 0.5 ppm. With the widest window it deposits near its own ratio: at most 1 - 2 * sqrt(3) / 4 = 13.4%.
    function test_capitalAccounted_widestWindow_offMarketPrincipal() public {
        principalDivisor = 3;
        seedTenths = 5;
        for (uint256 o; o < 2; o++) {
            uint256 snapshot = vm.snapshotState();
            Run memory narrow = _run(o == 0, 0);
            vm.revertToState(snapshot);
            assertLe(-narrow.principalDelta, int256(narrow.principalBefore / 2e6), "within +/-0.2% divergence bound");
            _widestWindow();
            Run memory wide = _run(o == 0, 0);
            vm.revertToState(snapshot);
            boundLower = -BOUND_TICKS;
            boundUpper = BOUND_TICKS;
            assertTrue(wide.deposited, "widest window migrates");
            assertEq(wide.principalBefore, narrow.principalBefore, "matched principal");
            assertGt(_beyondFee(wide), int256(wide.principalBefore / 1e12 + ROUNDING), "loss exceeds the P2 gate");
            assertLe(-wide.principalDelta, int256(wide.principalBefore * 134 / 1000), "loss within divergence bound");
            assertGt(wide.attackerPnl, 0, "arbitrage profits");
            console2.log("  >> off-market principal loss @P0, +/-0.2%", -narrow.principalDelta);
            console2.log("  >> off-market principal loss @P0, widest", -wide.principalDelta);
        }
    }
}
