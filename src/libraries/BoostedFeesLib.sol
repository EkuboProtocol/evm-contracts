// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IBoostedFees} from "../interfaces/extensions/IBoostedFees.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {TWAMMStorageLayout} from "./TWAMMStorageLayout.sol";
import {FlashAccountantLib} from "./FlashAccountantLib.sol";
import {TwammPoolState} from "../types/twammPoolState.sol";
import {PoolId} from "../types/poolId.sol";
import {StorageSlot} from "../types/storageSlot.sol";

/// @title BoostedFees Library
/// @notice Helper methods for interacting with the BoostedFees extension
library BoostedFeesLib {
    using ExposedStorageLib for *;
    using FlashAccountantLib for *;

    function poolState(IBoostedFees boostedFees, PoolId poolId) internal view returns (TwammPoolState twammPoolState) {
        twammPoolState = TwammPoolState.wrap(boostedFees.sload(TWAMMStorageLayout.twammPoolStateSlot(poolId)));
    }
}
