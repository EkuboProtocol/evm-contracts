// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Incentives} from "../src/Incentives.sol";
import {TestToken} from "./TestToken.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

contract IncentivesTest is Test {
    Incentives i;
    TestToken t;

    function setUp() public {
        i = new Incentives();
        t = new TestToken(address(this));
    }

    function test_fund(bytes32 root, uint256 amount) public {
        t.approve(address(i), type(uint256).max);

        assertEq(t.balanceOf(address(this)), type(uint256).max);
        assertEq(t.balanceOf(address(i)), 0);

        vm.expectEmit(address(i));
        emit Incentives.Funded(address(t), root, amount);
        i.fund({token: address(t), root: root, amount: amount});

        assertEq(t.balanceOf(address(this)), type(uint256).max - amount);
        assertEq(t.balanceOf(address(i)), amount);
        assertEq(i.getRemaining(address(t), root), amount);
    }

    function test_double_fund_reverts(bytes32 root, uint256 amount) public {
        t.approve(address(i), type(uint256).max);

        i.fund({token: address(t), root: root, amount: amount});
        vm.expectRevert(Incentives.AlreadyFunded.selector);
        i.fund({token: address(t), root: root, amount: amount});
    }

    function test_claim(uint256 index, address account, uint256 amount) public {
        t.approve(address(i), type(uint256).max);
        bytes32 root = i.hashClaim({index: index, account: account, amount: amount});
        i.fund(address(t), root, amount);

        bytes32[] memory proof = new bytes32[](0);
        uint256 beforeClaim = t.balanceOf(account);
        i.claim(address(t), root, index, account, amount, proof);
        uint256 afterClaim = t.balanceOf(account);
        assertTrue(i.isClaimed(address(t), root, index));
        assertEq(afterClaim - beforeClaim, amount);
    }

    function test_claim_gas() public {
        t.approve(address(i), type(uint256).max);
        bytes32 root = i.hashClaim({index: 0, account: address(this), amount: 100});
        i.fund(address(t), root, 100);
        bytes32[] memory proof = new bytes32[](0);
        i.claim(address(t), root, 0, address(this), 100, proof);
        vm.snapshotGasLastCall("#claim");
    }

    function test_claim_two(address accountA, uint256 amountA, address accountB, uint256 amountB) public {
        t.approve(address(i), type(uint256).max);

        amountB = bound(amountB, 0, type(uint256).max - amountA);

        bytes32 leafA = i.hashClaim({index: 0, account: accountA, amount: amountA});
        bytes32 leafB = i.hashClaim({index: 1, account: accountB, amount: amountB});
        (bytes32 leaf0, bytes32 leaf1) = uint256(leafA) < uint256(leafB) ? (leafA, leafB) : (leafB, leafA);
        bytes32 root = EfficientHashLib.hash(leaf0, leaf1);
        i.fund(address(t), root, amountA + amountB);

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = leafB;
        i.claim(address(t), root, 0, accountA, amountA, proof);
        assertTrue(i.isClaimed(address(t), root, 0));

        proof[0] = leafA;
        i.claim(address(t), root, 1, accountB, amountB, proof);
        assertTrue(i.isClaimed(address(t), root, 1));
    }

    function test_claim_twice_fails() public {
        t.approve(address(i), type(uint256).max);
        bytes32 root = i.hashClaim({index: 0, account: address(this), amount: 100});
        i.fund(address(t), root, 100);

        bytes32[] memory proof = new bytes32[](0);
        i.claim(address(t), root, 0, address(this), 100, proof);
        vm.expectRevert(Incentives.AlreadyClaimed.selector);
        i.claim(address(t), root, 0, address(this), 100, proof);
    }

    function test_claim_not_funded_fails() public {
        bytes32 root = i.hashClaim({index: 0, account: address(this), amount: 100});

        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(Incentives.InsufficientFunds.selector);
        i.claim(address(t), root, 0, address(this), 100, proof);
    }

    function test_claim_invalid_hash_fails() public {
        bytes32 root = i.hashClaim({index: 0, account: address(this), amount: 100});

        vm.expectRevert(Incentives.InvalidProof.selector);
        bytes32[] memory proof = new bytes32[](0);
        i.claim(address(t), root, 1, address(this), 100, proof);
    }
}
