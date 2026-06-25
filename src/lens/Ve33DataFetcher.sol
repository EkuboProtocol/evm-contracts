// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ve33} from "../extensions/Ve33.sol";
import {IExposedStorage} from "../interfaces/IExposedStorage.sol";
import {Ve33Lib} from "../libraries/Ve33Lib.sol";
import {Ve33StorageLayout} from "../libraries/Ve33StorageLayout.sol";
import {StorageSlot} from "../types/storageSlot.sol";
import {MAX_NUM_VALID_TIMES, nextValidTime} from "../math/time.sol";

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
            uint256 currentTimestamp = block.timestamp;
            uint32 lastAccrued = ve33.emissionsLastAccrued();
            uint256 lastAccruedReal = _realEmissionTimeAtOrBefore(currentTimestamp, lastAccrued);
            uint192 runningEmissionRate = ve33.emissionRate();

            uint64[] memory allValidTimes = _getAllValidFutureTimes(lastAccruedReal);
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
            uint256 lastEmissionRateChangeTime = currentTimestamp;
            uint192 currentEmissionRate;
            bool currentEmissionRateSet;

            for (uint256 i = 0; i < allValidTimes.length; i++) {
                uint64 time = allValidTimes[i];
                uint256 realTime = time;
                int256 emissionRateDelta;
                assembly ("memory-safe") {
                    emissionRateDelta := mload(add(result, mul(add(i, 1), 32)))
                }

                if (emissionRateDelta != 0) {
                    if (realTime <= currentTimestamp) {
                        runningEmissionRate = _addEmissionRate(runningEmissionRate, emissionRateDelta);
                    } else {
                        if (!currentEmissionRateSet) {
                            currentEmissionRate = runningEmissionRate;
                            currentEmissionRateSet = true;
                        }
                        totalRemainingEmissions += (uint256(runningEmissionRate)
                                        * (realTime - lastEmissionRateChangeTime)) >> 32;
                        runningEmissionRate = _addEmissionRate(runningEmissionRate, emissionRateDelta);
                        futureEmissionRateChanges[futureChangeCount++] = Ve33EmissionRateChange({
                            time: time, emissionRateDelta: emissionRateDelta, emissionRateAfter: runningEmissionRate
                        });
                        lastEmissionRateChangeTime = realTime;
                    }
                }
            }

            if (!currentEmissionRateSet) currentEmissionRate = runningEmissionRate;

            assembly ("memory-safe") {
                mstore(futureEmissionRateChanges, futureChangeCount)
            }

            state = Ve33EmissionState({
                currentTimestamp: uint64(currentTimestamp),
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

    function _getAllValidFutureTimes(uint256 currentTime) private pure returns (uint64[] memory times) {
        unchecked {
            times = new uint64[](MAX_NUM_VALID_TIMES);
            uint256 count = 0;
            uint256 t = currentTime;

            while (true) {
                uint256 nextTime = nextValidTime(currentTime, t);
                if (nextTime == 0) break;

                t = nextTime;
                times[count++] = uint64(t);
            }

            assembly ("memory-safe") {
                mstore(times, count)
            }
        }
    }

    function _realEmissionTimeAtOrBefore(uint256 referenceTime, uint32 time) private pure returns (uint256 realTime) {
        unchecked {
            realTime = referenceTime - (uint32(referenceTime) - time);
        }
    }
}
