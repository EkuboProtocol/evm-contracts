// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseRouter} from "./base/BaseRouter.sol";
import {ICore} from "./interfaces/ICore.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
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
    using FlashAccountantLib for *;
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
            (balanceUpdate, stateAfter) = abi.decode(
                CORE.forward(extension, abi.encode(poolKey, normalizedParams)), (PoolBalanceUpdate, PoolState)
            );
            if (value != 0) SafeTransferLib.safeTransferETH(address(CORE), value);
        } else {
            (balanceUpdate, stateAfter) = CORE.swap(value, poolKey, normalizedParams);
        }
    }
}
