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
import {TWAMM, UpdateSaleRateParams, CollectProceedsParams} from "./extensions/TWAMM.sol";
import {MintableNFT} from "./base/MintableNFT.sol";

contract Orders is UsesCore, PayableMulticallable, SlippageChecker, Permittable, BaseLocker, MintableNFT {
    error DepositFailedDueToSlippage(uint128 liquidity, uint128 minLiquidity);
    error DepositOverflow();

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

    // todo
    function handleLockData(uint256 id, bytes memory data) internal override returns (bytes memory result) {}
}
