// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./BaseLocker.sol";
import {BaseNonfungibleToken} from "./BaseNonfungibleToken.sol";
import {PayableMulticallable} from "./PayableMulticallable.sol";
import {UsesCore} from "./UsesCore.sol";
import {ICore} from "../interfaces/ICore.sol";
import {IPositions} from "../interfaces/IPositions.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {FlashAccountantLib} from "../libraries/FlashAccountantLib.sol";
import {maxLiquidity} from "../math/liquidity.sol";
import {NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolState} from "../types/poolState.sol";
import {PositionId, createPositionId} from "../types/positionId.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {SwapParameters, createSwapParameters} from "../types/swapParameters.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Shared NFT deposit flow for regular and extension-specific position managers.
abstract contract BasePositionDepositor is UsesCore, PayableMulticallable, BaseLocker, BaseNonfungibleToken {
    using CoreLib for *;
    using FlashAccountantLib for *;

    uint256 internal constant CALL_TYPE_DEPOSIT = 0;

    constructor(ICore core, address owner) BaseNonfungibleToken(owner) BaseLocker(core) UsesCore(core) {}

    /// @inheritdoc BaseNonfungibleToken
    /// @dev Restricts generated token ids to 192 bits so the complete id is used as the Core position salt.
    function saltToId(address minter, bytes32 salt) public view virtual override returns (uint256 id) {
        id = uint192(super.saltToId(minter, salt));
    }

    /// @notice Deposits tokens into a liquidity position at an exact pool price.
    /// @param id The NFT token ID representing the position.
    /// @param poolKey Pool receiving liquidity.
    /// @param tickLower Lower tick of the position range.
    /// @param tickUpper Upper tick of the position range.
    /// @param maxAmount0 Maximum net amount of token0 to spend across the swap and deposit.
    /// @param maxAmount1 Maximum net amount of token1 to spend across the swap and deposit.
    /// @param sqrtRatio The pool price at which liquidity must be added.
    /// @return liquidity Amount of liquidity added to the position.
    /// @return amount0 Amount of token0 added to the position, excluding the preceding swap.
    /// @return amount1 Amount of token1 added to the position, excluding the preceding swap.
    function deposit(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        SqrtRatio sqrtRatio
    ) public payable virtual authorizedForNft(id) returns (uint128 liquidity, uint128 amount0, uint128 amount1) {
        (liquidity, amount0, amount1) = abi.decode(
            lock(
                abi.encode(
                    CALL_TYPE_DEPOSIT, msg.sender, id, poolKey, tickLower, tickUpper, maxAmount0, maxAmount1, sqrtRatio
                )
            ),
            (uint128, uint128, uint128)
        );
    }

    /// @notice Initializes a supported pool if it has not been initialized yet.
    function maybeInitializePool(PoolKey memory poolKey, int32 tick)
        public
        payable
        virtual
        returns (bool initialized, SqrtRatio sqrtRatio)
    {
        _validatePool(poolKey);
        sqrtRatio = CORE.poolState(poolKey.toPoolId()).sqrtRatio();
        if (sqrtRatio.isZero()) {
            initialized = true;
            sqrtRatio = CORE.initializePool(poolKey, tick);
        }
    }

    /// @notice Mints a new NFT and deposits liquidity at an exact pool price.
    function mintAndDeposit(
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        SqrtRatio sqrtRatio
    ) public payable virtual returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1) {
        id = mint();
        (liquidity, amount0, amount1) = deposit(id, poolKey, tickLower, tickUpper, maxAmount0, maxAmount1, sqrtRatio);
    }

    /// @notice Mints a new deterministic NFT and deposits liquidity at an exact pool price.
    function mintAndDepositWithSalt(
        bytes32 salt,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        SqrtRatio sqrtRatio
    ) public payable virtual returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1) {
        id = mint(salt);
        (liquidity, amount0, amount1) = deposit(id, poolKey, tickLower, tickUpper, maxAmount0, maxAmount1, sqrtRatio);
    }

    function _handleDeposit(bytes memory data) internal returns (bytes memory result) {
        (
            ,
            address caller,
            uint256 id,
            PoolKey memory poolKey,
            int32 tickLower,
            int32 tickUpper,
            uint128 maxAmount0,
            uint128 maxAmount1,
            SqrtRatio targetSqrtRatio
        ) = abi.decode(data, (uint256, address, uint256, PoolKey, int32, int32, uint128, uint128, SqrtRatio));

        _validatePool(poolKey);

        PoolState stateBefore = CORE.poolState(poolKey.toPoolId());
        PoolBalanceUpdate swapBalanceUpdate;
        PoolState stateAfter = stateBefore;

        if (stateBefore.sqrtRatio() != targetSqrtRatio) {
            bool increasing = targetSqrtRatio > stateBefore.sqrtRatio();
            uint128 maxSwapAmount = increasing ? maxAmount1 : maxAmount0;
            int128 swapAmount = maxSwapAmount > uint128(type(int128).max) ? type(int128).max : int128(maxSwapAmount);

            (swapBalanceUpdate, stateAfter) = _swap(
                poolKey,
                createSwapParameters({
                    _sqrtRatioLimit: targetSqrtRatio, _amount: swapAmount, _isToken1: increasing, _skipAhead: 0
                })
            );
        }

        if (stateAfter.sqrtRatio() != targetSqrtRatio) {
            revert IPositions.DepositFailedToReachTargetPrice(targetSqrtRatio, stateAfter.sqrtRatio());
        }

        uint128 availableAmount0 = _availableAmount(maxAmount0, swapBalanceUpdate.delta0());
        uint128 availableAmount1 = _availableAmount(maxAmount1, swapBalanceUpdate.delta1());
        uint128 liquidity = maxLiquidity(
            targetSqrtRatio, tickToSqrtRatio(tickLower), tickToSqrtRatio(tickUpper), availableAmount0, availableAmount1
        );

        if (liquidity > uint128(type(int128).max)) revert IPositions.DepositOverflow();

        PositionId positionId = createPositionId(bytes24(uint192(id)), tickLower, tickUpper);
        _validateDepositLiquidity(poolKey, positionId, liquidity);
        PoolBalanceUpdate depositBalanceUpdate = CORE.updatePosition(poolKey, positionId, int128(liquidity));

        if (CORE.poolState(poolKey.toPoolId()).sqrtRatio() != targetSqrtRatio) {
            revert IPositions.DepositFailedDueToPriceMovement();
        }

        int256 balanceDelta0 = int256(swapBalanceUpdate.delta0()) + int256(depositBalanceUpdate.delta0());
        int256 balanceDelta1 = int256(swapBalanceUpdate.delta1()) + int256(depositBalanceUpdate.delta1());
        if (balanceDelta0 > int256(uint256(maxAmount0)) || balanceDelta1 > int256(uint256(maxAmount1))) {
            revert IPositions.DepositFailedDueToPriceMovement();
        }

        _settle(caller, poolKey, balanceDelta0, balanceDelta1);

        result = abi.encode(liquidity, uint128(depositBalanceUpdate.delta0()), uint128(depositBalanceUpdate.delta1()));
    }

    function _availableAmount(uint128 maxAmount, int128 swapDelta) private pure returns (uint128 amount) {
        uint256 available = uint256(maxAmount);
        if (swapDelta >= 0) {
            available -= uint128(swapDelta);
        } else {
            available += uint128(uint256(-int256(swapDelta)));
        }
        amount = available > type(uint128).max ? type(uint128).max : uint128(available);
    }

    function _settle(address caller, PoolKey memory poolKey, int256 delta0, int256 delta1) private {
        if (delta0 >= 0 && delta1 >= 0 && poolKey.token0 != NATIVE_TOKEN_ADDRESS) {
            ACCOUNTANT.payTwoFrom(caller, poolKey.token0, poolKey.token1, uint256(delta0), uint256(delta1));
        } else {
            _settleToken(caller, poolKey.token0, delta0);
            _settleToken(caller, poolKey.token1, delta1);
        }
    }

    function _settleToken(address caller, address token, int256 delta) private {
        if (delta > 0) {
            uint128 amount = uint128(uint256(delta));
            if (token == NATIVE_TOKEN_ADDRESS) {
                SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount);
            } else {
                ACCOUNTANT.payFrom(caller, token, amount);
            }
        } else if (delta < 0) {
            ACCOUNTANT.withdraw(token, caller, uint128(uint256(-delta)));
        }
    }

    function _validatePool(PoolKey memory poolKey) internal view virtual {}

    function _validateDepositLiquidity(PoolKey memory poolKey, PositionId positionId, uint128 liquidity)
        internal
        view
        virtual {}

    function _swap(PoolKey memory poolKey, SwapParameters params)
        internal
        virtual
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter);
}
