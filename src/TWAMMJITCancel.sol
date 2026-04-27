// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IOrders} from "./interfaces/IOrders.sol";
import {ITWAMM} from "./interfaces/extensions/ITWAMM.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {OrderKey} from "./types/orderKey.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PositionId, createPositionId} from "./types/positionId.sol";
import {PoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";
import {PoolId} from "./types/poolId.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {maxLiquidity} from "./math/liquidity.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {PoolState} from "./types/poolState.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface IERC721Owner {
    function ownerOf(uint256 id) external view returns (address owner);
}

/// @notice Helper for reproducing the v3.1.0 TWAMM cancellation fee JIT-liquidity issue.
contract TWAMMJITCancel is BaseLocker, UsesCore {
    using CoreLib for ICore;
    using FlashAccountantLib for ICore;

    error NotOrderOwner(address caller, address owner, uint256 id);

    IOrders public immutable ORDERS;
    ITWAMM public immutable TWAMM;

    constructor(ICore core, IOrders orders, ITWAMM twamm) BaseLocker(core) UsesCore(core) {
        ORDERS = orders;
        TWAMM = twamm;
    }

    /// @notice Adds overwhelming same-lock liquidity, collects proceeds, decreases sale rate, then removes the liquidity.
    /// @dev The Orders NFT must approve this contract for `id`.
    function collectProceedsAndDecreaseSaleRate(uint256 id, OrderKey memory orderKey)
        external
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        address owner = IERC721Owner(address(ORDERS)).ownerOf(id);
        if (owner != msg.sender) revert NotOrderOwner(msg.sender, owner, id);

        lock(abi.encode(id, orderKey));

        PoolKey memory poolKey = orderKey.toPoolKey(address(TWAMM));
        amount0 = _transferAll(poolKey.token0, owner);
        amount1 = _transferAll(poolKey.token1, owner);
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        (uint256 id, OrderKey memory orderKey) = abi.decode(data, (uint256, OrderKey));

        PoolKey memory poolKey = orderKey.toPoolKey(address(TWAMM));
        TWAMM.lockAndExecuteVirtualOrders(poolKey);
        (uint112 saleRate,,,) = ORDERS.executeVirtualOrdersAndGetCurrentOrderInfo(id, orderKey);
        PoolId poolId = poolKey.toPoolId();
        PoolState state = CORE.poolState(poolId);

        (PositionId positionId, uint128 liquidity, uint128 paid0, uint128 paid1) = _addTemporaryPosition(poolKey, state);

        ORDERS.collectProceeds(id, orderKey, address(this));
        ORDERS.decreaseSaleRate(id, orderKey, saleRate, address(this));

        _removeTemporaryPosition(poolKey, positionId, liquidity, paid0, paid1);
    }

    function _addTemporaryPosition(PoolKey memory poolKey, PoolState state)
        internal
        returns (PositionId positionId, uint128 liquidity, uint128 paid0, uint128 paid1)
    {
        (int32 tickLower, int32 tickUpper) = poolKey.config.stableswapActiveLiquidityTickRange();
        liquidity = maxLiquidity({
            _sqrtRatio: state.sqrtRatio(),
            sqrtRatioA: tickToSqrtRatio(tickLower),
            sqrtRatioB: tickToSqrtRatio(tickUpper),
            amount0: uint128(type(int128).max),
            amount1: uint128(type(int128).max)
        });
        if (liquidity > uint128(type(int128).max)) liquidity = uint128(type(int128).max);
        uint128 remainingPoolLiquidity = type(uint128).max - state.liquidity();
        if (liquidity > remainingPoolLiquidity) liquidity = remainingPoolLiquidity;

        positionId = createPositionId({_salt: bytes24(0), _tickLower: tickLower, _tickUpper: tickUpper});

        // forge-lint: disable-next-line(unsafe-typecast)
        PoolBalanceUpdate balanceUpdate = CORE.updatePosition(poolKey, positionId, int128(liquidity));

        paid0 = uint128(balanceUpdate.delta0());
        paid1 = uint128(balanceUpdate.delta1());
    }

    function _removeTemporaryPosition(
        PoolKey memory poolKey,
        PositionId positionId,
        uint128 liquidity,
        uint128 paid0,
        uint128 paid1
    ) internal {
        (uint128 fees0, uint128 fees1) = CORE.collectFees(poolKey, positionId);

        // forge-lint: disable-next-line(unsafe-typecast)
        PoolBalanceUpdate balanceUpdate = CORE.updatePosition(poolKey, positionId, -int128(liquidity));

        uint128 withdrawn0 = _settleToken(poolKey.token0, fees0, paid0, uint128(-balanceUpdate.delta0()));
        uint128 withdrawn1 = _settleToken(poolKey.token1, fees1, paid1, uint128(-balanceUpdate.delta1()));
        CORE.withdrawTwo(poolKey.token0, poolKey.token1, address(this), withdrawn0, withdrawn1);
    }

    function _settleToken(address token, uint128 fees, uint128 paid, uint128 principal)
        internal
        returns (uint128 withdrawn)
    {
        if (principal >= paid) {
            withdrawn = fees + principal - paid;
        } else {
            withdrawn = fees;
            _payDust(token, paid - principal);
        }
    }

    function _payDust(address token, uint128 amount) internal {
        if (amount == 0) return;
        if (token == NATIVE_TOKEN_ADDRESS) {
            SafeTransferLib.safeTransferETH(address(CORE), amount);
        } else {
            CORE.pay(token, amount);
        }
    }

    function _transferAll(address token, address recipient) internal returns (uint128 amount) {
        if (token == NATIVE_TOKEN_ADDRESS) {
            amount = SafeCastLib.toUint128(address(this).balance);
            if (amount != 0) SafeTransferLib.safeTransferAllETH(recipient);
        } else {
            amount = SafeCastLib.toUint128(SafeTransferLib.balanceOf(token, address(this)));
            if (amount != 0) SafeTransferLib.safeTransfer(token, recipient, amount);
        }
    }
}
