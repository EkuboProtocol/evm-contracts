// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

// Non-standard quote tokens through LaunchRouter (EKU-645 gate P3). Each behavior either reverts cleanly or
// accounts exactly against a standard-token control at the same address and ordering. Supported behaviors
// decide which tokens may enter the quote allowlist.

import {LaunchRouterTest} from "./LaunchRouter.t.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";
import {ScheduledLaunch} from "../src/extensions/ScheduledLaunch.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {IFlashAccountant} from "../src/interfaces/IFlashAccountant.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {SwapParameters, createSwapParameters} from "../src/types/swapParameters.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";

/// @dev Share-based ERC20. At the default index of 1e18 it behaves like a standard token.
abstract contract MockQuoteBase {
    mapping(address => uint256) public shares;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public index = 1e18;
    bool public frozen;

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function balanceOf(address account) public view returns (uint256) {
        return shares[account] * index / 1e18;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        shares[to] += amount * 1e18 / index;
    }

    function setFrozen(bool value) external {
        frozen = value;
    }

    /// @dev Returns false instead of moving tokens when the transfer cannot be made.
    function _tryTransfer(address from, address to, uint256 amount) internal virtual returns (bool) {
        if (frozen) return false;
        if (msg.sender != from) {
            if (allowance[from][msg.sender] < amount) return false;
            if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        }
        uint256 moved = amount * 1e18 / index;
        if (shares[from] < moved) return false;
        _move(from, to, moved);
        return true;
    }

    function _move(address from, address to, uint256 moved) internal virtual {
        shares[from] -= moved;
        shares[to] += moved;
    }
}

contract StandardQuote is MockQuoteBase {
    function transfer(address to, uint256 amount) external returns (bool) {
        require(_tryTransfer(msg.sender, to, amount), "transfer");
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(_tryTransfer(from, to, amount), "transferFrom");
        return true;
    }
}

/// @dev Burns 1% of every transfer from the amount the recipient receives.
contract FeeOnTransferQuote is StandardQuote {
    function _move(address from, address to, uint256 moved) internal override {
        shares[from] -= moved;
        shares[to] += moved - moved / 100;
    }
}

/// @dev Balances scale with an index anyone can set; transfers move floor(amount / index) shares.
contract RebasingQuote is StandardQuote {
    function setIndex(uint256 value) external {
        index = value;
    }
}

interface IQuoteHooks {
    function tokensToSend(address from, address to, uint256 amount) external;
    function tokensReceived(address from, address to, uint256 amount) external;
}

/// @dev ERC-777 style: calls the sender before and the recipient after the balance change, if registered.
contract HookQuote is StandardQuote {
    mapping(address => bool) public hooked;

    function register(bool value) external {
        hooked[msg.sender] = value;
    }

    function _tryTransfer(address from, address to, uint256 amount) internal override returns (bool ok) {
        if (hooked[from]) IQuoteHooks(from).tokensToSend(from, to, amount);
        ok = super._tryTransfer(from, to, amount);
        if (ok && hooked[to]) IQuoteHooks(to).tokensReceived(from, to, amount);
    }
}

/// @dev Reverts on every transfer while frozen, like an issuer pause.
contract RevertingQuote is StandardQuote {}

/// @dev Returns false on failure instead of reverting.
contract ReturnsFalseQuote is MockQuoteBase {
    function transfer(address to, uint256 amount) external returns (bool) {
        return _tryTransfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        return _tryTransfer(from, to, amount);
    }
}

/// @dev USDT style: no return value, reverts on failure.
contract MissingReturnQuote is MockQuoteBase {
    function transfer(address to, uint256 amount) external {
        require(_tryTransfer(msg.sender, to, amount), "transfer");
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(_tryTransfer(from, to, amount), "transferFrom");
    }
}

