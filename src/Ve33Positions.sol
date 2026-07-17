// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BasePositionDepositor} from "./base/BasePositionDepositor.sol";
import {Ve33} from "./extensions/Ve33.sol";
import {ICore} from "./interfaces/ICore.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {ExposedStorageLib} from "./libraries/ExposedStorageLib.sol";
import {Ve33Lib} from "./libraries/Ve33Lib.sol";
import {liquidityDeltaToAmountDelta} from "./math/liquidity.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {PoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";
import {PoolId} from "./types/poolId.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PoolState} from "./types/poolState.sol";
import {PositionId, createPositionId} from "./types/positionId.sol";
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {SwapParameters} from "./types/swapParameters.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/// @notice ERC721 position manager for Ve33 liquidity positions.
/// @dev Ve33 LPs do not earn Core swap fees. This contract only manages liquidity principal and Ve33 reward claims.
contract Ve33Positions is BasePositionDepositor {
    using CoreLib for *;
    using ExposedStorageLib for *;
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_WITHDRAW = 1;
    uint256 private constant CALL_TYPE_CLAIM_REWARDS = 2;
    uint256 private constant CALL_TYPE_WITHDRAW_AND_CLAIM_REWARDS = 3;

    /// @notice The Ve33 extension whose pools this position manager supports.
    Ve33 public immutable ve33;

    /// @notice Token paid as LP rewards by Ve33.
    address public immutable stakeToken;

    /// @notice Thrown when the available swap input cannot move the pool into the requested deposit price range.
    error DepositFailedToReachPriceRange(SqrtRatio minSqrtRatio, SqrtRatio maxSqrtRatio, SqrtRatio actualSqrtRatio);

    /// @notice Thrown when an extension moves the price while liquidity is being added.
    error DepositFailedDueToPriceMovement();

    /// @notice Thrown when deposit liquidity cannot fit in the Core position update type.
    error DepositOverflow();

    /// @notice Thrown when withdrawn liquidity cannot fit in the Core position update type.
    error WithdrawOverflow();

    /// @notice Thrown when a pool is not managed by this contract's Ve33 extension.
    error InvalidPoolExtension();

    /// @notice Creates the Ve33 position NFT manager.
    /// @param core Ekubo Core contract used for locks and position updates.
    /// @param _ve33 Ve33 extension whose pools are supported.
    /// @param owner Owner allowed to set collection metadata.
    constructor(ICore core, Ve33 _ve33, address owner) BasePositionDepositor(core, owner) {
        ve33 = _ve33;
        stakeToken = _ve33.stakeToken();
    }

    receive() external payable {}

    /// @notice Computes the Core position id controlled by this NFT id and tick range.
    /// @param id ERC721 token id representing the position owner.
    /// @param tickLower Lower position tick.
    /// @param tickUpper Upper position tick.
    /// @return The Core position id owned by this contract.
    function positionId(uint256 id, int32 tickLower, int32 tickUpper) public pure returns (PositionId) {
        return createPositionId(bytes24(uint192(id)), tickLower, tickUpper);
    }

    /// @notice Gets position liquidity and principal amounts.
    /// @dev Does not include Core swap fees because Ve33 pools account swap fees outside LP positions.
    /// @param id ERC721 token id representing the position owner.
    /// @param poolKey Pool containing the position.
    /// @param tickLower Lower position tick.
    /// @param tickUpper Upper position tick.
    /// @return liquidity Current position liquidity.
    /// @return principal0 Current token0 principal.
    /// @return principal1 Current token1 principal.
    function getPositionLiquidity(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        external
        view
        returns (uint128 liquidity, uint128 principal0, uint128 principal1)
    {
        _validateVe33Pool(poolKey);
        PoolId poolId = poolKey.toPoolId();
        SqrtRatio sqrtRatio = CORE.poolState(poolId).sqrtRatio();
        liquidity = Ve33Lib.positionLiquidity(CORE, poolId, address(this), positionId(id, tickLower, tickUpper));

        (int128 delta0, int128 delta1) = liquidityDeltaToAmountDelta(
            sqrtRatio, -SafeCastLib.toInt128(liquidity), tickToSqrtRatio(tickLower), tickToSqrtRatio(tickUpper)
        );
        principal0 = uint128(-delta0);
        principal1 = uint128(-delta1);
    }

    /// @notice Gets position liquidity, principal amounts, and currently claimable Ve33 reward tokens.
    /// @dev Reward amount reflects already-accumulated Ve33 state.
    /// @param id ERC721 token id representing the position owner.
    /// @param poolKey Pool containing the position.
    /// @param tickLower Lower position tick.
    /// @param tickUpper Upper position tick.
    /// @return liquidity Current position liquidity.
    /// @return principal0 Current token0 principal.
    /// @return principal1 Current token1 principal.
    /// @return rewardAmount Current reward-token amount claimable through this manager.
    function getPositionRewardsAndLiquidity(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        external
        view
        returns (uint128 liquidity, uint128 principal0, uint128 principal1, uint256 rewardAmount)
    {
        _validateVe33Pool(poolKey);
        PoolId poolId = poolKey.toPoolId();
        SqrtRatio sqrtRatio = CORE.poolState(poolId).sqrtRatio();
        PositionId positionId_ = positionId(id, tickLower, tickUpper);
        liquidity = Ve33Lib.positionLiquidity(CORE, poolId, address(this), positionId_);

        (int128 delta0, int128 delta1) = liquidityDeltaToAmountDelta(
            sqrtRatio, -SafeCastLib.toInt128(liquidity), tickToSqrtRatio(tickLower), tickToSqrtRatio(tickUpper)
        );
        principal0 = uint128(-delta0);
        principal1 = uint128(-delta1);
        rewardAmount = _positionRewardAmount(poolKey, poolId, positionId_, tickLower, tickUpper, liquidity);
    }

    /// @notice Withdraws liquidity principal from a Ve33 position.
    /// @param id ERC721 token id representing the position owner.
    /// @param poolKey Pool containing the position.
    /// @param tickLower Lower position tick.
    /// @param tickUpper Upper position tick.
    /// @param liquidity Amount of liquidity to withdraw.
    /// @param recipient Account receiving withdrawn pool tokens.
    /// @return amount0 Token0 withdrawn.
    /// @return amount1 Token1 withdrawn.
    function withdraw(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 liquidity,
        address recipient
    ) public payable authorizedForNft(id) returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = abi.decode(
            lock(abi.encode(CALL_TYPE_WITHDRAW, id, poolKey, tickLower, tickUpper, liquidity, recipient)),
            (uint128, uint128)
        );
    }

    /// @notice Withdraws liquidity principal to the caller.
    function withdraw(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper, uint128 liquidity)
        external
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = withdraw(id, poolKey, tickLower, tickUpper, liquidity, msg.sender);
    }

    /// @notice Claims reward tokens, then withdraws liquidity principal from a Ve33 position.
    /// @param id ERC721 token id representing the position owner.
    /// @param poolKey Pool containing the position.
    /// @param tickLower Lower position tick.
    /// @param tickUpper Upper position tick.
    /// @param liquidity Amount of liquidity to withdraw.
    /// @param recipient Account receiving withdrawn pool tokens and claimed reward tokens.
    /// @return amount0 Token0 withdrawn.
    /// @return amount1 Token1 withdrawn.
    /// @return rewardAmount Claimed reward-token amount.
    function withdrawAndClaimRewards(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 liquidity,
        address recipient
    ) public payable authorizedForNft(id) returns (uint128 amount0, uint128 amount1, uint256 rewardAmount) {
        (amount0, amount1, rewardAmount) = abi.decode(
            lock(
                abi.encode(
                    CALL_TYPE_WITHDRAW_AND_CLAIM_REWARDS, id, poolKey, tickLower, tickUpper, liquidity, recipient
                )
            ),
            (uint128, uint128, uint256)
        );
    }

    /// @notice Claims reward tokens, then withdraws liquidity principal to the caller.
    function withdrawAndClaimRewards(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 liquidity
    ) external payable returns (uint128 amount0, uint128 amount1, uint256 rewardAmount) {
        (amount0, amount1, rewardAmount) =
            withdrawAndClaimRewards(id, poolKey, tickLower, tickUpper, liquidity, msg.sender);
    }

    /// @notice Claims Ve33 LP reward tokens for a position.
    /// @param id ERC721 token id representing the position owner.
    /// @param poolKey Pool containing the position.
    /// @param tickLower Lower position tick.
    /// @param tickUpper Upper position tick.
    /// @param recipient Account receiving claimed reward tokens.
    /// @return amount Claimed reward-token amount.
    function claimRewards(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper, address recipient)
        public
        payable
        authorizedForNft(id)
        returns (uint256 amount)
    {
        amount = abi.decode(
            lock(abi.encode(CALL_TYPE_CLAIM_REWARDS, poolKey, positionId(id, tickLower, tickUpper), recipient)),
            (uint256)
        );
    }

    /// @notice Claims Ve33 LP reward tokens to the caller.
    function claimRewards(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        external
        payable
        returns (uint256 amount)
    {
        amount = claimRewards(id, poolKey, tickLower, tickUpper, msg.sender);
    }

    /// @notice Handles position-manager operations while the Core lock is held.
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_DEPOSIT) {
            result = _handleDeposit(data);
        } else if (callType == CALL_TYPE_WITHDRAW) {
            (
                ,
                uint256 id,
                PoolKey memory poolKey,
                int32 tickLower,
                int32 tickUpper,
                uint128 liquidity,
                address recipient
            ) = abi.decode(data, (uint256, uint256, PoolKey, int32, int32, uint128, address));

            _validateVe33Pool(poolKey);
            if (liquidity > uint128(type(int128).max)) revert WithdrawOverflow();

            PoolBalanceUpdate balanceUpdate =
                CORE.updatePosition(poolKey, positionId(id, tickLower, tickUpper), -int128(liquidity));
            uint128 amount0 = uint128(-balanceUpdate.delta0());
            uint128 amount1 = uint128(-balanceUpdate.delta1());

            ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, recipient, amount0, amount1);
            result = abi.encode(amount0, amount1);
        } else if (callType == CALL_TYPE_WITHDRAW_AND_CLAIM_REWARDS) {
            (
                ,
                uint256 id,
                PoolKey memory poolKey,
                int32 tickLower,
                int32 tickUpper,
                uint128 liquidity,
                address recipient
            ) = abi.decode(data, (uint256, uint256, PoolKey, int32, int32, uint128, address));

            _validateVe33Pool(poolKey);
            if (liquidity > uint128(type(int128).max)) revert WithdrawOverflow();

            PositionId positionId_ = positionId(id, tickLower, tickUpper);
            uint128 rewardAmount = uint128(Ve33Lib.claimRewards(CORE, ve33, poolKey, positionId_));

            PoolBalanceUpdate balanceUpdate = CORE.updatePosition(poolKey, positionId_, -int128(liquidity));
            uint128 amount0 = uint128(-balanceUpdate.delta0());
            uint128 amount1 = uint128(-balanceUpdate.delta1());

            ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, recipient, amount0, amount1);
            if (rewardAmount != 0) {
                ACCOUNTANT.withdraw(stakeToken, recipient, rewardAmount);
            }
            result = abi.encode(amount0, amount1, rewardAmount);
        } else if (callType == CALL_TYPE_CLAIM_REWARDS) {
            (, PoolKey memory poolKey, PositionId positionId_, address recipient) =
                abi.decode(data, (uint256, PoolKey, PositionId, address));

            _validateVe33Pool(poolKey);
            uint128 rewardAmount = uint128(Ve33Lib.claimRewards(CORE, ve33, poolKey, positionId_));
            if (rewardAmount != 0) {
                ACCOUNTANT.withdraw(stakeToken, recipient, rewardAmount);
            }
            result = abi.encode(rewardAmount);
        } else {
            revert();
        }
    }

    function _validateVe33Pool(PoolKey memory poolKey) private view {
        if (poolKey.config.extension() != address(ve33)) revert InvalidPoolExtension();
    }

    function _validatePool(PoolKey memory poolKey) internal view override {
        _validateVe33Pool(poolKey);
    }

    function _validateDepositLiquidity(PoolKey memory poolKey, PositionId positionId_, uint128 liquidity)
        internal
        view
        override
    {
        uint128 existingLiquidity = Ve33Lib.positionLiquidity(CORE, poolKey.toPoolId(), address(this), positionId_);
        if (existingLiquidity > uint128(type(int128).max) - liquidity) revert DepositOverflow();
    }

    function _swap(PoolKey memory poolKey, SwapParameters params)
        internal
        override
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        (balanceUpdate, stateAfter) = Ve33Lib.swap(CORE, ve33, poolKey, params);
    }

    function _positionRewardAmount(
        PoolKey memory poolKey,
        PoolId poolId,
        PositionId positionId_,
        int32 tickLower,
        int32 tickUpper,
        uint128 liquidity
    ) private view returns (uint256 amount) {
        if (liquidity != 0) {
            uint256 rewardsInsidePerLiquidity = poolKey.config.isStableswap()
                ? Ve33Lib.rewardsGlobalPerLiquidity(ve33, poolId)
                : ve33.getPoolRewardsPerLiquidityInside(poolId, tickLower, tickUpper);
            uint256 snapshot = Ve33Lib.positionRewardsSnapshotPerLiquidity(ve33, poolId, address(this), positionId_);
            unchecked {
                amount = uint128(FixedPointMathLib.fullMulDivN(rewardsInsidePerLiquidity - snapshot, liquidity, 128));
            }
        }
    }
}
