// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {PoolKey} from "../types/poolKey.sol";
import {IPositionDepositor} from "./IPositionDepositor.sol";

/// @notice Positions interface with maximum-liquidity routed deposits.
interface IPositionsV2 is IPositionDepositor {
    error WithdrawOverflow();

    function getPositionFeesAndLiquidity(uint256 id, PoolKey calldata poolKey, int32 tickLower, int32 tickUpper)
        external
        view
        returns (uint128 liquidity, uint128 principal0, uint128 principal1, uint128 fees0, uint128 fees1);

    function collectFees(uint256 id, PoolKey calldata poolKey, int32 tickLower, int32 tickUpper)
        external
        payable
        returns (uint128 amount0, uint128 amount1);

    function collectFees(uint256 id, PoolKey calldata poolKey, int32 tickLower, int32 tickUpper, address recipient)
        external
        payable
        returns (uint128 amount0, uint128 amount1);

    function withdraw(
        uint256 id,
        PoolKey calldata poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 liquidity,
        address recipient,
        bool withFees
    ) external payable returns (uint128 amount0, uint128 amount1);

    function withdraw(uint256 id, PoolKey calldata poolKey, int32 tickLower, int32 tickUpper, uint128 liquidity)
        external
        payable
        returns (uint128 amount0, uint128 amount1);

    function withdrawProtocolFees(address token0, address token1, uint128 amount0, uint128 amount1, address recipient)
        external
        payable;

    function getProtocolFees(address token0, address token1) external view returns (uint128 amount0, uint128 amount1);
}
