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

interface IForwardee {
    function forwarded(address locker, uint256 id, bytes calldata data) external returns (bytes memory);
}

contract Core is OwnedUpgradeable {
    using LibBitmap for LibBitmap.Bitmap;

    struct TickInfo {
        int128 liquidityDelta;
        uint128 liquidityNet;
    }

    struct PoolPrice {
        uint192 sqrtRatio;
        int32 tick;
    }

    // The total fees per liquidity for each token
    struct FeesPerLiquidity {
        uint256 token0_fees_per_liquidity;
        uint256 token1_fees_per_liquidity;
    }

    error FailedRegisterInvalidCallPoints();
    error ExtensionAlreadyRegistered();

    mapping(address extension => bool isRegistered) public isExtensionRegistered;
    mapping(address token => uint256 amountCollected) public protocolFeesCollected;

    // Keyed by the pool ID, which is the keccak256 of the ABI-encoded pool key
    mapping(bytes32 poolId => PoolPrice price) public poolPrice;
    mapping(bytes32 poolId => uint128 liquidity) public poolLiquidity;
    mapping(bytes32 poolId => FeesPerLiquidity feesPerLiquidity) public poolFees;
    mapping(bytes32 poolId => mapping(bytes32 positionId => Position position)) public positions;
    mapping(bytes32 poolId => mapping(int32 tick => TickInfo tickInfo)) public ticks;
    mapping(bytes32 poolId => LibBitmap.Bitmap) initializedTickBitmaps;

    // Balances saved for later
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

    error LockerOnly();

    function requireLocker() private view returns (uint256 id, address locker) {
        assembly ("memory-safe") {
            id := sub(tload(0), 1)
            locker := tload(add(0x100000000, id))
        }
        if (locker != msg.sender) revert LockerOnly();
    }

    function accountDelta(uint256 lockerId, address token, int128 delta) private {
        bytes32 slot = keccak256(abi.encode(lockerId, token));

        int128 current;
        assembly ("memory-safe") {
            current := tload(slot)
        }

        int128 next = current + delta;
        if (current == 0 && next != 0) {
            assembly ("memory-safe") {
                let nzdCountSlot := add(lockerId, 0x200000000)

                tstore(nzdCountSlot, add(tload(nzdCountSlot), 1))
            }
        } else if (current != 0 && next == 0) {
            assembly ("memory-safe") {
                let nzdCountSlot := add(lockerId, 0x200000000)

                tstore(nzdCountSlot, sub(tload(nzdCountSlot), 1))
            }
        }

        assembly ("memory-safe") {
            tstore(slot, next)
        }
    }

    error DeltasNotZeroed(uint256 count);

    // The entrypoint for all operations on the core contract
    function lock(bytes calldata data) external onlyProxy returns (bytes memory result) {
        uint256 id;

        assembly ("memory-safe") {
            id := tload(0)
            // store the count
            tstore(0, add(id, 1))
            // store the address of the locker
            tstore(add(0x100000000, id), caller())
        }

        // We make the assumption that this code can never be called recursively this many times, causing storage slots to overlap
        // This is just the codified assumption
        assert(id < type(uint32).max);

        result = ILocker(msg.sender).locked(id, data);

        uint256 nonzeroDeltaCount;
        assembly ("memory-safe") {
            // reset the locker id
            tstore(0, id)
            // remove the address
            tstore(add(0x100000000, id), 0)
            // load the delta count which should already be reset to zero
            nonzeroDeltaCount := tload(add(0x200000000, id))
        }

        if (nonzeroDeltaCount != 0) revert DeltasNotZeroed(nonzeroDeltaCount);
    }

    function forward(address to, bytes calldata data) external returns (bytes memory result) {
        (uint256 id, address locker) = requireLocker();

        // update this lock's locker to the forwarded address for the duration of the forwarded
        // call, meaning only the forwarded address can update state
        assembly ("memory-safe") {
            tstore(add(0x100000000, id), to)
        }

        result = IForwardee(to).forwarded(locker, id, data);

        assembly ("memory-safe") {
            tstore(add(0x100000000, id), locker)
        }
    }
}
