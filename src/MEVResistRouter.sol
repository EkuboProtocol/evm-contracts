// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Router} from "./Router.sol";
import {ICore, PoolKey, SqrtRatio} from "./interfaces/ICore.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title Ekubo MEV Resist Router
/// @author Moody Salem <moody@ekubo.org>
/// @notice Enables swapping and quoting against pools in Ekubo Protocol including the MEV resist extension pools
contract MEVResistRouter is Router {
    using CoreLib for *;

    address public immutable mevResist;

    constructor(ICore core, address _mevResist) Router(core) {
        mevResist = _mevResist;
    }

    function _swap(
        uint256 value,
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead
    ) internal override returns (int128 delta0, int128 delta1) {
        if (poolKey.extension() == address(mevResist)) {
            (delta0, delta1) = abi.decode(
                forward(address(mevResist), abi.encode(poolKey, amount, isToken1, sqrtRatioLimit, skipAhead)),
                (int128, int128)
            );
            if (value != 0) {
                SafeTransferLib.safeTransferETH(address(core), value);
            }
        } else {
            (delta0, delta1) = core.swap(value, poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);
        }
    }
}
