// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {OwnedUpgradeable} from "./base/OwnedUpgradeable.sol";
import {CallPoints, byteToCallPoints} from "./types/callPoints.sol";
import {PoolKey, PositionKey} from "./types/keys.sol";
import {Position} from "./types/position.sol";
import {LibBitmap} from "solady/utils/LibBitmap.sol";

interface ILocker {
    function locked(uint256 id, bytes calldata data) external returns (bytes memory);
}

contract Core is OwnedUpgradeable {
    using LibBitmap for LibBitmap.Bitmap;

    struct TickInfo {
        int128 liquidityDelta;
        uint128 liquidityNet;
    }

    struct PoolData {
        // The current price
        uint192 sqrtRatio;
        int32 tick;
        // The current pool liquidity
        uint128 liquidity;
        // The total fees per liquidity for each token
        uint256 token0_fees_per_liquidity;
        uint256 token1_fees_per_liquidity;
        // All the positions on the pool
        mapping(bytes32 positionId => Position position) positions;
        // All the tick data for the pool
        mapping(int32 tick => TickInfo tickInfo) ticks;
        LibBitmap.Bitmap initializedTicks;
    }

    error FailedRegisterInvalidCallPoints();
    error ExtensionAlreadyRegistered();

    mapping(address extension => bool isRegistered) public isExtensionRegistered;
    mapping(address token => uint256 amountCollected) public protocolFeesCollected;

    // Keyed by the pool ID, which is the keccak256 of the ABI-encoded pool key
    mapping(bytes32 poolId => PoolData poolData) pools;

    mapping(address owner => mapping(address token => mapping(bytes32 salt => uint256))) savedBalances;

    // Extensions must call this function to become registered. The call points are validated against the caller address

    function registerExtension(CallPoints memory expectedCallPoints) external {
        uint8 b;
        assembly ("memory-safe") {
            b := and(shr(160, caller()), 0xff)
        }
        CallPoints memory computed = byteToCallPoints(b);
        if (!computed.eq(expectedCallPoints)) revert FailedRegisterInvalidCallPoints();
        if (isExtensionRegistered[msg.sender]) revert ExtensionAlreadyRegistered();
        isExtensionRegistered[msg.sender] = true;
    }

    error DeltasNotZeroed(uint256 count);

    // The entrypoint for all operations on the core contract
    function lock(bytes calldata data) external onlyProxy returns (bytes memory result) {
        uint256 id;

        assembly ("memory-safe") {
            id := tload(0)
            tstore(0, add(id, 1))
        }

        result = ILocker(msg.sender).locked(id, data);

        uint256 nonzeroDeltaCount;
        assembly ("memory-safe") {
            tstore(0, id)
            nonzeroDeltaCount := tload(add(0x10000000000000000, id))
        }
        if (nonzeroDeltaCount != 0) revert DeltasNotZeroed(nonzeroDeltaCount);
    }
}
