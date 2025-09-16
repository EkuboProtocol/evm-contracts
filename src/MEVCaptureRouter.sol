// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Router} from "./Router.sol";
import {ICore, PoolKey, SqrtRatio} from "./interfaces/ICore.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title Ekubo MEV Capture Router
/// @author Moody Salem <moody@ekubo.org>
/// @notice Enables swapping and quoting against pools in Ekubo Protocol including the MEV capture extension pools
contract MEVCaptureRouter is Router {
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
    ) internal override returns (int128 delta0, int128 delta1) {
        if (poolKey.extension() != address(MEV_CAPTURE)) {
            (delta0, delta1) = CORE.swap(value, poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);
        } else {
            (delta0, delta1) = abi.decode(
                forward(address(MEV_CAPTURE), abi.encode(poolKey, amount, isToken1, sqrtRatioLimit, skipAhead)),
                (int128, int128)
            );
            if (value != 0) {
                SafeTransferLib.safeTransferETH(address(CORE), value);
            }
        }
    }
}
