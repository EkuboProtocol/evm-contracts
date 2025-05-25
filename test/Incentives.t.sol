// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Incentives, DropKey, Claim, hashClaim} from "../src/Incentives.sol";
import {TestToken} from "./TestToken.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

contract IncentivesTest is Test {
    Incentives i;
    TestToken t;

    function setUp() public {
        i = new Incentives();
        t = new TestToken(address(this));
    }

    function test_fund(address owner, bytes32 root, uint128 amount) public {
        DropKey memory key = DropKey({token: address(t), owner: owner, root: root});
        t.approve(address(i), type(uint256).max);

        assertEq(t.balanceOf(address(this)), type(uint256).max);
        assertEq(t.balanceOf(address(i)), 0);

        if (amount > 0) {
            vm.expectEmit(address(i));
            emit Incentives.Funded(key, amount);
        }
        assertEq(i.fund(key, amount), amount);

        assertEq(t.balanceOf(address(this)), type(uint256).max - amount);
        assertEq(t.balanceOf(address(i)), amount);
        assertEq(i.getRemaining(key), amount);
    }

    function test_double_fund_no_reverts(bytes32 root, uint128 amount) public {
        t.approve(address(i), type(uint256).max);

        i.fund({key: DropKey({owner: address(this), token: address(t), root: root}), minimum: amount});
        i.fund({key: DropKey({owner: address(this), token: address(t), root: root}), minimum: amount});
    }

    function test_claim(uint256 index, address account, uint128 amount) public {
        t.approve(address(i), type(uint256).max);
        bytes32 root = hashClaim(Claim({index: index, account: account, amount: amount}));

        if (amount == 0) {
            assertTrue(i.isAvailable(DropKey({owner: address(this), token: address(t), root: root}), index, amount));
        } else {
            assertFalse(i.isAvailable(DropKey({owner: address(this), token: address(t), root: root}), index, amount));
        }

        i.fund(DropKey({owner: address(this), token: address(t), root: root}), amount);

        assertTrue(i.isAvailable(DropKey({owner: address(this), token: address(t), root: root}), index, amount));

        bytes32[] memory proof = new bytes32[](0);
        uint256 beforeClaim = t.balanceOf(account);
        i.claim(
            DropKey({owner: address(this), token: address(t), root: root}),
            Claim({index: index, account: account, amount: amount}),
            proof
        );
        uint256 afterClaim = t.balanceOf(account);
        assertFalse(i.isAvailable(DropKey({owner: address(this), token: address(t), root: root}), index, amount));
        if (account != address(i)) assertEq(afterClaim - beforeClaim, amount);
        else assertEq(afterClaim - beforeClaim, 0);
    }

    function test_refund(uint128 funded, address owner, uint256 index, address account, uint128 amount) public {
        t.approve(address(i), type(uint256).max);
        amount = uint128(bound(amount, 0, funded));
        bytes32 root = hashClaim(Claim({index: index, account: account, amount: amount}));

        i.fund(DropKey({owner: owner, token: address(t), root: root}), funded);

        bytes32[] memory proof = new bytes32[](0);
        i.claim(
            DropKey({owner: owner, token: address(t), root: root}),
            Claim({index: index, account: account, amount: amount}),
            proof
        );

        uint256 beforeRefund = t.balanceOf(owner);
        vm.prank(owner);
        emit Incentives.Refunded(DropKey({owner: owner, token: address(t), root: root}), (funded - amount));
        i.refund(DropKey({owner: owner, token: address(t), root: root}));
        uint256 afterRefund = t.balanceOf(owner);
        if (owner != address(i)) {} else {
            assertEq(afterRefund - beforeRefund, 0);
        }
    }

    function test_claim_gas() public {
        t.approve(address(i), type(uint256).max);
        bytes32 root = hashClaim(Claim({index: 0, account: address(this), amount: 100}));
        i.fund(DropKey({owner: address(this), token: address(t), root: root}), 100);
        bytes32[] memory proof = new bytes32[](0);
        i.claim(
            DropKey({owner: address(this), token: address(t), root: root}),
            Claim({index: 0, account: address(this), amount: 100}),
            proof
        );
        vm.snapshotGasLastCall("#claim");
    }

    function test_claim_two(address accountA, uint128 amountA, address accountB, uint128 amountB) public {
        t.approve(address(i), type(uint256).max);

        amountB = uint128(bound(amountB, 0, type(uint128).max - amountA));

        bytes32 leafA = hashClaim(Claim({index: 0, account: accountA, amount: amountA}));
        bytes32 leafB = hashClaim(Claim({index: 1, account: accountB, amount: amountB}));
        (bytes32 leaf0, bytes32 leaf1) = uint256(leafA) < uint256(leafB) ? (leafA, leafB) : (leafB, leafA);
        bytes32 root = EfficientHashLib.hash(leaf0, leaf1);
        i.fund(DropKey({owner: address(this), token: address(t), root: root}), amountA + amountB);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;
        i.claim(
            DropKey({owner: address(this), token: address(t), root: root}),
            Claim({index: 0, account: accountA, amount: amountA}),
            proof
        );
        assertFalse(i.isAvailable(DropKey({owner: address(this), token: address(t), root: root}), 0, amountA));

        proof[0] = leafA;
        i.claim(
            DropKey({owner: address(this), token: address(t), root: root}),
            Claim({index: 1, account: accountB, amount: amountB}),
            proof
        );
        assertFalse(i.isAvailable(DropKey({owner: address(this), token: address(t), root: root}), 1, amountB));
    }

    function test_claim_twice_fails() public {
        t.approve(address(i), type(uint256).max);
        bytes32 root = hashClaim(Claim({index: 0, account: address(this), amount: 100}));
        i.fund(DropKey({owner: address(this), token: address(t), root: root}), 100);

        bytes32[] memory proof = new bytes32[](0);
        i.claim(
            DropKey({owner: address(this), token: address(t), root: root}),
            Claim({index: 0, account: address(this), amount: 100}),
            proof
        );
        vm.expectRevert(Incentives.AlreadyClaimed.selector);
        i.claim(
            DropKey({owner: address(this), token: address(t), root: root}),
            Claim({index: 0, account: address(this), amount: 100}),
            proof
        );
    }

    function test_claim_not_funded_fails() public {
        bytes32 root = hashClaim(Claim({index: 0, account: address(this), amount: 100}));

        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(Incentives.InsufficientFunds.selector);
        i.claim(
            DropKey({owner: address(this), token: address(t), root: root}),
            Claim({index: 0, account: address(this), amount: 100}),
            proof
        );
    }

    function test_claim_invalid_hash_fails() public {
        bytes32 root = hashClaim(Claim({index: 0, account: address(this), amount: 100}));

        vm.expectRevert(Incentives.InvalidProof.selector);
        bytes32[] memory proof = new bytes32[](0);
        i.claim(
            DropKey({owner: address(this), token: address(t), root: root}),
            Claim({index: 1, account: address(this), amount: 100}),
            proof
        );
    }
}
