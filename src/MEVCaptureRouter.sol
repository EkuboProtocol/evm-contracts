// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {Router} from "./Router.sol";
import {ICore, PoolKey} from "./interfaces/ICore.sol";
import {PoolState} from "./types/poolState.sol";
import {PoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";
import {SwapParameters} from "./types/swapParameters.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {CoreLib} from "./libraries/CoreLib.sol";

/// @title Ekubo MEV Capture Router
/// @author Moody Salem <moody@ekubo.org>
/// @notice Enables swapping and quoting against pools in Ekubo Protocol including the MEV capture extension pools
contract MEVCaptureRouter is Router {
    using FlashAccountantLib for *;
    using CoreLib for *;

    address public immutable MEV_CAPTURE;

    constructor(ICore core, address _mevCapture) Router(core) {
        MEV_CAPTURE = _mevCapture;
    }

    function _swap(uint256 value, PoolKey memory poolKey, SwapParameters params)
        internal
        override
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        if (poolKey.config.extension() != MEV_CAPTURE) {
            (balanceUpdate, stateAfter) = CORE.swap(value, poolKey, params.withDefaultSqrtRatioLimit());
        } else {
            (balanceUpdate, stateAfter) = abi.decode(
                CORE.forward(MEV_CAPTURE, abi.encode(poolKey, params.withDefaultSqrtRatioLimit())),
                (PoolBalanceUpdate, PoolState)
            );
            if (value != 0) {
                SafeTransferLib.safeTransferETH(address(CORE), value);
            }
        }
    }
}
