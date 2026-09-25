// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {
    AUCTION_COLLECT_RENT,
    AUCTION_COLLECT_SWAP_FEES,
    AUCTION_UPDATE_BID
} from "../interfaces/extensions/IContinuousAuction.sol";
import {ICore} from "../interfaces/ICore.sol";
import {FlashAccountantLib} from "./FlashAccountantLib.sol";
import {CoreStorageLayout} from "./CoreStorageLayout.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PositionId} from "../types/positionId.sol";
import {SwapParameters} from "../types/swapParameters.sol";

/// @title Continuous Auction Library
/// @notice Forward-call encoders for the continuous auction extension. Every call runs inside a Core lock; the
/// forwarding locker settles the resulting debts or withdraws the resulting credits.
library ContinuousAuctionLib {
    using ExposedStorageLib for *;
    using FlashAccountantLib for *;

    /// @notice The identity a bid is keyed by: the forwarding locker and a salt of its choosing.
    function bidderId(address locker, bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(locker, salt));
    }

    /// @notice Executes a forwarded swap through Core.
    function swap(ICore core, address auction, PoolKey memory poolKey, SwapParameters params)
        internal
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        bytes memory data = new bytes(128);
        assembly ("memory-safe") {
            let ptr := add(data, 0x20)
            mstore(ptr, mload(poolKey))
            mstore(add(ptr, 0x20), mload(add(poolKey, 0x20)))
            mstore(add(ptr, 0x40), mload(add(poolKey, 0x40)))
            mstore(add(ptr, 0x60), params)
        }

        bytes memory result = core.forward(auction, data);
        assembly ("memory-safe") {
            balanceUpdate := mload(add(result, 0x20))
            stateAfter := mload(add(result, 0x40))
        }
    }

    /// @notice Sets the locker's bid for the pool from the next second on. See ContinuousAuction.
    /// @return delta Bid-token debt of the locker: positive to pay, negative to withdraw.
    function updateBid(
        ICore core,
        address auction,
        PoolKey memory poolKey,
        bytes32 salt,
        uint96 rate,
        uint64 end,
        address executor,
        uint32 fee
    ) internal returns (int256 delta) {
        delta = abi.decode(
            core.forward(auction, abi.encode(AUCTION_UPDATE_BID, poolKey, salt, rate, end, executor, fee)), (int256)
        );
    }

    /// @notice Collects the rent of a position owned by the locker. The locker withdraws the bid token.
    function collectRent(ICore core, address auction, PoolKey memory poolKey, PositionId positionId)
        internal
        returns (uint256 amount)
    {
        amount = abi.decode(core.forward(auction, abi.encode(AUCTION_COLLECT_RENT, poolKey, positionId)), (uint256));
    }

    /// @notice Collects the swap fees earned by the locker's bid. The locker withdraws the pool tokens.
    function collectSwapFees(ICore core, address auction, PoolKey memory poolKey, bytes32 salt)
        internal
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = abi.decode(
            core.forward(auction, abi.encode(AUCTION_COLLECT_SWAP_FEES, poolKey, salt)), (uint128, uint128)
        );
    }

    /// @notice Liquidity of a Core position.
    function positionLiquidity(ICore core, PoolId poolId, address owner, PositionId positionId)
        internal
        view
        returns (uint128)
    {
        return uint128(uint256(core.sload(CoreStorageLayout.poolPositionsSlot(poolId, owner, positionId))) >> 128);
    }
}
