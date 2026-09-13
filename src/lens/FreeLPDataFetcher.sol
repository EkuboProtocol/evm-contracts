// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {QuoteDataFetcher} from "./QuoteDataFetcher.sol";
import {TokenDataFetcher} from "./TokenDataFetcher.sol";
import {ICore} from "../interfaces/ICore.sol";

import {FreeLP} from "../FreeLP.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";
import {Position} from "../types/position.sol";
import {createPositionId} from "../types/positionId.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {liquidityDeltaToAmountDelta} from "../math/liquidity.sol";

/// @notice Complete owned LP position snapshots without an indexer or per-position RPC calls.
contract FreeLPDataFetcher is QuoteDataFetcher, TokenDataFetcher {
    using CoreLib for ICore;

    struct Amounts {
        uint128 liquidity;
        uint128 principal0;
        uint128 principal1;
        uint128 fees0;
        uint128 fees1;
    }

    constructor(ICore core) QuoteDataFetcher(core) {}

    struct OwnedPosition {
        uint256 id;
        FreeLP.Descriptor descriptor;
        Amounts amounts;
        uint256 sqrtRatio;
        string metadata;
    }

    function descriptor(FreeLP manager, uint256 id) public view returns (FreeLP.Descriptor memory d) {
        PoolId poolId;
        (poolId, d.tickLower, d.tickUpper) = manager.position(id);
        (d.poolKey.token0, d.poolKey.token1, d.poolKey.config) = manager.POOL_KEY_INDEX().poolKeyById(poolId);
    }

    function poolState(FreeLP manager, PoolKey memory key)
        public
        view
        returns (uint256 sqrtRatio, int32 tick, uint128 liquidity)
    {
        SqrtRatio ratio;
        (ratio, tick, liquidity) = manager.CORE().poolState(key.toPoolId()).parse();
        sqrtRatio = ratio.toFixed();
    }

    function positionAmounts(FreeLP manager, uint256 id) public view returns (Amounts memory) {
        return _positionAmounts(manager.CORE(), manager, id, descriptor(manager, id));
    }

    function _positionAmounts(ICore core, FreeLP manager, uint256 id, FreeLP.Descriptor memory d)
        private
        view
        returns (Amounts memory a)
    {
        PoolId poolId = d.poolKey.toPoolId();
        Position memory p = core.poolPositions(
            poolId, address(manager), createPositionId(bytes24(uint192(id)), d.tickLower, d.tickUpper)
        );
        if (p.liquidity > uint128(type(int128).max)) revert FreeLP.InvalidValue();
        a.liquidity = p.liquidity;
        (int128 delta0, int128 delta1) = liquidityDeltaToAmountDelta(
            core.poolState(poolId).sqrtRatio(),
            -int128(p.liquidity),
            tickToSqrtRatio(d.tickLower),
            tickToSqrtRatio(d.tickUpper)
        );
        (a.principal0, a.principal1) = (uint128(-delta0), uint128(-delta1));
        FeesPerLiquidity memory f = d.poolKey.config.isStableswap()
            ? core.getPoolFeesPerLiquidity(poolId)
            : core.getPoolFeesPerLiquidityInside(poolId, d.tickLower, d.tickUpper);
        (a.fees0, a.fees1) = p.fees(f);
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
            FreeLP.Descriptor memory d = descriptor(manager, id);
            (uint256 sqrtRatio,,) = poolState(manager, d.poolKey);
            result[i] =
                OwnedPosition(id, d, _positionAmounts(manager.CORE(), manager, id, d), sqrtRatio, manager.tokenURI(id));
        }
    }
}
