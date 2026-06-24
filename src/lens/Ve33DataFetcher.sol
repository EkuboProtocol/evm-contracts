// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ve33} from "../extensions/Ve33.sol";
import {IExposedStorage} from "../interfaces/IExposedStorage.sol";
import {Ve33Lib} from "../libraries/Ve33Lib.sol";
import {Ve33StorageLayout} from "../libraries/Ve33StorageLayout.sol";
import {StorageSlot} from "../types/storageSlot.sol";
import {getAllValidFutureTimes} from "./TWAMMDataFetcher.sol";

struct Ve33EmissionRateChange {
    uint64 time;
    int256 emissionRateDelta;
    uint192 emissionRateAfter;
}

struct Ve33EmissionState {
    uint64 currentTimestamp;
    uint192 currentEmissionRate;
    uint256 totalRemainingEmissions;
    Ve33EmissionRateChange[] futureEmissionRateChanges;
}

contract Ve33DataFetcher {
    using Ve33Lib for Ve33;

    error InvalidEmissionRate();

    Ve33 public immutable VE33_EXTENSION;

    constructor(Ve33 ve33) {
        VE33_EXTENSION = ve33;
    }

    function getEmissionState() public view returns (Ve33EmissionState memory state) {
        unchecked {
            Ve33 ve33 = VE33_EXTENSION;
            uint64 currentTimestamp = uint64(block.timestamp);
            uint64 lastAccrued = ve33.emissionsLastAccrued();
            uint192 runningEmissionRate = ve33.emissionRate();

            uint64[] memory allValidTimes = getAllValidFutureTimes(lastAccrued);
            StorageSlot[] memory rateDeltaSlots = new StorageSlot[](allValidTimes.length);

            for (uint256 i = 0; i < rateDeltaSlots.length; i++) {
                rateDeltaSlots[i] = Ve33StorageLayout.emissionRateDeltaAtTimeSlot(allValidTimes[i]);
            }

            (bool success, bytes memory result) =
                address(ve33).staticcall(abi.encodePacked(IExposedStorage.sload.selector, rateDeltaSlots));
            assert(success);

            Ve33EmissionRateChange[] memory futureEmissionRateChanges =
                new Ve33EmissionRateChange[](allValidTimes.length);
            uint256 futureChangeCount = 0;
            uint256 totalRemainingEmissions = 0;
            uint64 lastEmissionRateChangeTime = currentTimestamp;
            uint192 currentEmissionRate;
            bool currentEmissionRateSet;

            for (uint256 i = 0; i < allValidTimes.length; i++) {
                uint64 time = allValidTimes[i];
                int256 emissionRateDelta;
                assembly ("memory-safe") {
                    emissionRateDelta := mload(add(result, mul(add(i, 1), 32)))
                }

                if (emissionRateDelta != 0) {
                    if (time <= currentTimestamp) {
                        runningEmissionRate = _addEmissionRate(runningEmissionRate, emissionRateDelta);
                    } else {
                        if (!currentEmissionRateSet) {
                            currentEmissionRate = runningEmissionRate;
                            currentEmissionRateSet = true;
                        }
                        totalRemainingEmissions += (uint256(runningEmissionRate) * (time - lastEmissionRateChangeTime))
                                >> 32;
                        runningEmissionRate = _addEmissionRate(runningEmissionRate, emissionRateDelta);
                        futureEmissionRateChanges[futureChangeCount++] = Ve33EmissionRateChange({
                            time: time, emissionRateDelta: emissionRateDelta, emissionRateAfter: runningEmissionRate
                        });
                        lastEmissionRateChangeTime = time;
                    }
                }
            }

            if (!currentEmissionRateSet) currentEmissionRate = runningEmissionRate;

            assembly ("memory-safe") {
                mstore(futureEmissionRateChanges, futureChangeCount)
            }

            state = Ve33EmissionState({
                currentTimestamp: currentTimestamp,
                currentEmissionRate: currentEmissionRate,
                totalRemainingEmissions: totalRemainingEmissions,
                futureEmissionRateChanges: futureEmissionRateChanges
            });
        }
    }

    function _addEmissionRate(uint192 emissionRate, int256 delta) private pure returns (uint192 next) {
        int256 nextSigned = int256(uint256(emissionRate)) + delta;
        if (nextSigned < 0 || uint256(nextSigned) > type(uint192).max) revert InvalidEmissionRate();
        next = uint192(uint256(nextSigned));
    }
}
