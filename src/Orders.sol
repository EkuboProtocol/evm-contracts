// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ERC721} from "solady/tokens/ERC721.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore, UpdatePositionParameters} from "./interfaces/ICore.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PositionKey, Bounds} from "./types/positionKey.sol";
import {FeesPerLiquidity} from "./types/feesPerLiquidity.sol";
import {Position} from "./types/position.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {maxLiquidity, liquidityDeltaToAmountDelta} from "./math/liquidity.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {Permittable} from "./base/Permittable.sol";
import {SlippageChecker} from "./base/SlippageChecker.sol";
import {ITokenURIGenerator} from "./interfaces/ITokenURIGenerator.sol";
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {TWAMM, OrderKey, UpdateSaleRateParams, CollectProceedsParams} from "./extensions/TWAMM.sol";
import {computeSaleRate} from "./math/twamm.sol";
import {MintableNFT} from "./base/MintableNFT.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract Orders is UsesCore, PayableMulticallable, SlippageChecker, Permittable, BaseLocker, MintableNFT {
    error InvalidDuration();
    error OrderAlreadyEnded();
    error MaxSaleRateExceeded();

    using CoreLib for ICore;

    TWAMM public immutable twamm;

    constructor(ICore core, TWAMM _twamm, ITokenURIGenerator tokenURIGenerator)
        MintableNFT(tokenURIGenerator)
        BaseLocker(core)
        UsesCore(core)
    {
        twamm = _twamm;
    }

    function name() public pure override returns (string memory) {
        return "Ekubo DCA Orders";
    }

    function symbol() public pure override returns (string memory) {
        return "ekuOrd";
    }

    function increaseSellAmount(
        uint256 id,
        uint112 amount,
        address sellToken,
        address buyToken,
        uint64 fee,
        uint256 startTime,
        uint256 endTime,
        uint112 maxSaleRate
    ) public returns (uint112 saleRate) {
        if (endTime <= startTime || endTime - startTime > type(uint32).max) {
            revert InvalidDuration();
        }

        if (endTime <= block.timestamp) revert OrderAlreadyEnded();

        saleRate = computeSaleRate(amount, uint32(endTime - FixedPointMathLib.max(block.timestamp, startTime)));

        if (saleRate > maxSaleRate) {
            revert MaxSaleRateExceeded();
        }

        revert("todo");
    }

    function collectProceeds(
        uint256 id,
        address sellToken,
        address buyToken,
        uint64 fee,
        uint256 startTime,
        uint256 endTime
    ) public returns (uint128 proceeds) {
        revert("todo");
    }

    function decreaseSaleRate(
        uint256 id,
        uint112 saleRateDecrease,
        address sellToken,
        address buyToken,
        uint64 fee,
        uint256 startTime,
        uint256 endTime,
        uint112 minRefund
    ) public returns (uint112 refund) {
        revert("todo");
    }

    // todo
    function handleLockData(uint256 id, bytes memory data) internal override returns (bytes memory result) {}
}
