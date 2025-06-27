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

    function test_hashClaim() public {
        vm.snapshotValue("zero claim", uint256(hashClaim(Claim({index: 0, account: address(0), amount: 0}))));
        vm.snapshotValue("1,2,3 claim", uint256(hashClaim(Claim({index: 1, account: address(2), amount: 3}))));
        vm.snapshotValue("3,1,2 claim", uint256(hashClaim(Claim({index: 3, account: address(1), amount: 2}))));
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
        // second funding does nothing since minimum already set
        assertEq(i.fund(key, amount), 0);

        assertEq(t.balanceOf(address(this)), type(uint256).max - amount);
        assertEq(t.balanceOf(address(i)), amount);
        assertEq(i.getRemaining(key), amount);
    }

    function test_claim(uint256 index, address account, uint128 amount) public {
        t.approve(address(i), type(uint256).max);
        bytes32 root = hashClaim(Claim({index: index, account: account, amount: amount}));

        DropKey memory key = DropKey({owner: address(this), token: address(t), root: root});
        if (amount == 0) {
            assertTrue(i.isAvailable(key, index, amount));
        } else {
            assertFalse(i.isAvailable(key, index, amount));
        }

        assertFalse(i.isClaimed(key, index));

        i.fund(key, amount);

        assertTrue(i.isAvailable(key, index, amount));
        assertFalse(i.isClaimed(key, index));

        bytes32[] memory proof = new bytes32[](0);
        uint256 beforeClaim = t.balanceOf(account);
        i.claim(key, Claim({index: index, account: account, amount: amount}), proof);
        uint256 afterClaim = t.balanceOf(account);
        assertFalse(i.isAvailable(key, index, amount));
        assertTrue(i.isClaimed(key, index));

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

    function test_claim_twice_fails(uint256 index, address account, uint128 amount) public {
        t.approve(address(i), amount);

        Claim memory c = Claim({index: index, account: account, amount: amount});
        bytes32 root = hashClaim(c);

        DropKey memory dropKey = DropKey({owner: address(this), token: address(t), root: root});
        i.fund(dropKey, amount);

        bytes32[] memory proof = new bytes32[](0);
        i.claim(dropKey, c, proof);
        vm.expectRevert(Incentives.AlreadyClaimed.selector);
        i.claim(dropKey, c, proof);
    }

    function test_claim_underfunded_fails(uint128 amount, uint128 funded) public {
        amount = uint128(bound(amount, 1, type(uint128).max));
        funded = uint128(bound(funded, 0, amount - 1));

        Claim memory c = Claim({index: 0, account: address(this), amount: amount});
        bytes32 root = hashClaim(c);
        DropKey memory dropKey = DropKey({owner: address(this), token: address(t), root: root});

        // fund the drop first if necessary
        if (funded != 0) {
            t.approve(address(i), funded);
            i.fund(dropKey, funded);
        }

        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(Incentives.InsufficientFunds.selector);
        i.claim(dropKey, c, proof);
    }

    function test_claim_invalid_claim_fails() public {
        Claim memory c = Claim({index: 0, account: address(this), amount: 100});
        bytes32 root = hashClaim(c);
        DropKey memory dropKey = DropKey({owner: address(this), token: address(t), root: root});

        bytes32[] memory proof = new bytes32[](0);
        c.index = 1;
        vm.expectRevert(Incentives.InvalidProof.selector);
        i.claim(dropKey, c, proof);
    }

    function test_claim_invalid_proof_fails() public {
        Claim memory c = Claim({index: 0, account: address(this), amount: 100});
        bytes32 root = hashClaim(c);
        DropKey memory dropKey = DropKey({owner: address(this), token: address(t), root: root});

        vm.expectRevert(Incentives.InvalidProof.selector);
        // proof has a single zero element
        bytes32[] memory proof = new bytes32[](1);
        i.claim(dropKey, c, proof);
    }
}
