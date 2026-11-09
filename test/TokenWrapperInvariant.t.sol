// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Core} from "../src/Core.sol";
import {TokenWrapper} from "../src/TokenWrapper.sol";
import {TokenWrapperFactory} from "../src/TokenWrapperFactory.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {TestToken} from "./TestToken.sol";
import {TokenWrapperPeriphery} from "./TokenWrapper.t.sol";

contract TokenWrapperInvariantHandler is StdAssertions {
    Vm private immutable vm;
    Core private immutable core;
    TestToken private immutable underlying;
    TokenWrapperPeriphery private immutable periphery;
    TokenWrapper[2] private wrappers;
    address[3] private holders;

    // A cash-flow ledger: no Core storage, transient payment balance or signed debt is modeled.
    uint256[3] private cash;
    uint256[3][2] private claims;
    uint256[4][3][2] private approvals;
    uint256[2] private deposits;
    uint256[2] private redemptions;
    uint256 private constant INITIAL_CASH = type(uint96).max;

    constructor(Vm _vm) {
        vm = _vm;
        core = new Core();
        underlying = new TestToken(address(this));
        periphery = new TokenWrapperPeriphery(core);
        TokenWrapperFactory factory = new TokenWrapperFactory(core);
        for (uint256 w; w < wrappers.length; w++) {
            wrappers[w] = factory.deployWrapper(IERC20(address(underlying)), block.timestamp + 10 * (w + 1));
        }
        for (uint256 h; h < holders.length; h++) {
            holders[h] = address(uint160(0x1000 + h));
            cash[h] = INITIAL_CASH;
            underlying.transfer(holders[h], INITIAL_CASH);
            vm.prank(holders[h]);
            underlying.approve(address(periphery), type(uint256).max);
        }
    }

    function wrap(uint256 w, uint256 payer, uint256 recipient, uint96 rawAmount) external {
        w %= 2;
        payer %= 3;
        recipient %= 3;
        uint128 amount = uint128(uint256(rawAmount) % (cash[payer] + 1));
        vm.prank(holders[payer]);
        periphery.wrap(wrappers[w], holders[recipient], amount);
        cash[payer] -= amount;
        claims[w][recipient] += amount;
        deposits[w] += amount;
    }

    function transfer(uint256 w, uint256 from, uint256 to, uint96 rawAmount, bool overdraw) external {
        w %= 2;
        from %= 3;
        to %= 3;
        uint256 amount = overdraw ? claims[w][from] + 1 : uint256(rawAmount) % (claims[w][from] + 1);
        vm.prank(holders[from]);
        if (overdraw) vm.expectRevert(TokenWrapper.InsufficientBalance.selector);
        wrappers[w].transfer(holders[to], amount);
        if (!overdraw) {
            claims[w][from] -= amount;
            claims[w][to] += amount;
        }
    }

    function approve(uint256 w, uint256 holder, uint256 spender, uint96 amount, bool unlimited) external {
        w %= 2;
        holder %= 3;
        spender %= 4;
        uint256 value = unlimited ? type(uint256).max : amount;
        vm.prank(holders[holder]);
        wrappers[w].approve(_spender(spender), value);
        approvals[w][holder][spender] = value;
    }

    function transferFrom(uint256 w, uint256 from, uint256 to, uint256 spender, uint96 rawAmount, bool overdraw)
        external
    {
        w %= 2;
        from %= 3;
        to %= 3;
        spender %= 3;
        uint256 amount = overdraw ? claims[w][from] + 1 : uint256(rawAmount) % (claims[w][from] + 1);
        bool insufficientAllowance = approvals[w][from][spender] < amount;
        vm.prank(holders[spender]);
        if (insufficientAllowance) vm.expectRevert(TokenWrapper.InsufficientAllowance.selector);
        else if (overdraw) vm.expectRevert(TokenWrapper.InsufficientBalance.selector);
        wrappers[w].transferFrom(holders[from], holders[to], amount);
        if (!insufficientAllowance && !overdraw) {
            _spend(w, from, spender, amount);
            claims[w][from] -= amount;
            claims[w][to] += amount;
        }
    }

    function unwrap(uint256 w, uint256 holder, uint256 recipient, uint96 rawAmount) external {
        w %= 2;
        holder %= 3;
        recipient %= 3;
        uint128 amount = uint128(uint256(rawAmount) % (claims[w][holder] + 1));
        bool tooEarly = amount != 0 && vm.getBlockTimestamp() < wrappers[w].UNLOCK_TIME();
        bool insufficientAllowance = approvals[w][holder][3] < amount;
        vm.prank(holders[holder]);
        if (tooEarly) vm.expectRevert(TokenWrapper.TooEarly.selector);
        else if (insufficientAllowance) vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        periphery.unwrap(wrappers[w], holders[recipient], amount);
        if (!tooEarly && !insufficientAllowance) {
            _spend(w, holder, 3, amount);
            claims[w][holder] -= amount;
            cash[recipient] += amount;
            redemptions[w] += amount;
        }
    }

    function advanceTime(uint256 delta) external {
        vm.warp(vm.getBlockTimestamp() + delta % 11);
    }

    function checkAccounting() external view {
        uint256 backing;
        uint256 circulatingCash;
        for (uint256 w; w < wrappers.length; w++) {
            uint256 circulatingClaims;
            for (uint256 h; h < holders.length; h++) {
                assertEq(wrappers[w].balanceOf(holders[h]), claims[w][h], "holder claims");
                circulatingClaims += claims[w][h];
                for (uint256 s; s < 4; s++) {
                    assertEq(wrappers[w].allowance(holders[h], _spender(s)), approvals[w][h][s], "allowance");
                }
            }
            assertEq(circulatingClaims, deposits[w] - redemptions[w], "claim conservation");
            assertEq(wrappers[w].totalSupply(), circulatingClaims, "wrapper backing");
            backing += circulatingClaims;
        }
        for (uint256 h; h < holders.length; h++) {
            assertEq(underlying.balanceOf(holders[h]), cash[h], "holder cash");
            circulatingCash += cash[h];
        }
        // Only these holders and two wrappers use this Core; there are no burns, donations or pools.
        // Core's synthetic wrapper balance is deliberately excluded: it is a payment counter, not supply.
        assertEq(underlying.balanceOf(address(core)), backing, "shared underlying backing");
        assertEq(circulatingCash + backing, 3 * INITIAL_CASH, "cash conservation");
    }

    function _spender(uint256 index) private view returns (address) {
        return index == 3 ? address(periphery) : holders[index];
    }

    function _spend(uint256 w, uint256 holder, uint256 spender, uint256 amount) private {
        if (approvals[w][holder][spender] != type(uint256).max) approvals[w][holder][spender] -= amount;
    }
}

