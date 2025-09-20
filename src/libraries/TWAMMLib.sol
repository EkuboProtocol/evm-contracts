// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {TWAMM} from "../extensions/TWAMM.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {TwammPoolState} from "../types/twammPoolState.sol";

// Common storage getters we need for external contracts are defined here instead of in the core contract
library TWAMMLib {
    using ExposedStorageLib for *;

    function poolState(TWAMM twamm, bytes32 poolId) internal view returns (TwammPoolState twammPoolState) {
        twammPoolState = TwammPoolState.wrap(twamm.sload(poolId));
    }

    function orderState(TWAMM twamm, address owner, bytes32 salt, bytes32 orderId)
        internal
        view
        returns (uint112 saleRate, uint32 lastUpdateTime, uint112 amountSold, uint256 rewardRateSnapshot)
    {
        bytes32 key;

        assembly ("memory-safe") {
            mstore(0, owner)
            mstore(32, 4)

            mstore(32, keccak256(0, 64))
            mstore(0, salt)

            mstore(32, keccak256(0, 64))
            mstore(0, orderId)

            key := keccak256(0, 64)
        }

        uint256 v0 = uint256(twamm.sload(key));
        saleRate = uint112(v0);
        lastUpdateTime = uint32(v0 >> 112);
        amountSold = uint112(v0 >> 144);
        rewardRateSnapshot = uint256(twamm.sload(bytes32(uint256(key) + 1)));
    }
}
