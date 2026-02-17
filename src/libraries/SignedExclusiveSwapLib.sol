// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "../interfaces/ICore.sol";
import {SignedSwapPayload} from "../interfaces/extensions/ISignedExclusiveSwap.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolConfig} from "../types/poolConfig.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {FlashAccountantLib} from "./FlashAccountantLib.sol";

/// @title SignedExclusiveSwap Library
/// @notice Helper methods for interacting with the SignedExclusiveSwap extension.
library SignedExclusiveSwapLib {
    bytes32 internal constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant _SIGNED_SWAP_TYPEHASH = keccak256(
        "SignedSwap(address token0,address token1,bytes32 config,bytes32 params,address authorizedLocker,uint64 deadline,uint64 extraFee,uint256 nonce)"
    );
    bytes32 internal constant _NAME_HASH = keccak256("Ekubo SignedExclusiveSwap");
    bytes32 internal constant _VERSION_HASH = keccak256("1");

    /// @notice Executes a signed exclusive swap by forwarding to the extension and decoding the return values.
    function swap(ICore core, address extension, SignedSwapPayload memory payload)
        internal
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        (balanceUpdate, stateAfter) = abi.decode(
            FlashAccountantLib.forward(core, extension, abi.encode(payload)), (PoolBalanceUpdate, PoolState)
        );
    }

    /// @notice Computes the EIP-712 digest expected by SignedExclusiveSwap for a payload.
    function hashTypedData(SignedSwapPayload memory payload, address extension) internal view returns (bytes32 digest) {
        bytes32 structHash = keccak256(
            abi.encode(
                _SIGNED_SWAP_TYPEHASH,
                payload.poolKey.token0,
                payload.poolKey.token1,
                PoolConfig.unwrap(payload.poolKey.config),
                SwapParameters.unwrap(payload.params),
                payload.authorizedLocker,
                payload.deadline,
                payload.extraFee,
                payload.nonce
            )
        );

        bytes32 domainSeparator =
            keccak256(abi.encode(_EIP712_DOMAIN_TYPEHASH, _NAME_HASH, _VERSION_HASH, block.chainid, extension));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
