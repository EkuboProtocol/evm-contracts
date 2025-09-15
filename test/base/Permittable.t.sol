// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Permittable} from "../../src/base/Permittable.sol";
import {TestToken} from "../TestToken.sol";

contract TestTarget is Permittable {}

contract PermittableTest is Test {
    TestTarget target;
    TestToken token;

    function setUp() public {
        token = new TestToken(address(this));
        target = new TestTarget();
    }

    function test_permittable(uint256 amount, uint256 deadline, uint256 privateKey) public {
        Vm.Wallet memory a = vm.createWallet(
            bound(privateKey, 1, 115792089237316195423570985008687907852837564279074904382605163141518161494336)
        );

        amount = bound(amount, 0, type(uint160).max);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            a,
            keccak256(
                abi.encodePacked(
                    hex"1901",
                    token.DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            keccak256(
                                "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                            ),
                            a.addr,
                            address(target),
                            amount,
                            token.nonces(a.addr),
                            deadline
                        )
                    )
                )
            )
        );

        assertEq(token.allowance(a.addr, address(target)), 0);

        vm.deal(a.addr, 1);
        vm.prank(a.addr);

        if (deadline < vm.getBlockTimestamp()) {
            vm.expectRevert(SafeTransferLib.Permit2Failed.selector);
            target.permit{value: 1}(address(token), amount, deadline, v, r, s);
            assertEq(token.allowance(a.addr, address(target)), 0);
        } else {
            // value = 1 for payable testing
            target.permit{value: 1}(address(token), amount, deadline, v, r, s);
            assertEq(token.allowance(a.addr, address(target)), amount);
        }
    }
}
