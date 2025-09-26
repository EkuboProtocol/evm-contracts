// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Router} from "./Router.sol";
import {ICore, PoolKey, SqrtRatio} from "./interfaces/ICore.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {PoolState} from "./types/poolState.sol";
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

    function _swap(
        uint256 value,
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead
    ) internal override returns (int128 delta0, int128 delta1, PoolState stateAfter) {
        if (poolKey.extension() != MEV_CAPTURE) {
            (delta0, delta1, stateAfter) = CORE.swap(poolKey, amount, isToken1, sqrtRatioLimit, skipAhead, value);
        } else {
            (delta0, delta1, stateAfter) = abi.decode(
                CORE.forward(MEV_CAPTURE, abi.encode(poolKey, amount, isToken1, sqrtRatioLimit, skipAhead)),
                (int128, int128, PoolState)
            );
            if (value != 0) {
                SafeTransferLib.safeTransferETH(address(CORE), value);
            }
        }
    }
}
