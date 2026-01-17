// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {CoreLib} from "../libraries/CoreLib.sol";
import {BoostedFeesLib} from "../libraries/BoostedFeesLib.sol";
import {UsesCore} from "../base/UsesCore.sol";
import {ICore} from "../interfaces/ICore.sol";
import {IBoostedFees} from "../interfaces/extensions/IBoostedFees.sol";
import {PoolKey} from "../types/poolKey.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {getAllValidFutureTimes} from "./TWAMMDataFetcher.sol";
import {IExposedStorage} from "../interfaces/IExposedStorage.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {TWAMMStorageLayout} from "../libraries/TWAMMStorageLayout.sol";
import {StorageSlot} from "../types/storageSlot.sol";

struct BoostedTimeDonateRateInfo {
    uint64 time;
    int128 donateRateDelta0;
    int128 donateRateDelta1;
}

struct BoostedPoolState {
    SqrtRatio sqrtRatio;
    int32 tick;
    uint128 liquidity;
    uint64 lastDonateTime;
    uint112 donateRateToken0;
    uint112 donateRateToken1;
    BoostedTimeDonateRateInfo[] donateRateDeltas;
}

contract BoostedFeesDataFetcher is UsesCore {
    using CoreLib for *;
    using BoostedFeesLib for *;

    IBoostedFees public immutable BOOSTED_FEES_EXTENSION;

    constructor(ICore core, IBoostedFees boostedFees) UsesCore(core) {
        BOOSTED_FEES_EXTENSION = boostedFees;
    }

    function getPoolState(PoolKey memory poolKey) public view returns (BoostedPoolState memory state) {
        unchecked {
            (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity) = CORE.poolState(poolKey.toPoolId()).parse();
            (uint32 lastDonateTime, uint112 donateRateToken0, uint112 donateRateToken1) =
                BOOSTED_FEES_EXTENSION.poolState(poolKey.toPoolId()).parse();

            uint64 lastTimeReal = uint64(block.timestamp - (uint32(block.timestamp) - lastDonateTime));

            uint64[] memory allValidTimes = getAllValidFutureTimes(lastTimeReal);

            PoolId poolId = poolKey.toPoolId();
            StorageSlot[] memory timeInfoSlots = new StorageSlot[](allValidTimes.length);

            for (uint256 i = 0; i < timeInfoSlots.length; i++) {
                timeInfoSlots[i] = TWAMMStorageLayout.poolTimeInfosSlot(poolId, allValidTimes[i]);
            }

            (bool success, bytes memory result) = address(BOOSTED_FEES_EXTENSION)
                .staticcall(abi.encodePacked(IExposedStorage.sload.selector, timeInfoSlots));
            assert(success);

            uint256 countNonZero = 0;
            BoostedTimeDonateRateInfo[] memory donateRateDeltas = new BoostedTimeDonateRateInfo[](timeInfoSlots.length);

            for (uint256 i = 0; i < allValidTimes.length; i++) {
                PoolBalanceUpdate timeInfo;
                assembly ("memory-safe") {
                    timeInfo := mload(add(result, mul(add(i, 1), 32)))
                }

                if (PoolBalanceUpdate.unwrap(timeInfo) != bytes32(0)) {
                    donateRateDeltas[countNonZero++] =
                        BoostedTimeDonateRateInfo(allValidTimes[i], timeInfo.delta0(), timeInfo.delta1());
                }
            }

            assembly ("memory-safe") {
                mstore(donateRateDeltas, countNonZero)
            }

            state = BoostedPoolState({
                sqrtRatio: sqrtRatio,
                tick: tick,
                liquidity: liquidity,
                lastDonateTime: lastTimeReal,
                donateRateToken0: donateRateToken0,
                donateRateToken1: donateRateToken1,
                donateRateDeltas: donateRateDeltas
            });
        }
    }
}
