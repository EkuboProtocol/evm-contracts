// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IPositions} from "./interfaces/IPositions.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PositionId, createPositionId} from "./types/positionId.sol";
import {FeesPerLiquidity} from "./types/feesPerLiquidity.sol";
import {Position} from "./types/position.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {maxLiquidity, liquidityDeltaToAmountDelta} from "./math/liquidity.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {BaseNonfungibleToken} from "./base/BaseNonfungibleToken.sol";
import {computeFee} from "./math/fee.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";

/// @title Ekubo Protocol Positions
/// @author Moody Salem <moody@ekubo.org>
/// @notice Tracks liquidity positions in Ekubo Protocol as NFTs
/// @dev Manages liquidity positions, fee collection, and protocol fees
contract Positions is IPositions, UsesCore, PayableMulticallable, BaseLocker, BaseNonfungibleToken {
    /// @notice Protocol fee rate for swaps (as a fraction of 2^64)
    uint64 public immutable SWAP_PROTOCOL_FEE_X64;

    /// @notice Denominator for withdrawal protocol fee calculation
    uint64 public immutable WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR;

    using CoreLib for *;
    using FlashAccountantLib for *;

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
        SWAP_PROTOCOL_FEE_X64 = _swapProtocolFeeX64;
        WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR = _withdrawalProtocolFeeDenominator;
    }

    /// @inheritdoc IPositions
    function getPositionFeesAndLiquidity(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        external
        view
        returns (uint128 liquidity, uint128 principal0, uint128 principal1, uint128 fees0, uint128 fees1)
    {
        bytes32 poolId = poolKey.toPoolId();
        SqrtRatio sqrtRatio = CORE.poolState(poolId).sqrtRatio();
        PositionId positionId =
            createPositionId({_salt: bytes24(uint192(id)), _tickLower: tickLower, _tickUpper: tickUpper});
        Position memory position = CORE.poolPositions(poolId, address(this), positionId);

        liquidity = position.liquidity;

        (int128 delta0, int128 delta1) = liquidityDeltaToAmountDelta(
            sqrtRatio, -SafeCastLib.toInt128(position.liquidity), tickToSqrtRatio(tickLower), tickToSqrtRatio(tickUpper)
        );

        (principal0, principal1) = (uint128(-delta0), uint128(-delta1));

        FeesPerLiquidity memory feesPerLiquidityInside =
            CORE.getPoolFeesPerLiquidityInside(poolKey, tickLower, tickUpper);
        (fees0, fees1) = position.fees(feesPerLiquidityInside);
    }

    /// @inheritdoc IPositions
    function deposit(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) public payable authorizedForNft(id) returns (uint128 liquidity, uint128 amount0, uint128 amount1) {
        SqrtRatio sqrtRatio = CORE.poolState(poolKey.toPoolId()).sqrtRatio();

        liquidity =
            maxLiquidity(sqrtRatio, tickToSqrtRatio(tickLower), tickToSqrtRatio(tickUpper), maxAmount0, maxAmount1);

        if (liquidity < minLiquidity) {
            revert DepositFailedDueToSlippage(liquidity, minLiquidity);
        }

        if (liquidity > uint128(type(int128).max)) {
            revert DepositOverflow();
        }

        (amount0, amount1) = abi.decode(
            lock(abi.encode(bytes1(0xdd), msg.sender, id, poolKey, tickLower, tickUpper, liquidity)), (uint128, uint128)
        );
    }

    /// @inheritdoc IPositions
    function collectFees(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        public
        payable
        authorizedForNft(id)
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = collectFees(id, poolKey, tickLower, tickUpper, msg.sender);
    }

    /// @inheritdoc IPositions
    function collectFees(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper, address recipient)
        public
        payable
        authorizedForNft(id)
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = withdraw(id, poolKey, tickLower, tickUpper, 0, recipient, true);
    }

    /// @inheritdoc IPositions
    function withdraw(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 liquidity,
        address recipient,
        bool withFees
    ) public payable authorizedForNft(id) returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = abi.decode(
            lock(abi.encode(bytes1(0xff), id, poolKey, tickLower, tickUpper, liquidity, recipient, withFees)),
            (uint128, uint128)
        );
    }

    /// @inheritdoc IPositions
    function withdraw(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper, uint128 liquidity)
        public
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = withdraw(id, poolKey, tickLower, tickUpper, liquidity, address(msg.sender), true);
    }

    /// @inheritdoc IPositions
    function maybeInitializePool(PoolKey memory poolKey, int32 tick)
        external
        payable
        returns (bool initialized, SqrtRatio sqrtRatio)
    {
        // the before update position hook shouldn't be taken into account here
        sqrtRatio = CORE.poolState(poolKey.toPoolId()).sqrtRatio();
        if (sqrtRatio.isZero()) {
            initialized = true;
            sqrtRatio = CORE.initializePool(poolKey, tick);
        }
    }

    /// @inheritdoc IPositions
    function mintAndDeposit(
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) external payable returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1) {
        id = mint();
        (liquidity, amount0, amount1) = deposit(id, poolKey, tickLower, tickUpper, maxAmount0, maxAmount1, minLiquidity);
    }

    /// @inheritdoc IPositions
    function mintAndDepositWithSalt(
        bytes32 salt,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) external payable returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1) {
        id = mint(salt);
        (liquidity, amount0, amount1) = deposit(id, poolKey, tickLower, tickUpper, maxAmount0, maxAmount1, minLiquidity);
    }

    /// @inheritdoc IPositions
    function withdrawProtocolFees(address token0, address token1, uint128 amount0, uint128 amount1, address recipient)
        external
        payable
        onlyOwner
    {
        lock(abi.encode(bytes1(0xee), token0, token1, amount0, amount1, recipient));
    }

    /// @inheritdoc IPositions
    function getProtocolFees(address token0, address token1) external view returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = CORE.savedBalances(address(this), token0, token1, bytes32(0));
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

            CORE.updateSavedBalances(token0, token1, bytes32(0), -int256(uint256(amount0)), -int256(uint256(amount1)));

            ACCOUNTANT.withdrawTwo(token0, token1, recipient, amount0, amount1);
        } else if (callType == 0xdd) {
            (, address caller, uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper, uint128 liquidity)
            = abi.decode(data, (bytes1, address, uint256, PoolKey, int32, int32, uint128));

            (int128 delta0, int128 delta1) = CORE.updatePosition(
                poolKey,
                createPositionId({_salt: bytes24(uint192(id)), _tickLower: tickLower, _tickUpper: tickUpper}),
                int128(liquidity)
            );

            uint128 amount0 = uint128(delta0);
            uint128 amount1 = uint128(delta1);

            // Use multi-token payment for ERC20-only pools, fall back to individual payments for native token pools
            if (poolKey.token0 != NATIVE_TOKEN_ADDRESS) {
                ACCOUNTANT.payTwoFrom(caller, poolKey.token0, poolKey.token1, amount0, amount1);
            } else {
                if (amount0 != 0) {
                    SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount0);
                }
                if (amount1 != 0) {
                    ACCOUNTANT.payFrom(caller, poolKey.token1, amount1);
                }
            }

            result = abi.encode(amount0, amount1);
        } else if (callType == 0xff) {
            (
                ,
                uint256 id,
                PoolKey memory poolKey,
                int32 tickLower,
                int32 tickUpper,
                uint128 liquidity,
                address recipient,
                bool withFees
            ) = abi.decode(data, (bytes1, uint256, PoolKey, int32, int32, uint128, address, bool));

            uint128 amount0;
            uint128 amount1;

            // collect first in case we are withdrawing the entire amount
            if (withFees) {
                (amount0, amount1) = CORE.collectFees(
                    poolKey,
                    createPositionId({_salt: bytes24(uint192(id)), _tickLower: tickLower, _tickUpper: tickUpper})
                );
                if (SWAP_PROTOCOL_FEE_X64 != 0) {
                    uint128 swapProtocolFee0;
                    uint128 swapProtocolFee1;

                    swapProtocolFee0 = computeFee(amount0, SWAP_PROTOCOL_FEE_X64);
                    swapProtocolFee1 = computeFee(amount1, SWAP_PROTOCOL_FEE_X64);

                    if (swapProtocolFee0 != 0 || swapProtocolFee1 != 0) {
                        CORE.updateSavedBalances(
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
                (int128 delta0, int128 delta1) = CORE.updatePosition(
                    poolKey,
                    createPositionId({_salt: bytes24(uint192(id)), _tickLower: tickLower, _tickUpper: tickUpper}),
                    -int128(liquidity)
                );

                uint64 fee = poolKey.fee();

                uint128 withdrawalFee0;
                uint128 withdrawalFee1;
                if (fee != 0 && WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR != 0) {
                    withdrawalFee0 = computeFee(uint128(-delta0), fee / WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR);
                    withdrawalFee1 = computeFee(uint128(-delta1), fee / WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR);

                    if (withdrawalFee0 != 0 || withdrawalFee1 != 0) {
                        // we know cast won't overflow because delta0 and delta1 were originally int128
                        CORE.updateSavedBalances(
                            poolKey.token0, poolKey.token1, bytes32(0), int128(withdrawalFee0), int128(withdrawalFee1)
                        );
                    }
                }

                amount0 += uint128(-delta0) - withdrawalFee0;
                amount1 += uint128(-delta1) - withdrawalFee1;
            }

            CORE.withdrawTwo(poolKey.token0, poolKey.token1, recipient, amount0, amount1);

            result = abi.encode(amount0, amount1);
        } else {
            revert UnexpectedCallTypeByte(callType);
        }
    }
}
