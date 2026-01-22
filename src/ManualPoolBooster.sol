// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {BaseLocker} from "./base/BaseLocker.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {BoostedFeesLib} from "./libraries/BoostedFeesLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {PoolKey} from "./types/poolKey.sol";

/// @title Manual Pool Booster
/// @notice Helper periphery to add BoostedFees incentives by transferring required tokens/ETH.
/// @dev Approve tokens to this contract (and send ETH if token0 is native) before calling boost.
contract ManualPoolBooster is PayableMulticallable, UsesCore, BaseLocker {
    using FlashAccountantLib for *;
    using BoostedFeesLib for *;

    constructor(ICore core) UsesCore(core) BaseLocker(core) {}

    /// @notice Adds incentives to a pool by forwarding to the BoostedFees extension.
    /// @param poolKey Pool to boost.
    /// @param startTime First second incentives are paid (must be a valid time).
    /// @param endTime Last second incentives are paid (must be a valid time > startTime).
    /// @param rate0 Incentive rate for token0 as a fixed point 80.32 value.
    /// @param rate1 Incentive rate for token1 as a fixed point 80.32 value.
    /// @return amount0 Amount of token0 required to fund the boost.
    /// @return amount1 Amount of token1 required to fund the boost.
    function boost(PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint112 rate0, uint112 rate1)
        external
        payable
        returns (uint112, uint112)
    {
        return abi.decode(lock(abi.encode(msg.sender, poolKey, startTime, endTime, rate0, rate1)), (uint112, uint112));
    }

    /// @dev Handles the lock callback from the flash accountant by adding incentives and paying required amounts.
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (address payer, PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint112 rate0, uint112 rate1) =
            abi.decode(data, (address, PoolKey, uint64, uint64, uint112, uint112));

        (uint112 amount0, uint112 amount1) = CORE.addIncentives(poolKey, startTime, endTime, rate0, rate1);

        if (poolKey.token0 == NATIVE_TOKEN_ADDRESS) {
            if (amount0 != 0) SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount0);
            if (amount1 != 0) ACCOUNTANT.payFrom(payer, poolKey.token1, amount1);
        } else {
            if (amount0 != 0 && amount1 != 0) {
                ACCOUNTANT.payTwoFrom(payer, poolKey.token0, poolKey.token1, amount0, amount1);
            } else if (amount0 != 0) {
                ACCOUNTANT.payFrom(payer, poolKey.token0, amount0);
            } else if (amount1 != 0) {
                ACCOUNTANT.payFrom(payer, poolKey.token1, amount1);
            }
        }

        return abi.encode(amount0, amount1);
    }
}