/// @dev Payer or recipient that reenters LaunchRouter with a buy from inside a token hook.
contract ReentrantTrader is IQuoteHooks {
    LaunchRouter immutable ROUTER;
    HookQuote immutable QUOTE;
    PoolKey key;
    SwapParameters params;
    bool sendArmed;
    bool receiveArmed;
    PoolBalanceUpdate public nested;

    constructor(LaunchRouter router, HookQuote quote) {
        ROUTER = router;
        QUOTE = quote;
        quote.approve(address(router), type(uint256).max);
        quote.register(true);
    }

    function arm(PoolKey memory key_, SwapParameters params_, bool onSend, bool onReceive) external {
        key = key_;
        params = params_;
        sendArmed = onSend;
        receiveArmed = onReceive;
    }

    function approveToken(address token) external {
        MintableERC20(token).approve(address(ROUTER), type(uint256).max);
    }

    function create(ScheduledLaunch.LaunchConfig memory config) external returns (PoolKey memory k) {
        (k,) = ROUTER.create(config, block.timestamp);
    }

    function swap(PoolKey memory key_, SwapParameters params_, address recipient) external returns (PoolBalanceUpdate) {
        return ROUTER.swap(key_, params_, type(int256).min + 1, recipient, block.timestamp);
    }

    function fund(PoolId launchId, uint128 amount0, uint128 amount1) external {
        ROUTER.fund(launchId, amount0, amount1, block.timestamp);
    }

    function tokensToSend(address, address, uint256) external {
        if (!sendArmed || msg.sender != address(QUOTE)) return;
        sendArmed = false;
        nested = ROUTER.swap(key, params, type(int256).min + 1, address(this), block.timestamp);
    }

    function tokensReceived(address, address, uint256) external {
        if (!receiveArmed || msg.sender != address(QUOTE)) return;
        receiveArmed = false;
        nested = ROUTER.swap(key, params, type(int256).min + 1, address(this), block.timestamp);
    }
}

