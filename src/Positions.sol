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
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ITokenURIGenerator} from "./interfaces/ITokenURIGenerator.sol";
import {MintableNFT} from "./base/MintableNFT.sol";

contract Positions is UsesCore, PayableMulticallable, SlippageChecker, Permittable, BaseLocker, MintableNFT {
    error DepositFailedDueToSlippage(uint128 liquidity, uint128 minLiquidity);
    error DepositOverflow();

    using CoreLib for ICore;

    constructor(ICore core, ITokenURIGenerator tokenURIGenerator)
        MintableNFT(tokenURIGenerator)
        BaseLocker(core)
        UsesCore(core)
    {}

    function name() public pure override returns (string memory) {
        return "Ekubo Positions";
    }

    function symbol() public pure override returns (string memory) {
        return "ekuPo";
    }

    function getPositionFeesAndLiquidity(uint256 id, PoolKey memory poolKey, Bounds memory bounds)
        external
        view
        returns (uint128 liquidity, uint128 principal0, uint128 principal1, uint128 fees0, uint128 fees1)
    {
        bytes32 poolId = poolKey.toPoolId();
        (SqrtRatio sqrtRatio,,) = core.poolState(poolId);
        bytes32 positionId = PositionKey(bytes32(id), address(this), bounds).toPositionId();
        Position memory position = core.poolPositions(poolId, positionId);

        liquidity = position.liquidity;

        (int128 delta0, int128 delta1) = liquidityDeltaToAmountDelta(
            sqrtRatio,
            -SafeCastLib.toInt128(position.liquidity),
            tickToSqrtRatio(bounds.lower),
            tickToSqrtRatio(bounds.upper)
        );

        (principal0, principal1) = (uint128(-delta0), uint128(-delta1));

        FeesPerLiquidity memory feesPerLiquidityInside = core.getPoolFeesPerLiquidityInside(poolKey, bounds);
        (fees0, fees1) = position.fees(feesPerLiquidityInside);
    }

    function deposit(
        uint256 id,
        PoolKey memory poolKey,
        Bounds memory bounds,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) public payable authorizedForNft(id) returns (uint128 liquidity, uint128 amount0, uint128 amount1) {
        (SqrtRatio sqrtRatio,,) = core.poolState(poolKey.toPoolId());

        liquidity = maxLiquidity(
            sqrtRatio, tickToSqrtRatio(bounds.lower), tickToSqrtRatio(bounds.upper), maxAmount0, maxAmount1
        );

        if (liquidity < minLiquidity) {
            revert DepositFailedDueToSlippage(liquidity, minLiquidity);
        }

        if (liquidity > uint128(type(int128).max)) {
            revert DepositOverflow();
        }

        (amount0, amount1) =
            abi.decode(lock(abi.encode(bytes1(0xdd), msg.sender, id, poolKey, bounds, liquidity)), (uint128, uint128));
    }

    function collectFees(uint256 id, PoolKey memory poolKey, Bounds memory bounds)
        public
        payable
        authorizedForNft(id)
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = collectFees(id, poolKey, bounds, msg.sender);
    }

    function collectFees(uint256 id, PoolKey memory poolKey, Bounds memory bounds, address recipient)
        public
        payable
        authorizedForNft(id)
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = withdraw(id, poolKey, bounds, 0, recipient, true);
    }

    function withdraw(
        uint256 id,
        PoolKey memory poolKey,
        Bounds memory bounds,
        uint128 liquidity,
        address recipient,
        bool withFees
    ) public payable authorizedForNft(id) returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = abi.decode(
            lock(abi.encode(bytes1(0xff), id, poolKey, bounds, liquidity, recipient, withFees)), (uint128, uint128)
        );
    }

    function withdraw(uint256 id, PoolKey memory poolKey, Bounds memory bounds, uint128 liquidity)
        public
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = withdraw(id, poolKey, bounds, liquidity, address(msg.sender), true);
    }

    // Can be used to refund some gas after withdrawing
    // The NFT ID can be re-minted by the original minter after it is burned
    function burn(uint256 id) external payable authorizedForNft(id) {
        _burn(id);
    }

    function maybeInitializePool(PoolKey memory poolKey, int32 tick)
        external
        payable
        returns (bool initialized, SqrtRatio sqrtRatio)
    {
        // the before update position hook shouldn't be taken into account here
        (sqrtRatio,,) = core.poolState(poolKey.toPoolId());
        if (sqrtRatio.isZero()) {
            initialized = true;
            sqrtRatio = core.initializePool(poolKey, tick);
        }
    }

    function mintAndDeposit(
        PoolKey memory poolKey,
        Bounds memory bounds,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) external payable returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1) {
        id = mint();
        (liquidity, amount0, amount1) = deposit(id, poolKey, bounds, maxAmount0, maxAmount1, minLiquidity);
    }

    function mintAndDepositWithSalt(
        bytes32 salt,
        PoolKey memory poolKey,
        Bounds memory bounds,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) external payable returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1) {
        id = mint(salt);
        (liquidity, amount0, amount1) = deposit(id, poolKey, bounds, maxAmount0, maxAmount1, minLiquidity);
    }

    error UnexpectedCallTypeByte(bytes1 b);

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        bytes1 callType = data[0];

        if (callType == 0xdd) {
            (, address caller, uint256 id, PoolKey memory poolKey, Bounds memory bounds, uint128 liquidity) =
                abi.decode(data, (bytes1, address, uint256, PoolKey, Bounds, uint128));

            (int128 delta0, int128 delta1) = core.updatePosition(
                poolKey,
                UpdatePositionParameters({salt: bytes32(id), bounds: bounds, liquidityDelta: int128(liquidity)})
            );

            uint128 amount0 = uint128(delta0);
            uint128 amount1 = uint128(delta1);
            pay(caller, poolKey.token0, amount0);
            pay(caller, poolKey.token1, amount1);

            result = abi.encode(amount0, amount1);
        } else if (callType == 0xff) {
            (
                ,
                uint256 id,
                PoolKey memory poolKey,
                Bounds memory bounds,
                uint128 liquidity,
                address recipient,
                bool withFees
            ) = abi.decode(data, (bytes1, uint256, PoolKey, Bounds, uint128, address, bool));

            uint128 amount0;
            uint128 amount1;

            // collect first in case we are withdrawing the entire amount
            if (withFees) {
                (amount0, amount1) = core.collectFees(poolKey, bytes32(id), bounds);
            }

            if (liquidity != 0) {
                (int128 delta0, int128 delta1) = core.updatePosition(
                    poolKey,
                    UpdatePositionParameters({salt: bytes32(id), bounds: bounds, liquidityDelta: -int128(liquidity)})
                );

                amount0 += uint128(-delta0);
                amount1 += uint128(-delta1);
            }

            withdraw(poolKey.token0, amount0, recipient);
            withdraw(poolKey.token1, amount1, recipient);

            result = abi.encode(amount0, amount1);
        } else {
            revert UnexpectedCallTypeByte(callType);
        }
    }
}
