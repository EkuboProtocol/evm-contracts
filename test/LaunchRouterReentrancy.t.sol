// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

// Nested LaunchRouter calls from an output recipient or a quote-token callback (EKU-723). Native payments
// and the refund use the router's whole balance, so a nested call must never run inside an outer one.
// Each case sends native surplus with the outer call and attempts every nested entrypoint with zero amounts,
// which before the guard refunded the outer payer's surplus to the attacker.

import {LaunchRouterTest} from "./LaunchRouter.t.sol";
import {StandardQuote} from "./LaunchRouterQuoteTokens.t.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";
import {ScheduledLaunch} from "../src/extensions/ScheduledLaunch.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {SwapParameters, createSwapParameters} from "../src/types/swapParameters.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";

/// @dev Attempts one nested router call when triggered and records the outcome instead of reverting.
abstract contract NestedRouterCaller {
    uint8 constant NONE = 0;
    uint8 constant CREATE = 1;
    uint8 constant SWAP = 2;
    uint8 constant FUND = 3;

    LaunchRouter immutable ROUTER;
    uint8 kind;
    PoolKey swapKey;
    PoolId fundId;
    bool public attempted;
    bool public nestedSucceeded;
    bytes public nestedError;

    constructor(LaunchRouter router) {
        ROUTER = router;
    }

    function arm(uint8 kind_, PoolKey memory swapKey_, PoolId fundId_) external {
        kind = kind_;
        swapKey = swapKey_;
        fundId = fundId_;
        attempted = false;
        nestedSucceeded = false;
        nestedError = "";
    }

    function _reenter() internal {
        uint8 k = kind;
        if (k == NONE) return;
        kind = NONE;
        attempted = true;
        if (k == CREATE) {
            try ROUTER.create(_nestedConfig(), block.timestamp) {
                nestedSucceeded = true;
            } catch (bytes memory err) {
                nestedError = err;
            }
        } else if (k == SWAP) {
            try ROUTER.swap(
                swapKey, createSwapParameters(SqrtRatio.wrap(0), 0, true, 0), 0, address(this), block.timestamp
            ) {
                nestedSucceeded = true;
            } catch (bytes memory err) {
                nestedError = err;
            }
        } else {
            try ROUTER.fund(fundId, 0, 0, block.timestamp) {
                nestedSucceeded = true;
            } catch (bytes memory err) {
                nestedError = err;
            }
        }
    }

    function _nestedConfig() private view returns (ScheduledLaunch.LaunchConfig memory) {
        return ScheduledLaunch.LaunchConfig({
            owner: address(this),
            quoteToken: address(0),
            name: "Nested",
            symbol: "NEST",
            decimals: 18,
            totalSupply: 1e18,
            quoteAmount: 0,
            startTime: uint64(block.timestamp),
            endTime: uint64(block.timestamp + 1000),
            targetTick: 0,
            upperTick: 100_000,
            tickSpacing: 100,
            initialFee: 0,
            finalFee: 0,
            migrationTickLower: -100_000,
            migrationTickUpper: 200_000
        });
    }
}

/// @dev Output recipient that reenters from its native receive hook.
contract ReentrantRecipient is NestedRouterCaller {
    constructor(LaunchRouter router) NestedRouterCaller(router) {}

    receive() external payable {
        _reenter();
    }
}

/// @dev Quote token that reenters on every transfer while armed, both when the payer pays and when Core
/// pays a recipient. It accepts native value so a successful theft would be observable.
contract ReentrantQuote is StandardQuote, NestedRouterCaller {
    constructor(LaunchRouter router) NestedRouterCaller(router) {}

    function _tryTransfer(address from, address to, uint256 amount) internal override returns (bool) {
        _reenter();
        return super._tryTransfer(from, to, amount);
    }

    receive() external payable {}
}

