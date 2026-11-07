// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {Vm} from "forge-std/Vm.sol";
import {Incentives} from "../src/Incentives.sol";
import {IIncentives} from "../src/interfaces/IIncentives.sol";
import {IncentivesLib} from "../src/libraries/IncentivesLib.sol";
import {DropKey} from "../src/types/dropKey.sol";
import {ClaimKey} from "../src/types/claimKey.sol";
import {TestToken} from "./TestToken.sol";

contract IncentivesInvariantHandler is StdAssertions {
    using IncentivesLib for IIncentives;

    struct Model {
        uint256 deposits;
        uint256 refunds;
        uint256 paid;
        bool[4] claimed;
    }

    Vm private immutable vm;
    IIncentives private immutable incentives;
    TestToken private immutable token;
    DropKey[2] private keys;
    ClaimKey[4] private claims;
    bytes32[4] private leaves;
    Model[2] private models;

    constructor(Vm _vm) {
        vm = _vm;
        incentives = new Incentives();
        token = new TestToken(address(this));
        token.approve(address(incentives), type(uint256).max);

        // Include a zero claim, both sides of a bitmap-word boundary, and the largest index.
        uint256[4] memory indexes = [uint256(0), 255, 256, type(uint256).max];
        uint128[4] memory amounts = [uint128(0), 7, 23, 1e18];
        for (uint256 j; j < claims.length; j++) {
            claims[j] = ClaimKey({index: indexes[j], account: address(uint160(0x2000 + j)), amount: amounts[j]});
            // Build the proof independently of the contract's leaf helper.
            leaves[j] = keccak256(abi.encode(claims[j].index, claims[j].account, claims[j].amount));
        }
        bytes32 root = _hash(_hash(leaves[0], leaves[1]), _hash(leaves[2], leaves[3]));
        for (uint256 j; j < keys.length; j++) {
            // Same token and root, different owners: each drop must keep its own ledger and bitmap.
            keys[j] = DropKey({token: address(token), owner: address(uint160(0x1000 + j)), root: root});
        }
    }

    function fund(uint256 drop, uint128 minimum) external {
        drop %= keys.length;
        Model storage model = models[drop];
        uint256 funded = model.deposits - model.refunds;
        uint256 expected = minimum > funded ? minimum - funded : 0;
        assertEq(incentives.fund(keys[drop], minimum), expected);
        model.deposits += expected;
    }

    function refund(uint256 drop) external {
        drop %= keys.length;
        Model storage model = models[drop];
        uint256 expected = model.deposits - model.refunds - model.paid;
        vm.prank(keys[drop].owner);
        assertEq(incentives.refund(keys[drop]), expected);
        model.refunds += expected;
    }

    function claim(uint256 drop, uint256 leaf) external {
        drop %= keys.length;
        leaf %= claims.length;
        Model storage model = models[drop];
        ClaimKey memory c = claims[leaf];
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = leaves[leaf ^ 1];
        proof[1] = _hash(leaves[leaf ^ 2], leaves[leaf ^ 3]);

        if (model.claimed[leaf]) {
            vm.expectRevert(IIncentives.AlreadyClaimed.selector);
        } else if (model.deposits - model.refunds - model.paid < c.amount) {
            vm.expectRevert(IIncentives.InsufficientFunds.selector);
        } else {
            model.claimed[leaf] = true;
            model.paid += c.amount;
        }
        incentives.claim(keys[drop], c, proof);
    }

    function unauthorizedRefund(uint256 drop) external {
        vm.expectRevert(IIncentives.DropOwnerOnly.selector);
        incentives.refund(keys[drop % keys.length]);
    }

    function checkAccounting() external view {
        uint256 totalRemaining;
        uint256 totalDeposits;
        uint256[4] memory recipientBalances;
        for (uint256 j; j < keys.length; j++) {
            Model storage model = models[j];
            uint256 funded = model.deposits - model.refunds;
            uint256 remaining = funded - model.paid;
            assertEq(incentives.getFunded(keys[j]), funded);
            assertEq(incentives.getClaimed(keys[j]), model.paid);
            assertEq(incentives.getRemaining(keys[j]), remaining);
            assertEq(token.balanceOf(keys[j].owner), model.refunds);
            for (uint256 k; k < claims.length; k++) {
                assertEq(incentives.isClaimed(keys[j], claims[k].index), model.claimed[k]);
                assertEq(
                    incentives.isAvailable(keys[j], claims[k].index, claims[k].amount),
                    !model.claimed[k] && remaining >= claims[k].amount
                );
                if (model.claimed[k]) recipientBalances[k] += claims[k].amount;
            }
            totalRemaining += remaining;
            totalDeposits += model.deposits;
        }
        // Exact conservation applies to this standard token fixture, with no donations or self-transfers.
        assertEq(token.balanceOf(address(incentives)), totalRemaining);
        assertEq(token.balanceOf(address(this)), type(uint256).max - totalDeposits);
        for (uint256 k; k < claims.length; k++) {
            assertEq(token.balanceOf(claims[k].account), recipientBalances[k]);
        }
    }

    function _hash(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }
}

contract IncentivesInvariantTest is Test {
    IncentivesInvariantHandler private handler;

    function setUp() public {
        handler = new IncentivesInvariantHandler(vm);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.refund.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.unauthorizedRefund.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    /// forge-config: ci.invariant.runs = 64
    /// forge-config: ci.invariant.depth = 64
    function invariant_dropLedgersAndTransfersMatchModel() public view {
        handler.checkAccounting();
    }

    function test_refundAndRefillPreserveClaims() public {
        handler.claim(0, 0); // A zero-valued claim is consumed even before funding.
        handler.fund(0, type(uint128).max);
        handler.fund(1, 30);
        handler.claim(0, 1);
        handler.claim(1, 1); // Same index and root, independently claimable in the second drop.
        handler.refund(0);
        handler.checkAccounting();
        handler.refund(0); // Refunding an empty drop is idempotent.
        handler.fund(0, 7); // Already paid claims still count toward the funding minimum.
        handler.claim(0, 2); // Underfunded; must not consume the claim.
        handler.checkAccounting();
        handler.fund(0, 30);
        handler.claim(0, 2);
        handler.claim(0, 0); // Refunding and re-funding never resets the bitmap.
        handler.claim(0, 1);
        handler.fund(0, type(uint128).max);
        handler.claim(0, 3);
        handler.refund(0);
        handler.claim(1, 2);
        handler.unauthorizedRefund(1);
        handler.checkAccounting();
    }
}
