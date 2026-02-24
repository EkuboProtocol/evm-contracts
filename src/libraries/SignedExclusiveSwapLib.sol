// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "../interfaces/ICore.sol";
import {ISignedExclusiveSwap} from "../interfaces/extensions/ISignedExclusiveSwap.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {SignedSwapMeta} from "../types/signedSwapMeta.sol";
import {FlashAccountantLib} from "./FlashAccountantLib.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

/// @title SignedExclusiveSwap Library
/// @notice Helper methods for interacting with the SignedExclusiveSwap extension.
library SignedExclusiveSwapLib {
    bytes32 internal constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant _SIGNED_SWAP_TYPEHASH =
        keccak256("SignedSwap(bytes32 poolId,uint256 meta,bytes32 minBalanceUpdate)");
    bytes32 internal constant _NAME_HASH = keccak256("Ekubo SignedExclusiveSwap");
    bytes32 internal constant _VERSION_HASH = keccak256("1");

    /// @notice Executes a signed exclusive swap by forwarding to the extension and decoding the return values.
    function swap(
        ICore core,
        address extension,
        PoolKey memory poolKey,
        SwapParameters params,
        SignedSwapMeta meta,
        PoolBalanceUpdate minBalanceUpdate,
        bytes memory signature
    ) internal returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) {
        (balanceUpdate, stateAfter) = abi.decode(
            FlashAccountantLib.forward(core, extension, abi.encode(poolKey, params, meta, minBalanceUpdate, signature)),
            (PoolBalanceUpdate, PoolState)
        );
    }

    function computeDomainSeparatorHash(ISignedExclusiveSwap extension)
        internal
        view
        returns (bytes32 domainSeparator)
    {
        domainSeparator = EfficientHashLib.hash(
            _EIP712_DOMAIN_TYPEHASH,
            _NAME_HASH,
            _VERSION_HASH,
            bytes32(block.chainid),
            bytes32(uint256(uint160(address(extension))))
        );
    }

    /// @notice Computes the EIP-712 digest expected by SignedExclusiveSwap for a payload and a given domain separator.
    function hashSignedSwapPayload(
        bytes32 domainSeparator,
        PoolId poolId,
        SignedSwapMeta meta,
        PoolBalanceUpdate minBalanceUpdate
    ) internal pure returns (bytes32 digest) {
        bytes32 structHash = EfficientHashLib.hash(
            _SIGNED_SWAP_TYPEHASH,
            PoolId.unwrap(poolId),
            bytes32(SignedSwapMeta.unwrap(meta)),
            PoolBalanceUpdate.unwrap(minBalanceUpdate)
        );

        assembly ("memory-safe") {
            mstore(0x00, 0x1901000000000000) // Store "\x19\x01".
            mstore(0x1a, domainSeparator) // Store the domain separator.
            mstore(0x3a, structHash) // Store the struct hash.
            digest := keccak256(0x18, 0x42)
            // Restore the part of the free memory slot that was overwritten.
            mstore(0x3a, 0)
        }
    }

    /// @notice Computes the EIP-712 digest expected by SignedExclusiveSwap for a payload, computing the domain separator from the address and chain ID.
    function hashSignedSwapPayload(
        ISignedExclusiveSwap extension,
        PoolId poolId,
        SignedSwapMeta meta,
        PoolBalanceUpdate minBalanceUpdate
    ) internal view returns (bytes32 digest) {
        digest = hashSignedSwapPayload(computeDomainSeparatorHash(extension), poolId, meta, minBalanceUpdate);
    }
}
