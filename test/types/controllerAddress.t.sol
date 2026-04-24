// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {ControllerAddress} from "../../src/types/controllerAddress.sol";

contract MockController1271 {
    address internal immutable signer;
    bytes4 internal constant MAGIC_VALUE = 0x1626ba7e;

    constructor(address _signer) {
        signer = _signer;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        (uint8 v, bytes32 r, bytes32 s) = _decodeSignature(signature);
        if (ecrecover(digest, v, r, s) == signer) {
            return MAGIC_VALUE;
        }
        return 0xffffffff;
    }

    function _decodeSignature(bytes calldata signature) private pure returns (uint8 v, bytes32 r, bytes32 s) {
        if (signature.length != 65) {
            return (0, bytes32(0), bytes32(0));
        }

        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
    }
}

contract ControllerAddressTest is Test {
    function test_isEoa_highBitUnset() public pure {
        ControllerAddress controller = ControllerAddress.wrap(address(0x1234));

        assertTrue(controller.isEoa());
    }

    function test_isEoa_highBitSet() public pure {
        address highBitSetAddress = address(uint160(1) << 159);
        ControllerAddress controller = ControllerAddress.wrap(highBitSetAddress);

        assertFalse(controller.isEoa());
    }

    function test_isSignatureValid_eoa_trueForMatchingSignature() public view {
        uint256 controllerPk = _firstEoaKey();
        address controllerAddress = vm.addr(controllerPk);
        bytes32 digest = keccak256("controller-address-eoa-valid");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        assertTrue(ControllerAddress.wrap(controllerAddress).isSignatureValid(digest, signature));
    }

    function test_isSignatureValid_eoa_falseForWrongSignature() public view {
        uint256 controllerPk = _firstEoaKey();
        uint256 otherPk = controllerPk + 1;
        while (uint160(vm.addr(otherPk)) >> 159 != 0) {
            unchecked {
                ++otherPk;
            }
        }

        address controllerAddress = vm.addr(controllerPk);
        bytes32 digest = keccak256("controller-address-eoa-invalid");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        assertFalse(ControllerAddress.wrap(controllerAddress).isSignatureValid(digest, signature));
    }

    function test_isSignatureValid_contract_trueForValid1271Signature() public {
        uint256 signerPk = _firstEoaKey();
        MockController1271 contractController = _deploy1271WithHighBitAddress(vm.addr(signerPk));
        bytes32 digest = keccak256("controller-address-1271-valid");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        assertTrue(ControllerAddress.wrap(address(contractController)).isSignatureValid(digest, signature));
    }

    function test_isSignatureValid_contract_falseForInvalid1271Signature() public {
        uint256 signerPk = _firstEoaKey();
        uint256 otherPk = signerPk + 1;
        while (uint160(vm.addr(otherPk)) >> 159 != 0) {
            unchecked {
                ++otherPk;
            }
        }

        MockController1271 contractController = _deploy1271WithHighBitAddress(vm.addr(signerPk));
        bytes32 digest = keccak256("controller-address-1271-invalid");

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        assertFalse(ControllerAddress.wrap(address(contractController)).isSignatureValid(digest, signature));
    }

    function _firstEoaKey() private view returns (uint256 key) {
        key = 1;
        while (uint160(vm.addr(key)) >> 159 != 0) {
            unchecked {
                ++key;
            }
        }
    }

    function _deploy1271WithHighBitAddress(address signer) private returns (MockController1271 controller) {
        for (uint256 i; i < 16; ++i) {
            controller = new MockController1271(signer);
            if (uint160(address(controller)) >> 159 == 1) {
                return controller;
            }
        }

        fail();
    }
}