contract LaunchRouterReentrancyTest is LaunchRouterTest {
    using CoreLib for *;

    address constant QUOTE_LOW = address(0x20000);
    address constant QUOTE_HIGH = address(type(uint160).max - 0xffff);
    uint256 constant SURPLUS = 1 ether;
    uint128 constant CREATE_QUOTE = 7e18;
    int128 constant BUY = 1_000e18;
    uint128 constant FUND = 3e18;

    /// Nested targets: an active native launch for swap and a finished native launch for fund.
    PoolKey nativeKey;
    PoolId finishedId;

    function setUp() public override {
        super.setUp();
        ScheduledLaunch.LaunchConfig memory config = _config(address(0));
        config.owner = OWNER;
        config.startTime = uint64(block.timestamp);
        config.endTime = uint64(block.timestamp + 1);
        vm.prank(PAYER);
        (PoolKey memory finished,) = launchRouter.create(config, block.timestamp);
        finishedId = finished.toPoolId();
        (nativeKey,) = _routerCreate(address(0), 0, 0);
        vm.warp(block.timestamp + 1);
        extension.advance(finished);
        assertEq(vault.getTerminal(finishedId).owner, OWNER);
    }

    function _quote(bool low) internal returns (ReentrantQuote quote) {
        quote = ReentrantQuote(payable(low ? QUOTE_LOW : QUOTE_HIGH));
        deployCodeTo("LaunchRouterReentrancy.t.sol:ReentrantQuote", abi.encode(launchRouter), address(quote));
        quote.mint(PAYER, 1_000_000e18);
        vm.prank(PAYER);
        quote.approve(address(launchRouter), type(uint256).max);
    }

    function _assertBlocked(NestedRouterCaller attacker) internal view {
        assertTrue(attacker.attempted(), "reentry attempted");
        assertFalse(attacker.nestedSucceeded(), "nested call succeeded");
        assertEq(attacker.nestedError(), abi.encodeWithSelector(LaunchRouter.Reentrant.selector), "nested error");
    }

    function _assertNoNativeMoved(uint256 payerBefore, address attacker) internal view {
        assertEq(PAYER.balance, payerBefore, "payer loses only what it owes");
        assertEq(attacker.balance, 0, "attacker receives no native value");
        assertEq(address(launchRouter).balance, 0, "router ETH");
    }

    function _arm(NestedRouterCaller attacker, uint8 kind) internal {
        attacker.arm(kind, nativeKey, finishedId);
    }

    // ---------------------------------------------------------------------------------------------
    // Malicious output recipient.
    // ---------------------------------------------------------------------------------------------

    /// The CSO case: a native sell whose recipient reenters while the payer's surplus sits in the router.
    function test_recipientReentryCannotTakeSurplus() public {
        vm.warp(START + 100);
        vm.prank(PAYER);
        PoolBalanceUpdate bought =
            launchRouter.swap{value: 2 ether}(nativeKey, _buyParams(false, 2 ether), 1, PAYER, block.timestamp);
        SwapParameters sell = createSwapParameters(SqrtRatio.wrap(0), -bought.delta1() / 8, true, 0);
        for (uint8 kind = 1; kind <= 3; kind++) {
            ReentrantRecipient recipient = new ReentrantRecipient(launchRouter);
            _arm(recipient, kind);
            uint256 payerEth = PAYER.balance;
            uint256 payerToken = MintableERC20(nativeKey.token1).balanceOf(PAYER);
            vm.prank(PAYER);
            PoolBalanceUpdate sold =
                launchRouter.swap{value: SURPLUS}(nativeKey, sell, 1, address(recipient), block.timestamp);
            _assertBlocked(recipient);
            assertEq(address(recipient).balance, uint128(-sold.delta0()), "recipient gets only the output");
            assertEq(PAYER.balance, payerEth, "surplus refunded to payer");
            assertEq(MintableERC20(nativeKey.token1).balanceOf(PAYER), payerToken - uint128(sold.delta1()));
            _assertRouterEmpty(nativeKey);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Malicious quote token, both orderings, every outer entrypoint and every nested entrypoint.
    // ---------------------------------------------------------------------------------------------

    function test_quoteCallbackDuringCreateCannotTakeSurplus() public {
        for (uint256 i; i < 2; i++) {
            ReentrantQuote quote = _quote(i == 0);
            for (uint8 kind = 1; kind <= 3; kind++) {
                ScheduledLaunch.LaunchConfig memory config = _config(address(quote));
                config.owner = OWNER;
                config.quoteAmount = CREATE_QUOTE;
                config.startTime = uint64(block.timestamp);
                uint256 payerEth = PAYER.balance;
                uint256 payerQuote = quote.balanceOf(PAYER);
                _arm(quote, kind);
                vm.prank(PAYER);
                (PoolKey memory key,) = launchRouter.create{value: SURPLUS}(config, block.timestamp);
                _assertBlocked(quote);
                _assertNoNativeMoved(payerEth, address(quote));
                assertEq(payerQuote - quote.balanceOf(PAYER), CREATE_QUOTE, "payer pays quoteAmount");
                (uint128 r0, uint128 r1) = _balances(address(extension), key, PoolId.unwrap(key.toPoolId()));
                assertEq(key.token0 == address(quote) ? r0 : r1, CREATE_QUOTE, "principal");
            }
        }
    }

    function test_quoteCallbackDuringSwapCannotTakeSurplus() public {
        for (uint256 i; i < 2; i++) {
            uint256 snapshot = vm.snapshotState();
            ReentrantQuote quote = _quote(i == 0);
            (PoolKey memory key, address token) = _routerCreate(address(quote), 0, 0);
            bool quoteIs0 = key.token0 == address(quote);
            vm.warp(START + 100);
            for (uint8 kind = 1; kind <= 3; kind++) {
                // Buy: the callback runs while the payer pays the quote token.
                uint256 payerEth = PAYER.balance;
                uint256 payerQuote = quote.balanceOf(PAYER);
                uint256 recipientToken = MintableERC20(token).balanceOf(RECIPIENT);
                _arm(quote, kind);
                vm.prank(PAYER);
                PoolBalanceUpdate buy =
                    launchRouter.swap{value: SURPLUS}(key, _buyParams(!quoteIs0, BUY), 1, RECIPIENT, block.timestamp);
                _assertBlocked(quote);
                _assertNoNativeMoved(payerEth, address(quote));
                assertEq(payerQuote - quote.balanceOf(PAYER), uint128(BUY), "payer pays exact input");
                int128 tokenOut = quoteIs0 ? buy.delta1() : buy.delta0();
                assertEq(MintableERC20(token).balanceOf(RECIPIENT) - recipientToken, uint128(-tokenOut), "buy output");

                // Sell: the callback runs while Core pays the recipient.
                vm.prank(RECIPIENT);
                MintableERC20(token).transfer(PAYER, uint128(-tokenOut));
                uint256 recipientQuote = quote.balanceOf(RECIPIENT);
                _arm(quote, kind);
                vm.prank(PAYER);
                PoolBalanceUpdate sell = launchRouter.swap{value: SURPLUS}(
                    key,
                    createSwapParameters(SqrtRatio.wrap(0), -tokenOut / 2, quoteIs0, 0),
                    1,
                    RECIPIENT,
                    block.timestamp
                );
                _assertBlocked(quote);
                _assertNoNativeMoved(payerEth, address(quote));
                int128 quoteOut = quoteIs0 ? sell.delta0() : sell.delta1();
                assertEq(quote.balanceOf(RECIPIENT) - recipientQuote, uint128(-quoteOut), "sell output");
                assertEq(quote.balanceOf(address(launchRouter)), 0, "router quote");
                _assertRouterEmpty(key);
            }
            vm.revertToState(snapshot);
        }
    }

    function test_quoteCallbackDuringFundCannotTakeSurplus() public {
        for (uint256 i; i < 2; i++) {
            uint256 snapshot = vm.snapshotState();
            ReentrantQuote quote = _quote(i == 0);
            (PoolKey memory key,) = _routerCreate(address(quote), CREATE_QUOTE, 0);
            bool quoteIs0 = key.token0 == address(quote);
            _finish(key);
            for (uint8 kind = 1; kind <= 3; kind++) {
                uint256 payerEth = PAYER.balance;
                uint256 payerQuote = quote.balanceOf(PAYER);
                (uint128 v0, uint128 v1) = _balances(address(vault), key, PoolId.unwrap(key.toPoolId()));
                _arm(quote, kind);
                vm.prank(PAYER);
                launchRouter.fund{value: SURPLUS}(
                    key.toPoolId(), quoteIs0 ? FUND : 0, quoteIs0 ? 0 : FUND, block.timestamp
                );
                _assertBlocked(quote);
                _assertNoNativeMoved(payerEth, address(quote));
                assertEq(payerQuote - quote.balanceOf(PAYER), FUND, "payer pays the funded amount");
                (uint128 w0, uint128 w1) = _balances(address(vault), key, PoolId.unwrap(key.toPoolId()));
                assertEq(quoteIs0 ? w0 - v0 : w1 - v1, FUND, "principal funded");
                assertEq(quoteIs0 ? w1 : w0, quoteIs0 ? v1 : v0, "other side unchanged");
            }
            vm.revertToState(snapshot);
        }
    }

    /// The guard clears after each call, so sequential routed actions in one transaction still work.
    function test_sequentialCallsInOneTransactionSucceed() public {
        vm.warp(START + 100);
        SequentialCaller caller = new SequentialCaller(launchRouter);
        vm.deal(address(caller), 3 ether);
        caller.buyTwice(nativeKey, _buyParams(false, 1 ether));
        assertGt(MintableERC20(nativeKey.token1).balanceOf(address(caller)), 0);
        assertEq(address(caller).balance, 1 ether);
        _assertRouterEmpty(nativeKey);
    }
}

contract SequentialCaller {
    LaunchRouter immutable ROUTER;

    constructor(LaunchRouter router) {
        ROUTER = router;
    }

    function buyTwice(PoolKey memory key, SwapParameters params) external {
        ROUTER.swap{value: 1 ether}(key, params, 1, address(this), block.timestamp);
        ROUTER.swap{value: 1 ether}(key, params, 1, address(this), block.timestamp);
    }

    receive() external payable {}
}
