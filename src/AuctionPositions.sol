// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./base/BaseLocker.sol";
import {BaseNonfungibleToken} from "./base/BaseNonfungibleToken.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ContinuousAuction} from "./extensions/ContinuousAuction.sol";
import {ICore} from "./interfaces/ICore.sol";
import {ContinuousAuctionLib} from "./libraries/ContinuousAuctionLib.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {liquidityDeltaToAmountDelta, maxLiquidity} from "./math/liquidity.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {PoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";
import {PoolId} from "./types/poolId.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PositionId, createPositionId} from "./types/positionId.sol";
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Position NFTs for continuous-auction pools with owner/approved-operator collection of rent.
/// @dev No protocol fees. Rent remains claimable after removing all liquidity and travels with the NFT on
/// transfer; collect it before burning. Burning does not settle Core positions or rent, and the original minter
/// can recreate the same deterministic NFT ID.
contract AuctionPositions is UsesCore, PayableMulticallable, BaseLocker, BaseNonfungibleToken {
    using CoreLib for *;
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_DEPOSIT = 0;
    uint256 private constant CALL_TYPE_WITHDRAW = 1;
    uint256 private constant CALL_TYPE_COLLECT_RENT = 2;
    uint256 private constant CALL_TYPE_WITHDRAW_AND_COLLECT_RENT = 3;

    ContinuousAuction public immutable auction;
    address public immutable bidToken;

    error DepositFailedDueToSlippage(uint128 liquidity, uint128 minLiquidity);
    error DepositFailedDueToPriceMovement();
    error DepositOverflow();
    error WithdrawOverflow();
    error InvalidAuctionPool();

    constructor(ICore core, ContinuousAuction _auction, address owner)
        BaseNonfungibleToken(owner)
        BaseLocker(core)
        UsesCore(core)
    {
        auction = _auction;
        bidToken = _auction.bidToken();
    }

    receive() external payable {}

    function saltToId(address minter, bytes32 salt) public view override returns (uint256 id) {
        id = uint192(super.saltToId(minter, salt));
    }

    function positionId(uint256 id, int32 tickLower, int32 tickUpper) public pure returns (PositionId) {
        return createPositionId(bytes24(uint192(id)), tickLower, tickUpper);
    }

    /// @notice Position liquidity, principal, and rent claimable using already-accrued state.
    function getPositionRentAndLiquidity(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        external
        view
        returns (uint128 liquidity, uint128 principal0, uint128 principal1, uint256 rent)
    {
        _validateAuctionPool(poolKey);
        PoolId poolId = poolKey.toPoolId();
        SqrtRatio sqrtRatio = CORE.poolState(poolId).sqrtRatio();
        PositionId positionId_ = positionId(id, tickLower, tickUpper);
        liquidity = ContinuousAuctionLib.positionLiquidity(CORE, poolId, address(this), positionId_);
        (int128 delta0, int128 delta1) = liquidityDeltaToAmountDelta(
            sqrtRatio, -SafeCastLib.toInt128(liquidity), tickToSqrtRatio(tickLower), tickToSqrtRatio(tickUpper)
        );
        principal0 = uint128(-delta0);
        principal1 = uint128(-delta1);
        rent = auction.getPositionRent(poolKey, address(this), positionId_);
    }

    function deposit(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) public payable authorizedForNft(id) returns (uint128 liquidity, uint128 amount0, uint128 amount1) {
        (liquidity, amount0, amount1) = abi.decode(
            lock(
                abi.encode(
                    CALL_TYPE_DEPOSIT,
                    msg.sender,
                    id,
                    poolKey,
                    tickLower,
                    tickUpper,
                    maxAmount0,
                    maxAmount1,
                    minLiquidity
                )
            ),
            (uint128, uint128, uint128)
        );
    }

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

    function withdraw(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper, uint128 liquidity)
        external
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = withdraw(id, poolKey, tickLower, tickUpper, liquidity, msg.sender);
    }

    /// @notice Withdraws liquidity and collects rent in one lock.
    function withdrawAndCollectRent(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 liquidity,
        address recipient
    ) public payable authorizedForNft(id) returns (uint128 amount0, uint128 amount1, uint256 rent) {
        (amount0, amount1, rent) = abi.decode(
            lock(
                abi.encode(CALL_TYPE_WITHDRAW_AND_COLLECT_RENT, id, poolKey, tickLower, tickUpper, liquidity, recipient)
            ),
            (uint128, uint128, uint256)
        );
    }

    function withdrawAndCollectRent(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 liquidity
    ) external payable returns (uint128 amount0, uint128 amount1, uint256 rent) {
        (amount0, amount1, rent) = withdrawAndCollectRent(id, poolKey, tickLower, tickUpper, liquidity, msg.sender);
    }

    /// @notice Collects bid-token rent to recipient. Only the NFT owner or an approved operator may collect.
    function collectRent(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper, address recipient)
        public
        payable
        authorizedForNft(id)
        returns (uint256 rent)
    {
        rent = abi.decode(
            lock(abi.encode(CALL_TYPE_COLLECT_RENT, poolKey, positionId(id, tickLower, tickUpper), recipient)),
            (uint256)
        );
    }

    function collectRent(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        external
        payable
        returns (uint256 rent)
    {
        rent = collectRent(id, poolKey, tickLower, tickUpper, msg.sender);
    }

    function maybeInitializePool(PoolKey memory poolKey, int32 tick)
        external
        payable
        returns (bool initialized, SqrtRatio sqrtRatio)
    {
        _validateAuctionPool(poolKey);
        sqrtRatio = CORE.poolState(poolKey.toPoolId()).sqrtRatio();
        if (sqrtRatio.isZero()) {
            initialized = true;
            sqrtRatio = CORE.initializePool(poolKey, tick);
        }
    }

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

    /// @inheritdoc BaseLocker
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_DEPOSIT) {
            (
                ,
                address caller,
                uint256 id,
                PoolKey memory poolKey,
                int32 tickLower,
                int32 tickUpper,
                uint128 maxAmount0,
                uint128 maxAmount1,
                uint128 minLiquidity
            ) = abi.decode(data, (uint256, address, uint256, PoolKey, int32, int32, uint128, uint128, uint128));

            _validateAuctionPool(poolKey);
            SqrtRatio sqrtRatio = CORE.poolState(poolKey.toPoolId()).sqrtRatio();
            uint128 liquidity =
                maxLiquidity(sqrtRatio, tickToSqrtRatio(tickLower), tickToSqrtRatio(tickUpper), maxAmount0, maxAmount1);

            if (liquidity < minLiquidity) revert DepositFailedDueToSlippage(liquidity, minLiquidity);
            if (liquidity > uint128(type(int128).max)) revert DepositOverflow();

            PoolBalanceUpdate balanceUpdate =
                CORE.updatePosition(poolKey, positionId(id, tickLower, tickUpper), int128(liquidity));
            uint128 amount0 = uint128(balanceUpdate.delta0());
            uint128 amount1 = uint128(balanceUpdate.delta1());

            if (amount0 > maxAmount0 || amount1 > maxAmount1) revert DepositFailedDueToPriceMovement();

            if (poolKey.token0 != NATIVE_TOKEN_ADDRESS) {
                ACCOUNTANT.payTwoFrom(caller, poolKey.token0, poolKey.token1, amount0, amount1);
            } else {
                if (amount0 != 0) SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount0);
                if (amount1 != 0) ACCOUNTANT.payFrom(caller, poolKey.token1, amount1);
            }

            result = abi.encode(liquidity, amount0, amount1);
        } else if (callType == CALL_TYPE_WITHDRAW || callType == CALL_TYPE_WITHDRAW_AND_COLLECT_RENT) {
            (
                ,
                uint256 id,
                PoolKey memory poolKey,
                int32 tickLower,
                int32 tickUpper,
                uint128 liquidity,
                address recipient
            ) = abi.decode(data, (uint256, uint256, PoolKey, int32, int32, uint128, address));

            _validateAuctionPool(poolKey);
            if (liquidity > uint128(type(int128).max)) revert WithdrawOverflow();
            PositionId positionId_ = positionId(id, tickLower, tickUpper);

            uint256 rent;
            if (callType == CALL_TYPE_WITHDRAW_AND_COLLECT_RENT) {
                rent = _collectRent(poolKey, positionId_, recipient);
            }

            uint128 amount0;
            uint128 amount1;
            if (liquidity != 0) {
                PoolBalanceUpdate balanceUpdate = CORE.updatePosition(poolKey, positionId_, -int128(liquidity));
                amount0 = uint128(-balanceUpdate.delta0());
                amount1 = uint128(-balanceUpdate.delta1());
                ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, recipient, amount0, amount1);
            }

            result = callType == CALL_TYPE_WITHDRAW ? abi.encode(amount0, amount1) : abi.encode(amount0, amount1, rent);
        } else if (callType == CALL_TYPE_COLLECT_RENT) {
            (, PoolKey memory poolKey, PositionId positionId_, address recipient) =
                abi.decode(data, (uint256, PoolKey, PositionId, address));

            _validateAuctionPool(poolKey);
            result = abi.encode(_collectRent(poolKey, positionId_, recipient));
        } else {
            revert();
        }
    }

    function _collectRent(PoolKey memory poolKey, PositionId positionId_, address recipient)
        private
        returns (uint256 rent)
    {
        rent = ContinuousAuctionLib.collectRent(CORE, address(auction), poolKey, positionId_);
        if (rent != 0) ACCOUNTANT.withdraw(bidToken, recipient, SafeCastLib.toUint128(rent));
    }

    function _validateAuctionPool(PoolKey memory poolKey) private view {
        if (poolKey.config.extension() != address(auction)) revert InvalidAuctionPool();
    }
}
