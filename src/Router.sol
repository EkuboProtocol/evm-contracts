// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseRouter} from "./base/BaseRouter.sol";
import {ICore} from "./interfaces/ICore.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PoolState} from "./types/poolState.sol";
import {PoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";
import {SwapParameters} from "./types/swapParameters.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title Ekubo Protocol Router
/// @author Moody Salem <moody@ekubo.org>
/// @notice Enables swapping and quoting against Ekubo pools, including MEV capture and Ve33 extension pools.
contract Router is BaseRouter {
    using CoreLib for *;

    uint160 private constant SWAP_CALL_POINTS_MASK = uint160(bytes20(hex"6000000000000000000000000000000000000000"));

    address public immutable MEV_CAPTURE;
    address public immutable VE33;

    /// @notice Constructs the Router contract.
    /// @param core The core contract instance.
    /// @param _mevCapture The MEV capture extension address, or zero if unsupported.
    /// @param _ve33 The Ve33 extension address, or zero if unsupported.
    constructor(ICore core, address _mevCapture, address _ve33) BaseRouter(core) {
        MEV_CAPTURE = _mevCapture;
        VE33 = _ve33;
    }

    /// @inheritdoc BaseRouter
    function _swap(uint256 value, PoolKey memory poolKey, SwapParameters params)
        internal
        override
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        SwapParameters normalizedParams = params.withDefaultSqrtRatioLimit();
        address extension = poolKey.config.extension();

        if ((uint160(extension) & SWAP_CALL_POINTS_MASK) == 0) {
            (balanceUpdate, stateAfter) = CORE.swap(value, poolKey, normalizedParams);
        } else if (extension == MEV_CAPTURE || extension == VE33) {
            (balanceUpdate, stateAfter) = _forwardSwap(extension, poolKey, normalizedParams);
            if (value != 0) SafeTransferLib.safeTransferETH(address(CORE), value);
        } else {
            (balanceUpdate, stateAfter) = CORE.swap(value, poolKey, normalizedParams);
        }
    }

    /// @dev Equivalent to decoding `CORE.forward(extension, abi.encode(poolKey, params))`, but writes the call data
    ///   once, directly into the buffer that is sent to core, and reads the two result words without copying the
    ///   return data into a new allocation.
    function _forwardSwap(address extension, PoolKey memory poolKey, SwapParameters params)
        private
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        ICore core = CORE;
        assembly ("memory-safe") {
            let free := mload(0x40)

            // Selector of forward(address), followed by the extension
            mstore(free, shl(224, 0x101e8952))
            mstore(add(free, 4), extension)

            // The forwarded data: the three words of the pool key and the swap parameters
            mcopy(add(free, 36), poolKey, 96)
            mstore(add(free, 132), params)

            // If the call failed, pass through the revert
            if iszero(call(gas(), core, 0, free, 164, free, 64)) {
                returndatacopy(free, 0, returndatasize())
                revert(free, returndatasize())
            }

            // A result shorter than the two words reverts with no data, as decoding it does
            if lt(returndatasize(), 64) { revert(0, 0) }

            balanceUpdate := mload(free)
            stateAfter := mload(add(free, 32))
        }
    }
}