contract LaunchRouterQuoteTokensTest is LaunchRouterTest {
    using CoreLib for *;

    // Below and above any launch token address, so the quote is token0 or token1 respectively.
    address constant QUOTE_LOW = address(0x20000);
    address constant QUOTE_HIGH = address(type(uint160).max - 0xffff);
    uint128 constant CREATE_QUOTE = 7e18;
    int128 constant BUY = 1_000e18;
    uint128 constant FUND = 3e18;

    /// Everything the flow observes. A behavior accounts exactly when it reproduces the standard control.
    struct Obs {
        PoolKey key;
        bool quoteIs0;
        PoolBalanceUpdate buy;
        PoolBalanceUpdate sell;
        uint128 principalQuote;
        uint128 principalToken;
        uint128 feeQuote;
        uint128 feeToken;
        uint128 lockedLiquidity;
        uint128 vaultReserve0;
        uint128 vaultReserve1;
        uint256 coreQuote;
        uint256 payerQuote;
        uint256 recipientQuote;
        uint256 ownerQuote;
    }

    function _deployQuote(string memory name, bool low) internal returns (address quote) {
        quote = low ? QUOTE_LOW : QUOTE_HIGH;
        deployCodeTo(string.concat("LaunchRouterQuoteTokens.t.sol:", name), quote);
        MockQuoteBase(quote).mint(PAYER, 1_000_000e18);
        vm.prank(PAYER);
        MockQuoteBase(quote).approve(address(launchRouter), type(uint256).max);
    }

    function _bal(address quote, address account) internal view returns (uint256) {
        return MockQuoteBase(quote).balanceOf(account);
    }

    function _quoteDelta(Obs memory o, PoolBalanceUpdate u) internal pure returns (int128) {
        return o.quoteIs0 ? u.delta0() : u.delta1();
    }

    function _tokenDelta(Obs memory o, PoolBalanceUpdate u) internal pure returns (int128) {
        return o.quoteIs0 ? u.delta1() : u.delta0();
    }

    function _assertRouterHoldsNothing(address quote, PoolKey memory key) internal view {
        assertEq(_bal(quote, address(launchRouter)), 0, "router quote");
        _assertRouterEmpty(key);
    }

    function _routerCreateQuote(address quote, uint128 quoteAmount) internal returns (Obs memory o) {
        uint256 core0 = _bal(quote, address(core));
        uint256 payer0 = _bal(quote, PAYER);
        (o.key,) = _routerCreate(quote, quoteAmount, 0);
        o.quoteIs0 = o.key.token0 == quote;
        assertEq(_bal(quote, address(core)) - core0, quoteAmount, "create: core receives quoteAmount");
        assertEq(payer0 - _bal(quote, PAYER), quoteAmount, "create: payer pays quoteAmount");
        (uint128 r0, uint128 r1) = _balances(address(extension), o.key, PoolId.unwrap(o.key.toPoolId()));
        assertEq(o.quoteIs0 ? r0 : r1, quoteAmount, "create: principal");
        _assertRouterHoldsNothing(quote, o.key);
    }

    function _buyParamsFor(Obs memory o, int128 amount) internal pure returns (SwapParameters) {
        return _buyParams(!o.quoteIs0, amount);
    }

    function _routerBuy(Obs memory o, address quote) internal {
        uint256 core0 = _bal(quote, address(core));
        uint256 payer0 = _bal(quote, PAYER);
        vm.prank(PAYER);
        o.buy = launchRouter.swap(o.key, _buyParamsFor(o, BUY), 1, PAYER, block.timestamp);
        assertEq(_quoteDelta(o, o.buy), BUY, "buy: quote in");
        assertEq(_bal(quote, address(core)) - core0, uint128(BUY), "buy: core receives");
        assertEq(payer0 - _bal(quote, PAYER), uint128(BUY), "buy: payer pays");
        _assertRouterHoldsNothing(quote, o.key);
    }

    function _routerSell(Obs memory o, address quote) internal {
        uint128 amount = uint128(-_tokenDelta(o, o.buy)) / 2;
        uint256 core0 = _bal(quote, address(core));
        uint256 recipient0 = _bal(quote, RECIPIENT);
        vm.prank(PAYER);
        o.sell = launchRouter.swap(
            o.key, createSwapParameters(SqrtRatio.wrap(0), int128(amount), o.quoteIs0, 0), 1, RECIPIENT, block.timestamp
        );
        uint128 out = uint128(-_quoteDelta(o, o.sell));
        assertGt(out, 0);
        assertEq(core0 - _bal(quote, address(core)), out, "sell: core pays");
        assertEq(_bal(quote, RECIPIENT) - recipient0, out, "sell: recipient receives");
        _assertRouterHoldsNothing(quote, o.key);
    }

    function _claim(Obs memory o, address quote) internal {
        (uint128 f0, uint128 f1) = _fees(o.key);
        (o.feeQuote, o.feeToken) = o.quoteIs0 ? (f0, f1) : (f1, f0);
        assertGt(o.feeQuote, 0, "sell fee is in quote");
        uint256 owner0 = _bal(quote, OWNER);
        vm.prank(OWNER);
        extension.claimFees(o.key, OWNER);
        assertEq(_bal(quote, OWNER) - owner0, o.feeQuote, "claim: owner receives quote fees");
        (f0, f1) = _fees(o.key);
        assertEq(f0 + f1, 0, "claim: ledger cleared");
    }

    function _routerFund(Obs memory o, address quote) internal {
        uint256 core0 = _bal(quote, address(core));
        PoolId launchId = o.key.toPoolId();
        (uint128 v0, uint128 v1) = _balances(address(vault), o.key, PoolId.unwrap(launchId));
        vm.prank(PAYER);
        launchRouter.fund(launchId, o.quoteIs0 ? FUND : 0, o.quoteIs0 ? 0 : FUND, block.timestamp);
        (o.vaultReserve0, o.vaultReserve1) = _balances(address(vault), o.key, PoolId.unwrap(launchId));
        assertEq(o.quoteIs0 ? o.vaultReserve0 - v0 : o.vaultReserve1 - v1, FUND, "fund: principal ledger");
        assertEq(o.quoteIs0 ? o.vaultReserve1 : o.vaultReserve0, o.quoteIs0 ? v1 : v0, "fund: other side");
        assertEq(_bal(quote, address(core)) - core0, FUND, "fund: core receives");
        _assertRouterHoldsNothing(quote, o.key);
    }

    function _snapshotPrincipal(Obs memory o) internal view {
        (uint128 r0, uint128 r1) = _balances(address(extension), o.key, PoolId.unwrap(o.key.toPoolId()));
        (o.principalQuote, o.principalToken) = o.quoteIs0 ? (r0, r1) : (r1, r0);
    }

    function _finishObs(Obs memory o, address quote) internal {
        o.lockedLiquidity = _locked(o.key);
        o.coreQuote = _bal(quote, address(core));
        o.payerQuote = _bal(quote, PAYER);
        o.recipientQuote = _bal(quote, RECIPIENT);
        o.ownerQuote = _bal(quote, OWNER);
    }

    /// create -> buy -> sell -> claim creator fees -> migrate at endTime -> fund locked principal.
    function _flow(address quote) internal returns (Obs memory o) {
        o = _routerCreateQuote(quote, CREATE_QUOTE);
        vm.warp(START + 100);
        _routerBuy(o, quote);
        _routerSell(o, quote);
        _snapshotPrincipal(o);
        _claim(o, quote);
        _finish(o.key);
        _routerFund(o, quote);
        _finishObs(o, quote);
    }

    function _assertSame(Obs memory a, Obs memory b) internal pure {
        assertEq(a.quoteIs0, b.quoteIs0, "ordering");
        assertEq(PoolBalanceUpdate.unwrap(a.buy), PoolBalanceUpdate.unwrap(b.buy), "buy update");
        assertEq(PoolBalanceUpdate.unwrap(a.sell), PoolBalanceUpdate.unwrap(b.sell), "sell update");
        assertEq(a.principalQuote, b.principalQuote, "principal quote");
        assertEq(a.principalToken, b.principalToken, "principal token");
        assertEq(a.feeQuote, b.feeQuote, "creator fee quote");
        assertEq(a.feeToken, b.feeToken, "creator fee token");
        assertEq(a.lockedLiquidity, b.lockedLiquidity, "locked liquidity");
        assertEq(a.vaultReserve0, b.vaultReserve0, "vault reserve0");
        assertEq(a.vaultReserve1, b.vaultReserve1, "vault reserve1");
        assertEq(a.coreQuote, b.coreQuote, "core quote balance");
        assertEq(a.payerQuote, b.payerQuote, "payer quote");
        assertEq(a.recipientQuote, b.recipientQuote, "recipient quote");
        assertEq(a.ownerQuote, b.ownerQuote, "owner quote");
    }

    function _control(bool low) internal returns (Obs memory o) {
        uint256 snapshot = vm.snapshotState();
        o = _flow(_deployQuote("StandardQuote", low));
        vm.revertToState(snapshot);
    }

    function _debtsNotZeroed() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IFlashAccountant.DebtsNotZeroed.selector, 0);
    }

    // ---------------------------------------------------------------------------------------------
    // Supported: standard and missing return value account exactly.
    // ---------------------------------------------------------------------------------------------

    function test_standardQuoteFlowBothOrderings() public {
        for (uint256 i; i < 2; i++) {
            Obs memory o = _control(i == 0);
            assertEq(o.quoteIs0, i == 0);
            assertGt(o.lockedLiquidity, 0);
        }
    }

    function test_missingReturnValueAccountsExactly() public {
        for (uint256 i; i < 2; i++) {
            Obs memory control = _control(i == 0);
            uint256 snapshot = vm.snapshotState();
            _assertSame(_flow(_deployQuote("MissingReturnQuote", i == 0)), control);
            vm.revertToState(snapshot);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Fee-on-transfer: Core credits only what arrives, so every inbound payment leaves debt and reverts.
    // ---------------------------------------------------------------------------------------------

    function test_feeOnTransferRevertsCreateSwapAndFund() public {
        for (uint256 i; i < 2; i++) {
            uint256 snapshot = vm.snapshotState();
            address quote = _deployQuote("FeeOnTransferQuote", i == 0);
            uint256 payer0 = _bal(quote, PAYER);

            ScheduledLaunch.LaunchConfig memory config = _config(quote);
            config.owner = OWNER;
            config.quoteAmount = CREATE_QUOTE;
            vm.prank(PAYER);
            vm.expectRevert(_debtsNotZeroed());
            launchRouter.create(config, block.timestamp);

            // Without a quote deposit the launch exists, but no quote can ever enter it.
            Obs memory o = _routerCreateQuote(quote, 0);
            vm.warp(START + 100);
            vm.prank(PAYER);
            vm.expectRevert(_debtsNotZeroed());
            launchRouter.swap(o.key, _buyParamsFor(o, BUY), 1, PAYER, block.timestamp);

            // Exact output names the launch token amount; the fee-inclusive quote input still arrives short.
            vm.prank(PAYER);
            vm.expectRevert(_debtsNotZeroed());
            launchRouter.swap(
                o.key,
                createSwapParameters(SqrtRatio.wrap(0), -100e18, o.quoteIs0, 0),
                type(int256).min + 1,
                PAYER,
                block.timestamp
            );

            _finish(o.key);
            // The terminal registration exists after the first advance at endTime, so fund reaches payment.
            vm.prank(PAYER);
            vm.expectRevert(_debtsNotZeroed());
            launchRouter.fund(o.key.toPoolId(), o.quoteIs0 ? FUND : 0, o.quoteIs0 ? 0 : FUND, block.timestamp);

            assertEq(_bal(quote, PAYER), payer0, "payer unchanged");
            assertEq(_bal(quote, address(core)), 0, "core holds no quote");
            (uint128 r0, uint128 r1) = _balances(address(vault), o.key, PoolId.unwrap(o.key.toPoolId()));
            assertEq(o.quoteIs0 ? r0 : r1, 0, "no quote principal recorded");
            (uint128 f0, uint128 f1) = _fees(o.key);
            assertEq(f0 + f1, 0, "no creator fees");
            _assertRouterHoldsNothing(quote, o.key);
            vm.revertToState(snapshot);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Rebasing: exact while the index is constant; a rebase changes Core's balance under fixed ledgers.
    // ---------------------------------------------------------------------------------------------

    function test_rebasingWithoutRebaseAccountsExactly() public {
        for (uint256 i; i < 2; i++) {
            Obs memory control = _control(i == 0);
            uint256 snapshot = vm.snapshotState();
            _assertSame(_flow(_deployQuote("RebasingQuote", i == 0)), control);
            vm.revertToState(snapshot);
        }
    }

    /// A 50% negative rebase while quote sits in Core. Every ledger matches the control, so the launch
    /// still records the same principal, but Core holds less quote than it owes. The shortfall falls on
    /// whoever withdraws last from Core in that token; locked principal never withdraws, so it is unbacked.
    function test_rebasingDownLeavesPrincipalUnbacked() public {
        for (uint256 i; i < 2; i++) {
            Obs memory control = _control(i == 0);
            uint256 snapshot = vm.snapshotState();
            address quote = _deployQuote("RebasingQuote", i == 0);
            Obs memory o = _routerCreateQuote(quote, CREATE_QUOTE);
            vm.warp(START + 100);
            _routerBuy(o, quote);
            uint256 coreBefore = _bal(quote, address(core));
            // Halving keeps every later transfer exact in this mock, isolating the rebase itself.
            RebasingQuote(quote).setIndex(0.5e18);
            uint256 shortfall = coreBefore - _bal(quote, address(core));
            assertEq(shortfall, coreBefore - coreBefore / 2);
            _routerSell(o, quote);
            _snapshotPrincipal(o);
            _claim(o, quote);
            _finish(o.key);
            _routerFund(o, quote);
            _finishObs(o, quote);

            // Ledgers are nominal and identical to the control.
            assertEq(PoolBalanceUpdate.unwrap(o.sell), PoolBalanceUpdate.unwrap(control.sell), "sell update");
            assertEq(o.principalQuote, control.principalQuote, "principal quote ledger");
            assertEq(o.feeQuote, control.feeQuote, "creator fee ledger");
            assertEq(o.lockedLiquidity, control.lockedLiquidity, "locked liquidity");
            assertEq(o.vaultReserve0, control.vaultReserve0, "vault reserve0");
            assertEq(o.vaultReserve1, control.vaultReserve1, "vault reserve1");
            // Core's quote balance after every withdrawal is short by the rebase loss.
            assertEq(o.coreQuote + shortfall, control.coreQuote, "core balance short by the rebase");
            vm.revertToState(snapshot);
        }
    }

    /// A positive rebase strands unowned surplus in Core; no ledger records it or can withdraw it.
    function test_rebasingUpStrandsSurplus() public {
        for (uint256 i; i < 2; i++) {
            Obs memory control = _control(i == 0);
            uint256 snapshot = vm.snapshotState();
            address quote = _deployQuote("RebasingQuote", i == 0);
            Obs memory o = _flow(quote);
            _assertSame(o, control);
            RebasingQuote(quote).setIndex(1.5e18);
            uint256 surplus = _bal(quote, address(core)) - o.coreQuote;
            assertEq(surplus, o.coreQuote / 2);
            (uint128 v0, uint128 v1) = _balances(address(vault), o.key, PoolId.unwrap(o.key.toPoolId()));
            assertEq(v0, o.vaultReserve0, "vault reserve0 nominal");
            assertEq(v1, o.vaultReserve1, "vault reserve1 nominal");
            assertEq(_locked(o.key), o.lockedLiquidity, "locked liquidity nominal");
            vm.revertToState(snapshot);
        }
    }

    /// At a non-unit index, transfers move whole shares, so Core can be credited less than the amount.
    /// Each such payment reverts with DebtsNotZeroed; otherwise the payment is exact.
    function testFuzz_rebasingShareRoundingRevertsOrExact(uint96 amount, bool low) public {
        _roundingBuy(_roundingLaunch(low), uint128(bound(amount, 1, 10_000e18)));
    }

    /// Both outcomes occur for consecutive amounts, so the property above is not vacuous.
    function test_rebasingShareRoundingHitsBothOutcomes() public {
        Obs memory o = _roundingLaunch(true);
        uint256 reverted;
        for (uint128 amount = 1e18; amount < 1e18 + 20; amount++) {
            if (_roundingBuy(o, amount)) reverted++;
        }
        assertGt(reverted, 0, "some payments credited short");
        assertLt(reverted, 20, "some payments exact");
    }

    function _roundingLaunch(bool low) internal returns (Obs memory o) {
        address quote = _deployQuote("RebasingQuote", low);
        RebasingQuote(quote).setIndex(1.1e18);
        // Core already holds a share balance, so rounding depends on both sides.
        RebasingQuote(quote).mint(address(core), 1e18 + 7);
        (o.key,) = _routerCreate(quote, 0, 0);
        o.quoteIs0 = o.key.token0 == quote;
        vm.warp(START + 100);
    }

    function _roundingBuy(Obs memory o, uint128 amount) internal returns (bool reverted) {
        address quote = o.quoteIs0 ? o.key.token0 : o.key.token1;
        uint256 core0 = _bal(quote, address(core));
        vm.prank(PAYER);
        try launchRouter.swap(
            o.key, _buyParamsFor(o, int128(amount)), type(int256).min + 1, PAYER, block.timestamp
        ) returns (
            PoolBalanceUpdate update
        ) {
            assertEq(_bal(quote, address(core)) - core0, uint128(_quoteDelta(o, update)), "credited exactly");
        } catch (bytes memory err) {
            assertEq(err, _debtsNotZeroed(), "only a short credit reverts");
            assertEq(_bal(quote, address(core)), core0);
            reverted = true;
        }
        _assertRouterHoldsNothing(quote, o.key);
    }

    // ---------------------------------------------------------------------------------------------
    // Reentrant hooks.
    // ---------------------------------------------------------------------------------------------

    function _hookSetup(bool low) internal returns (HookQuote quote, ReentrantTrader trader, Obs memory o) {
        quote = HookQuote(_deployQuote("HookQuote", low));
        trader = new ReentrantTrader(launchRouter, quote);
        quote.mint(address(trader), 1_000_000e18);
        o = _routerCreateQuote(address(quote), CREATE_QUOTE);
        trader.approveToken(o.quoteIs0 ? o.key.token1 : o.key.token0);
        vm.warp(START + 100);
    }

    /// A sender hook that reenters with a payment in the same token overwrites the outer payment window,
    /// so the outer lock is credited nothing and reverts. Create and swap as the outer call.
    function test_reentrantSenderHookRevertsCreateAndSwap() public {
        for (uint256 i; i < 2; i++) {
            uint256 snapshot = vm.snapshotState();
            (HookQuote quote, ReentrantTrader trader, Obs memory o) = _hookSetup(i == 0);
            uint256 trader0 = quote.balanceOf(address(trader));
            uint256 core0 = quote.balanceOf(address(core));
            SwapParameters nestedBuy = _buyParamsFor(o, 10e18);

            ScheduledLaunch.LaunchConfig memory config = _config(address(quote));
            config.startTime = uint64(vm.getBlockTimestamp() + 1);
            config.endTime = uint64(vm.getBlockTimestamp() + 1000);
            config.quoteAmount = CREATE_QUOTE;
            trader.arm(o.key, nestedBuy, true, false);
            vm.expectRevert(_debtsNotZeroed());
            trader.create(config);

            trader.arm(o.key, nestedBuy, true, false);
            vm.expectRevert(_debtsNotZeroed());
            trader.swap(o.key, _buyParamsFor(o, BUY), address(trader));

            assertEq(quote.balanceOf(address(trader)), trader0, "trader unchanged");
            assertEq(quote.balanceOf(address(core)), core0, "core unchanged");
            _assertRouterHoldsNothing(address(quote), o.key);
            vm.revertToState(snapshot);
        }
    }

    /// Fund as the outer call: the sender hook funds again in the same token and the outer is credited nothing.
    function test_reentrantSenderHookNestedFundReverts() public {
        for (uint256 i; i < 2; i++) {
            uint256 snapshot = vm.snapshotState();
            (HookQuote quote,, Obs memory o) = _hookSetup(i == 0);
            _finish(o.key);
            uint256 core0 = quote.balanceOf(address(core));
            (uint128 v0, uint128 v1) = _balances(address(vault), o.key, PoolId.unwrap(o.key.toPoolId()));
            NestedFunder funder = new NestedFunder(launchRouter, quote, o.key.toPoolId(), o.quoteIs0);
            quote.mint(address(funder), 1_000e18);
            vm.expectRevert(_debtsNotZeroed());
            funder.fund(FUND);
            (uint128 w0, uint128 w1) = _balances(address(vault), o.key, PoolId.unwrap(o.key.toPoolId()));
            assertEq(w0, v0);
            assertEq(w1, v1);
            assertEq(quote.balanceOf(address(core)), core0);
            assertEq(quote.balanceOf(address(funder)), 1_000e18);
            _assertRouterHoldsNothing(address(quote), o.key);
            vm.revertToState(snapshot);
        }
    }

    /// A recipient hook that reenters with a buy while Core pays out a sell. Core debits before the
    /// transfer, so the nested trade settles in its own lock and the result equals sell-then-buy.
    function test_reentrantRecipientHookMatchesSequentialTrades() public {
        for (uint256 i; i < 2; i++) {
            uint256 snapshot = vm.snapshotState();
            (HookQuote quote, ReentrantTrader trader, Obs memory o) = _hookSetup(i == 0);
            _routerBuy(o, address(quote));
            uint128 amount = uint128(-_tokenDelta(o, o.buy)) / 2;
            SwapParameters sell = createSwapParameters(SqrtRatio.wrap(0), int128(amount), o.quoteIs0, 0);
            SwapParameters nestedBuy = _buyParamsFor(o, 10e18);

            // Sequential control.
            uint256 control = vm.snapshotState();
            vm.prank(PAYER);
            PoolBalanceUpdate sellA = launchRouter.swap(o.key, sell, 1, address(trader), block.timestamp);
            PoolBalanceUpdate buyA = trader.swap(o.key, nestedBuy, address(trader));
            bytes memory stateA = _ledgerState(o, address(quote), address(trader));
            vm.revertToState(control);

            // Reentrant run.
            trader.arm(o.key, nestedBuy, false, true);
            vm.prank(PAYER);
            PoolBalanceUpdate sellB = launchRouter.swap(o.key, sell, 1, address(trader), block.timestamp);
            assertEq(PoolBalanceUpdate.unwrap(sellB), PoolBalanceUpdate.unwrap(sellA), "outer sell");
            assertEq(PoolBalanceUpdate.unwrap(trader.nested()), PoolBalanceUpdate.unwrap(buyA), "nested buy");
            assertEq(_ledgerState(o, address(quote), address(trader)), stateA, "ledgers equal sequential");
            _assertRouterHoldsNothing(address(quote), o.key);
            vm.revertToState(snapshot);
        }
    }

    function _ledgerState(Obs memory o, address quote, address trader) internal view returns (bytes memory) {
        PoolId id = o.key.toPoolId();
        (uint128 r0, uint128 r1) = _balances(address(extension), o.key, PoolId.unwrap(id));
        (uint128 f0, uint128 f1) = _fees(o.key);
        address token = o.quoteIs0 ? o.key.token1 : o.key.token0;
        return abi.encode(
            r0,
            r1,
            f0,
            f1,
            core.poolState(id),
            extension.getLaunch(id).deployed,
            _bal(quote, address(core)),
            _bal(quote, trader),
            _bal(quote, PAYER),
            MintableERC20(token).balanceOf(trader),
            MintableERC20(token).balanceOf(PAYER),
            MintableERC20(token).balanceOf(address(core))
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Revert on transfer and false return: every call fails closed with ledgers untouched, and the
    // launch resumes exactly once transfers work again.
    // ---------------------------------------------------------------------------------------------

    function _assertFrozenFailsClosed(string memory name, bytes memory payErr, bool low) internal {
        Obs memory control = _control(low);
        uint256 snapshot = vm.snapshotState();
        address quote = _deployQuote(name, low);
        Obs memory o = _routerCreateQuote(quote, CREATE_QUOTE);
        vm.warp(START + 100);
        _routerBuy(o, quote);
        MockQuoteBase(quote).setFrozen(true);
        bytes memory before = _ledgerState(o, quote, RECIPIENT);

        ScheduledLaunch.LaunchConfig memory config = _config(quote);
        config.startTime = uint64(vm.getBlockTimestamp() + 1);
        config.endTime = uint64(vm.getBlockTimestamp() + 1000);
        config.quoteAmount = CREATE_QUOTE;
        vm.prank(PAYER);
        vm.expectRevert(payErr);
        launchRouter.create(config, block.timestamp);

        vm.prank(PAYER);
        vm.expectRevert(payErr);
        launchRouter.swap(o.key, _buyParamsFor(o, BUY), 1, PAYER, block.timestamp);

        uint128 amount = uint128(-_tokenDelta(o, o.buy)) / 2;
        vm.prank(PAYER);
        vm.expectRevert(abi.encodeWithSignature("TransferFailed()"));
        launchRouter.swap(
            o.key, createSwapParameters(SqrtRatio.wrap(0), int128(amount), o.quoteIs0, 0), 1, RECIPIENT, block.timestamp
        );
        assertEq(_ledgerState(o, quote, RECIPIENT), before, "ledgers untouched while frozen");

        MockQuoteBase(quote).setFrozen(false);
        _routerSell(o, quote);
        _snapshotPrincipal(o);
        MockQuoteBase(quote).setFrozen(true);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSignature("TransferFailed()"));
        extension.claimFees(o.key, OWNER);
        // Migration moves no tokens, so it completes while frozen.
        _finish(o.key);
        vm.prank(PAYER);
        vm.expectRevert(payErr);
        launchRouter.fund(o.key.toPoolId(), o.quoteIs0 ? FUND : 0, o.quoteIs0 ? 0 : FUND, block.timestamp);
        _assertRouterHoldsNothing(quote, o.key);

        MockQuoteBase(quote).setFrozen(false);
        _claim(o, quote);
        _routerFund(o, quote);
        _finishObs(o, quote);
        // Claiming after migration instead of before leaves every figure the control reports unchanged.
        _assertSame(o, control);
        vm.revertToState(snapshot);
    }

    function test_revertingTransferFailsClosedAndResumesExactly() public {
        for (uint256 i; i < 2; i++) {
            _assertFrozenFailsClosed("RevertingQuote", abi.encodeWithSignature("TransferFromFailed()"), i == 0);
        }
    }

    function test_falseReturnFailsClosedAndResumesExactly() public {
        for (uint256 i; i < 2; i++) {
            _assertFrozenFailsClosed("ReturnsFalseQuote", abi.encodeWithSignature("TransferFromFailed()"), i == 0);
        }
    }

    /// A false return for missing allowance is treated as failure even though the call succeeded.
    function test_falseReturnOnMissingAllowanceReverts() public {
        address quote = _deployQuote("ReturnsFalseQuote", true);
        vm.prank(PAYER);
        MockQuoteBase(quote).approve(address(launchRouter), 0);
        ScheduledLaunch.LaunchConfig memory config = _config(quote);
        config.owner = OWNER;
        config.quoteAmount = CREATE_QUOTE;
        vm.prank(PAYER);
        vm.expectRevert(abi.encodeWithSignature("TransferFromFailed()"));
        launchRouter.create(config, block.timestamp);
        assertEq(_bal(quote, address(core)), 0);
    }
}

/// @dev Funds a launch through the router; its sender hook funds again in the same token.
contract NestedFunder is IQuoteHooks {
    LaunchRouter immutable ROUTER;
    HookQuote immutable QUOTE;
    PoolId immutable LAUNCH;
    bool immutable QUOTE_IS_0;
    bool armed;

    constructor(LaunchRouter router, HookQuote quote, PoolId launchId, bool quoteIs0) {
        ROUTER = router;
        QUOTE = quote;
        LAUNCH = launchId;
        QUOTE_IS_0 = quoteIs0;
        quote.approve(address(router), type(uint256).max);
        quote.register(true);
    }

    function fund(uint128 amount) external {
        armed = true;
        ROUTER.fund(LAUNCH, QUOTE_IS_0 ? amount : 0, QUOTE_IS_0 ? 0 : amount, block.timestamp);
    }

    function tokensToSend(address, address, uint256) external {
        if (!armed || msg.sender != address(QUOTE)) return;
        armed = false;
        ROUTER.fund(LAUNCH, QUOTE_IS_0 ? 1e18 : 0, QUOTE_IS_0 ? 0 : 1e18, block.timestamp);
    }

    function tokensReceived(address, address, uint256) external {}
}
