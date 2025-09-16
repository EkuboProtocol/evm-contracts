// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore, UpdatePositionParameters} from "./interfaces/ICore.sol";
import {IPositions} from "./interfaces/IPositions.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PositionKey, Bounds} from "./types/positionKey.sol";
import {FeesPerLiquidity} from "./types/feesPerLiquidity.sol";
import {Position} from "./types/position.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {maxLiquidity, liquidityDeltaToAmountDelta} from "./math/liquidity.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {BaseNonfungibleToken} from "./base/BaseNonfungibleToken.sol";
import {computeFee} from "./math/fee.sol";

/// @title Ekubo Protocol Positions
/// @author Moody Salem <moody@ekubo.org>
/// @notice Tracks liquidity positions in Ekubo Protocol as NFTs
/// @dev Manages liquidity positions, fee collection, and protocol fees
contract Positions is IPositions, UsesCore, PayableMulticallable, BaseLocker, BaseNonfungibleToken {
    /// @notice Protocol fee rate for swaps (as a fraction of 2^64)
    uint64 public immutable swapProtocolFeeX64;

    /// @notice Denominator for withdrawal protocol fee calculation
    uint64 public immutable withdrawalProtocolFeeDenominator;

    using CoreLib for ICore;

    /// @notice Constructs the Positions contract
    /// @param core The core contract instance
    /// @param owner The owner of the contract (for access control)
    /// @param _swapProtocolFeeX64 Protocol fee rate for swaps
    /// @param _withdrawalProtocolFeeDenominator Denominator for withdrawal protocol fee
    constructor(ICore core, address owner, uint64 _swapProtocolFeeX64, uint64 _withdrawalProtocolFeeDenominator)
        BaseNonfungibleToken(owner)
        BaseLocker(core)
        UsesCore(core)
    {
        swapProtocolFeeX64 = _swapProtocolFeeX64;
        withdrawalProtocolFeeDenominator = _withdrawalProtocolFeeDenominator;
    }

    /// @notice Gets the liquidity, principal amounts, and accumulated fees for a position
    /// @param id The NFT token ID representing the position
    /// @param poolKey Pool key identifying the pool
    /// @param bounds Price bounds for the position
    /// @return liquidity Current liquidity in the position
    /// @return principal0 Principal amount of token0 in the position
    /// @return principal1 Principal amount of token1 in the position
    /// @return fees0 Accumulated fees in token0
    /// @return fees1 Accumulated fees in token1
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

    /// @notice Deposits tokens into a liquidity position
    /// @param id The NFT token ID representing the position
    /// @param poolKey Pool key identifying the pool
    /// @param bounds Price bounds for the position
    /// @param maxAmount0 Maximum amount of token0 to deposit
    /// @param maxAmount1 Maximum amount of token1 to deposit
    /// @param minLiquidity Minimum liquidity to receive (for slippage protection)
    /// @return liquidity Amount of liquidity added to the position
    /// @return amount0 Actual amount of token0 deposited
    /// @return amount1 Actual amount of token1 deposited
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

    /// @notice Collects accumulated fees from a position to msg.sender
    /// @param id The NFT token ID representing the position
    /// @param poolKey Pool key identifying the pool
    /// @param bounds Price bounds for the position
    /// @return amount0 Amount of token0 fees collected
    /// @return amount1 Amount of token1 fees collected
    function collectFees(uint256 id, PoolKey memory poolKey, Bounds memory bounds)
        public
        payable
        authorizedForNft(id)
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = collectFees(id, poolKey, bounds, msg.sender);
    }

    /// @notice Collects accumulated fees from a position to a specified recipient
    /// @param id The NFT token ID representing the position
    /// @param poolKey Pool key identifying the pool
    /// @param bounds Price bounds for the position
    /// @param recipient Address to receive the collected fees
    /// @return amount0 Amount of token0 fees collected
    /// @return amount1 Amount of token1 fees collected
    function collectFees(uint256 id, PoolKey memory poolKey, Bounds memory bounds, address recipient)
        public
        payable
        authorizedForNft(id)
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = withdraw(id, poolKey, bounds, 0, recipient, true);
    }

    /// @notice Withdraws liquidity from a position
    /// @param id The NFT token ID representing the position
    /// @param poolKey Pool key identifying the pool
    /// @param bounds Price bounds for the position
    /// @param liquidity Amount of liquidity to withdraw
    /// @param recipient Address to receive the withdrawn tokens
    /// @param withFees Whether to also collect accumulated fees
    /// @return amount0 Amount of token0 withdrawn
    /// @return amount1 Amount of token1 withdrawn
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

    /// @notice Withdraws liquidity from a position to msg.sender with fees
    /// @param id The NFT token ID representing the position
    /// @param poolKey Pool key identifying the pool
    /// @param bounds Price bounds for the position
    /// @param liquidity Amount of liquidity to withdraw
    /// @return amount0 Amount of token0 withdrawn
    /// @return amount1 Amount of token1 withdrawn
    function withdraw(uint256 id, PoolKey memory poolKey, Bounds memory bounds, uint128 liquidity)
        public
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = withdraw(id, poolKey, bounds, liquidity, address(msg.sender), true);
    }

    /// @notice Initializes a pool if it hasn't been initialized yet
    /// @param poolKey Pool key identifying the pool
    /// @param tick Initial tick for the pool if initialization is needed
    /// @return initialized Whether the pool was initialized by this call
    /// @return sqrtRatio The sqrt price ratio of the pool (existing or newly set)
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

    /// @notice Mints a new NFT and deposits liquidity into it
    /// @param poolKey Pool key identifying the pool
    /// @param bounds Price bounds for the position
    /// @param maxAmount0 Maximum amount of token0 to deposit
    /// @param maxAmount1 Maximum amount of token1 to deposit
    /// @param minLiquidity Minimum liquidity to receive (for slippage protection)
    /// @return id The newly minted NFT token ID
    /// @return liquidity Amount of liquidity added to the position
    /// @return amount0 Actual amount of token0 deposited
    /// @return amount1 Actual amount of token1 deposited
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

    /// @notice Mints a new NFT with a specific salt and deposits liquidity into it
    /// @param salt Salt for deterministic NFT ID generation
    /// @param poolKey Pool key identifying the pool
    /// @param bounds Price bounds for the position
    /// @param maxAmount0 Maximum amount of token0 to deposit
    /// @param maxAmount1 Maximum amount of token1 to deposit
    /// @param minLiquidity Minimum liquidity to receive (for slippage protection)
    /// @return id The newly minted NFT token ID
    /// @return liquidity Amount of liquidity added to the position
    /// @return amount0 Actual amount of token0 deposited
    /// @return amount1 Actual amount of token1 deposited
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

    /// @notice Withdraws accumulated protocol fees (only callable by owner)
    /// @param token0 Address of token0
    /// @param token1 Address of token1
    /// @param amount0 Amount of token0 fees to withdraw
    /// @param amount1 Amount of token1 fees to withdraw
    /// @param recipient Address to receive the protocol fees
    function withdrawProtocolFees(address token0, address token1, uint128 amount0, uint128 amount1, address recipient)
        external
        payable
        onlyOwner
    {
        lock(abi.encode(bytes1(0xee), token0, token1, amount0, amount1, recipient));
    }

    /// @notice Gets the accumulated protocol fees for a token pair
    /// @param token0 Address of token0
    /// @param token1 Address of token1
    /// @return amount0 Amount of token0 protocol fees
    /// @return amount1 Amount of token1 protocol fees
    function getProtocolFees(address token0, address token1) external view returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = core.savedBalances(address(this), token0, token1, bytes32(0));
    }

    /// @notice Handles lock callback data for position operations
    /// @dev Internal function that processes different types of position operations
    /// @param data Encoded operation data
    /// @return result Encoded result data
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        bytes1 callType = data[0];

        if (callType == 0xee) {
            (, address token0, address token1, uint128 amount0, uint128 amount1, address recipient) =
                abi.decode(data, (bytes1, address, address, uint128, uint128, address));

            core.updateSavedBalances(token0, token1, bytes32(0), -int256(uint256(amount0)), -int256(uint256(amount1)));

            withdraw(token0, amount0, recipient);
            withdraw(token1, amount1, recipient);
        } else if (callType == 0xdd) {
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
                if (swapProtocolFeeX64 != 0) {
                    uint128 swapProtocolFee0;
                    uint128 swapProtocolFee1;

                    swapProtocolFee0 = computeFee(amount0, swapProtocolFeeX64);
                    swapProtocolFee1 = computeFee(amount1, swapProtocolFeeX64);

                    if (swapProtocolFee0 != 0 || swapProtocolFee1 != 0) {
                        core.updateSavedBalances(
                            poolKey.token0,
                            poolKey.token1,
                            bytes32(0),
                            int128(swapProtocolFee0),
                            int128(swapProtocolFee1)
                        );

                        amount0 -= swapProtocolFee0;
                        amount1 -= swapProtocolFee1;
                    }
                }
            }

            if (liquidity != 0) {
                (int128 delta0, int128 delta1) = core.updatePosition(
                    poolKey,
                    UpdatePositionParameters({salt: bytes32(id), bounds: bounds, liquidityDelta: -int128(liquidity)})
                );

                uint64 fee = poolKey.fee();

                uint128 withdrawalFee0;
                uint128 withdrawalFee1;
                if (fee != 0 && withdrawalProtocolFeeDenominator != 0) {
                    withdrawalFee0 = computeFee(uint128(-delta0), fee / withdrawalProtocolFeeDenominator);
                    withdrawalFee1 = computeFee(uint128(-delta1), fee / withdrawalProtocolFeeDenominator);

                    if (withdrawalFee0 != 0 || withdrawalFee1 != 0) {
                        // we know cast won't overflow because delta0 and delta1 were originally int128
                        core.updateSavedBalances(
                            poolKey.token0, poolKey.token1, bytes32(0), int128(withdrawalFee0), int128(withdrawalFee1)
                        );
                    }
                }

                amount0 += uint128(-delta0) - withdrawalFee0;
                amount1 += uint128(-delta1) - withdrawalFee1;
            }

            withdraw(poolKey.token0, amount0, recipient);
            withdraw(poolKey.token1, amount1, recipient);

            result = abi.encode(amount0, amount1);
        } else {
            revert UnexpectedCallTypeByte(callType);
        }
    }
}
