// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Positions} from "./Positions.sol";
import {ContinuousAuction} from "./extensions/ContinuousAuction.sol";
import {ICore} from "./interfaces/ICore.sol";
import {PoolKey} from "./types/poolKey.sol";
import {createPositionId} from "./types/positionId.sol";

/// @notice Position NFTs with owner/approved-operator collection of continuous-auction rent.
/// @dev Principal management uses the standard Positions API, with no protocol fees. Auction fees remain
/// claimable after removing all liquidity and travel with the NFT on transfer. Collect them before burning.
contract AuctionPositions is Positions {
    ContinuousAuction public immutable auction;

    error InvalidAuctionPool();

    constructor(ICore core, ContinuousAuction _auction, address owner) Positions(core, owner, 0, 0) {
        auction = _auction;
    }

    /// @notice Collects bid-token fees to recipient. Only the NFT owner or an approved operator may collect.
    function collectAuctionFees(uint256 id, PoolKey calldata key, int32 lower, int32 upper, address recipient)
        public
        authorizedForNft(id)
        returns (uint256 amount)
    {
        if (key.config.extension() != address(auction)) revert InvalidAuctionPool();
        amount = auction.collectFees(key, createPositionId(bytes24(uint192(id)), lower, upper), recipient);
    }

    function collectAuctionFees(uint256 id, PoolKey calldata key, int32 lower, int32 upper)
        external
        returns (uint256 amount)
    {
        return collectAuctionFees(id, key, lower, upper, msg.sender);
    }
}
