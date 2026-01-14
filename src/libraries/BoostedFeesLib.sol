// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "../interfaces/ICore.sol";
import {IBoostedFees} from "../interfaces/extensions/IBoostedFees.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {TWAMMStorageLayout} from "./TWAMMStorageLayout.sol";
import {FlashAccountantLib} from "./FlashAccountantLib.sol";
import {TwammPoolState} from "../types/twammPoolState.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolKey} from "../types/poolKey.sol";

/// @title BoostedFees Library
/// @notice Helper methods for interacting with the BoostedFees extension
library BoostedFeesLib {
    using ExposedStorageLib for *;
    using FlashAccountantLib for *;

    function poolState(IBoostedFees boostedFees, PoolId poolId) internal view returns (TwammPoolState twammPoolState) {
        twammPoolState = TwammPoolState.wrap(boostedFees.sload(TWAMMStorageLayout.twammPoolStateSlot(poolId)));
    }

    /// @notice Collects proceeds from a TWAMM order using FlashAccountantLib.forward
    /// @dev Uses FlashAccountantLib.forward to make the necessary call to add incentives
    /// @param core The core contract
    /// @param poolKey The pool key using the boosted fees extension that should have incentives added
    /// @param startTime The time that the incentives should start
    /// @param endTime The time that the incentives should end
    /// @param rate0 The rate at which token0 fees will be accumulated to the pool as a 80.32 number
    /// @param rate1 The rate at which token1 fees will be accumulated to the pool as a 80.32 number
    /// @return amount0 The amount of incentives in token0 that must be paid
    /// @return amount1 The amount of incentives in token1 that must be paid
    function addIncentives(
        ICore core,
        PoolKey memory poolKey,
        uint64 startTime,
        uint64 endTime,
        uint112 rate0,
        uint112 rate1
    ) internal returns (uint112 amount0, uint112 amount1) {
        (amount0, amount1) = abi.decode(
            core.forward(poolKey.config.extension(), abi.encode(poolKey, startTime, endTime, rate0, rate1)),
            (uint112, uint112)
        );
    }
}
