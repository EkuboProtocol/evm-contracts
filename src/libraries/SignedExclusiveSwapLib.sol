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

    /// @notice Computes the EIP-712 digest expected by SignedExclusiveSwap for a payload.
    function hashSignedSwapPayload(
        ISignedExclusiveSwap extension,
        PoolId poolId,
        SignedSwapMeta meta,
        PoolBalanceUpdate minBalanceUpdate
    ) internal view returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(
                _SIGNED_SWAP_TYPEHASH,
                PoolId.unwrap(poolId),
                SignedSwapMeta.unwrap(meta),
                PoolBalanceUpdate.unwrap(minBalanceUpdate)
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(_EIP712_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, address(extension))
        );
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