contract TokenWrapperInvariantTest is Test {
    TokenWrapperInvariantHandler private handler;

    function setUp() public {
        vm.warp(1);
        handler = new TokenWrapperInvariantHandler(vm);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.wrap.selector;
        selectors[1] = handler.transfer.selector;
        selectors[2] = handler.approve.selector;
        selectors[3] = handler.transferFrom.selector;
        selectors[4] = handler.unwrap.selector;
        selectors[5] = handler.advanceTime.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: ci.invariant.runs = 64
    /// forge-config: ci.invariant.depth = 64
    function invariant_claimsAndBackingMatchCashFlows() public view {
        handler.checkAccounting();
    }

    function test_transfersAllowancesAndMaturities() public {
        handler.wrap(0, 0, 0, 100);
        handler.wrap(1, 1, 0, 50);
        handler.transfer(0, 0, 1, 30, false);
        handler.transfer(0, 1, 1, 10, false); // Self-transfer must conserve the holder's claim.
        handler.approve(0, 1, 2, 20, false);
        handler.transferFrom(0, 1, 0, 2, 7, false);
        handler.checkAccounting();
        handler.transferFrom(0, 1, 0, 2, 14, false); // Remaining allowance is only 13.
        handler.approve(0, 1, 2, 100, false);
        handler.transferFrom(0, 1, 0, 2, 0, true); // Balance failure must roll back allowance spending.
        handler.checkAccounting();
        handler.approve(0, 1, 2, 0, true);
        handler.transferFrom(0, 1, 1, 2, 5, false); // Infinite allowance and self-transfer.
        handler.approve(0, 0, 3, 77, false);
        handler.unwrap(0, 0, 2, 77); // Still locked.
        handler.checkAccounting();
        handler.advanceTime(10); // Exactly the first maturity.
        handler.unwrap(0, 0, 2, 77);
        handler.approve(1, 0, 3, 0, true);
        handler.unwrap(1, 0, 2, 50); // The second wrapper is still locked.
        handler.checkAccounting();
        handler.advanceTime(10);
        handler.unwrap(1, 0, 2, 50);
        handler.approve(0, 1, 3, 0, true);
        handler.unwrap(0, 1, 0, 23);
        handler.wrap(0, 2, 1, 1); // Re-fund a fully redeemed, already-mature wrapper.
        handler.unwrap(0, 1, 2, 1);
        handler.checkAccounting();
    }
}
