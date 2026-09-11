// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {QuoteDataFetcher} from "./QuoteDataFetcher.sol";
import {TokenDataFetcher} from "./TokenDataFetcher.sol";
import {ICore} from "../interfaces/ICore.sol";

import {FreeLP} from "../FreeLP.sol";

/// @notice Complete owned LP position snapshots without an indexer or per-position RPC calls.
contract FreeLPDataFetcher is QuoteDataFetcher, TokenDataFetcher {
    constructor(ICore core) QuoteDataFetcher(core) {}

    struct OwnedPosition {
        uint256 id;
        FreeLP.Descriptor descriptor;
        FreeLP.Amounts amounts;
        uint256 sqrtRatio;
        string metadata;
    }

    /// @dev Results share one block; order is unspecified. Large portfolios remain subject to
    ///      the RPC provider's eth_call gas and response limits. No data is silently truncated.
    function ownedPositions(FreeLP manager, address holder)
        external
        view
        returns (uint256 chainId, bool managerDeployed, OwnedPosition[] memory result)
    {
        chainId = block.chainid;
        managerDeployed = address(manager).code.length != 0;
        if (!managerDeployed || holder == address(0)) return (chainId, managerDeployed, new OwnedPosition[](0));
        uint256 length = manager.balanceOf(holder);
        result = new OwnedPosition[](length);
        for (uint256 i; i < length; ++i) {
            uint256 id = manager.tokenOfOwnerByIndex(holder, i);
            FreeLP.Descriptor memory d = manager.descriptor(id);
            (uint256 sqrtRatio,,) = manager.poolState(d.poolKey);
            result[i] = OwnedPosition(id, d, manager.positionAmounts(id), sqrtRatio, manager.tokenURI(id));
        }
    }
}
