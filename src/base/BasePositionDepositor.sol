// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./BaseLocker.sol";
import {BaseNonfungibleToken} from "./BaseNonfungibleToken.sol";
import {PayableMulticallable} from "./PayableMulticallable.sol";
import {UsesCore} from "./UsesCore.sol";
import {ICore} from "../interfaces/ICore.sol";
import {IBaseNonfungibleToken} from "../interfaces/IBaseNonfungibleToken.sol";
import {IPositionDepositor, PositionDeposit} from "../interfaces/IPositionDepositor.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {FlashAccountantLib} from "../libraries/FlashAccountantLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {maxLiquidity} from "../math/liquidity.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionId, createPositionId} from "../types/positionId.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Shared maximum-liquidity deposit flow for regular and extension-specific position managers.
abstract contract BasePositionDepositor is
    IPositionDepositor,
    UsesCore,
    PayableMulticallable,
    BaseLocker,
    BaseNonfungibleToken
{
    using CoreLib for *;
    using FlashAccountantLib for *;

    uint256 internal constant CALL_TYPE_DEPOSIT = 0;

    constructor(ICore core, address owner) BaseNonfungibleToken(owner) BaseLocker(core) UsesCore(core) {}

    /// @inheritdoc BaseNonfungibleToken
    /// @dev Restricts generated token ids to 192 bits so the complete id is used as the Core position salt.
    function saltToId(address minter, bytes32 salt)
        public
        view
        virtual
        override(BaseNonfungibleToken, IBaseNonfungibleToken)
        returns (uint256 id)
    {
        id = uint192(super.saltToId(minter, salt));
    }

    /// @inheritdoc IPositionDepositor
    function deposit(uint256 id, PositionDeposit memory parameters)
        public
        payable
        virtual
        override
        authorizedForNft(id)
        returns (uint128 liquidity, int256 amount0, int256 amount1)
    {
        (liquidity, amount0, amount1) = abi.decode(
            lock(abi.encode(CALL_TYPE_DEPOSIT, msg.sender, id, parameters)), (uint128, int256, int256)
        );
    }

    /// @inheritdoc IPositionDepositor
    function maybeInitializePool(PoolKey memory poolKey, int32 tick)
        public
        payable
        virtual
        override
        returns (bool initialized, SqrtRatio sqrtRatio)
    {
        _validatePool(poolKey);
        sqrtRatio = CORE.poolState(poolKey.toPoolId()).sqrtRatio();
        if (sqrtRatio.isZero()) {
            initialized = true;
            sqrtRatio = CORE.initializePool(poolKey, tick);
        }
    }

    /// @inheritdoc IPositionDepositor
    function mintAndDeposit(PositionDeposit memory parameters)
        public
        payable
        virtual
        override
        returns (uint256 id, uint128 liquidity, int256 amount0, int256 amount1)
    {
        id = mint();
        (liquidity, amount0, amount1) = deposit(id, parameters);
    }

    /// @inheritdoc IPositionDepositor
    function mintAndDepositWithSalt(bytes32 salt, PositionDeposit memory parameters)
        public
        payable
        virtual
        override
        returns (uint256 id, uint128 liquidity, int256 amount0, int256 amount1)
    {
        id = mint(salt);
        (liquidity, amount0, amount1) = deposit(id, parameters);
    }

    function _handleDeposit(bytes memory data) internal returns (bytes memory result) {
        (, address caller, uint256 id, PositionDeposit memory parameters) =
            abi.decode(data, (uint256, address, uint256, PositionDeposit));

        _validatePool(parameters.poolKey);

        if (!parameters.targetSqrtRatio.isValid()) {
            revert InvalidTargetSqrtRatio(parameters.targetSqrtRatio);
        }

        (int256 routeAmount0, int256 routeAmount1) = _route(parameters);
        SqrtRatio routedSqrtRatio = CORE.poolState(parameters.poolKey.toPoolId()).sqrtRatio();
        if (routedSqrtRatio != parameters.targetSqrtRatio) {
            revert TargetSqrtRatioNotReached(parameters.targetSqrtRatio, routedSqrtRatio);
        }

        uint128 liquidity = maxLiquidity(
            routedSqrtRatio,
            tickToSqrtRatio(parameters.tickLower),
            tickToSqrtRatio(parameters.tickUpper),
            _availableAmount(parameters.maxAmount0, routeAmount0),
            _availableAmount(parameters.maxAmount1, routeAmount1)
        );

        if (liquidity < parameters.minLiquidity) {
            revert DepositLiquidityBelowMinimum(liquidity, parameters.minLiquidity);
        }
        if (liquidity > uint128(type(int128).max)) revert DepositLiquidityOverflow(liquidity);

        PositionId positionId = createPositionId(bytes24(uint192(id)), parameters.tickLower, parameters.tickUpper);
        _validateDepositLiquidity(parameters.poolKey, positionId, liquidity);
        PoolBalanceUpdate depositBalanceUpdate = CORE.updatePosition(parameters.poolKey, positionId, int128(liquidity));

        int256 amount0 = routeAmount0 + int256(depositBalanceUpdate.delta0());
        int256 amount1 = routeAmount1 + int256(depositBalanceUpdate.delta1());
        SqrtRatio finalSqrtRatio = CORE.poolState(parameters.poolKey.toPoolId()).sqrtRatio();
        if (finalSqrtRatio != parameters.targetSqrtRatio) {
            revert TargetSqrtRatioNotReached(parameters.targetSqrtRatio, finalSqrtRatio);
        } else if (amount0 > int256(uint256(parameters.maxAmount0)) || amount1 > int256(uint256(parameters.maxAmount1)))
        {
            revert DepositExceedsMaxAmounts(amount0, amount1, parameters.maxAmount0, parameters.maxAmount1);
        }

        _settle(caller, parameters.poolKey, amount0, amount1);
        result = abi.encode(liquidity, amount0, amount1);
    }

    function _availableAmount(uint128 maxAmount, int256 routeAmount) private pure returns (uint128 amount) {
        if (routeAmount >= 0) {
            uint256 spent = uint256(routeAmount);
            return spent >= maxAmount ? 0 : maxAmount - uint128(spent);
        }

        uint256 received;
        assembly ("memory-safe") {
            received := sub(0, routeAmount)
        }
        uint256 room = type(uint128).max - uint256(maxAmount);
        amount = received >= room ? type(uint128).max : maxAmount + uint128(received);
    }

    function _route(PositionDeposit memory parameters) private returns (int256 amount0, int256 amount1) {
        if (parameters.router == address(0)) {
            if (parameters.routerData.length != 0) revert RouterRequired();
            return (0, 0);
        }

        bytes memory routeResult = ACCOUNTANT.forward(parameters.router, parameters.routerData);
        (address specifiedToken, address calculatedToken, int256 specifiedDelta, int256 calculatedDelta) =
            abi.decode(routeResult, (address, address, int256, int256));

        if (specifiedToken == parameters.poolKey.token0 && calculatedToken == parameters.poolKey.token1) {
            return (specifiedDelta, calculatedDelta);
        }
        if (specifiedToken == parameters.poolKey.token1 && calculatedToken == parameters.poolKey.token0) {
            return (calculatedDelta, specifiedDelta);
        }
        revert InvalidRouteTokens(specifiedToken, calculatedToken, parameters.poolKey.token0, parameters.poolKey.token1);
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
            if (delta < -int256(uint256(type(uint128).max))) revert RouteOutputOverflow(token, delta);
            ACCOUNTANT.withdraw(token, caller, uint128(uint256(-delta)));
        }
    }

    function _validatePool(PoolKey memory poolKey) internal view virtual {}

    function _validateDepositLiquidity(PoolKey memory poolKey, PositionId positionId, uint128 liquidity)
        internal
        view
        virtual {}
}
