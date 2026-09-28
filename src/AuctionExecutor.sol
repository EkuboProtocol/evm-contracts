// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./base/BaseLocker.sol";
import {BaseOwnableExecutor} from "./base/BaseOwnableExecutor.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IContinuousAuction} from "./interfaces/extensions/IContinuousAuction.sol";
import {ContinuousAuctionLib} from "./libraries/ContinuousAuctionLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {PoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";
import {PoolKey} from "./types/poolKey.sol";
import {SwapParameters} from "./types/swapParameters.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title Auction Executor
/// @notice An owner-operated Core locker that bids in a continuous auction, names itself as the bid's executor,
/// swaps through the auction and collects the bid's swap fees.
/// @dev Every operation is owner-only and settles against this contract's own balances in the same lock: bids are
/// paid from and refunded to this contract, swaps are paid from and delivered to this contract, and fees are
/// withdrawn to it. Fund it by transfer or with call value; recover funds or run other calls with `call`, and batch
/// operations atomically with `multicall`. Bids name this contract as their executor, so only the owner swaps
/// fee-free while one of them holds a pool.
contract AuctionExecutor is BaseOwnableExecutor, UsesCore, BaseLocker {
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_UPDATE_BID = 0;
    uint256 private constant CALL_TYPE_SWAP = 1;
    uint256 private constant CALL_TYPE_COLLECT_SWAP_FEES = 2;

    address public immutable auction;
    address public immutable bidToken;

    /// @notice Thrown when an operation is included after its deadline.
    error DeadlineExpired(uint256 deadline);

    /// @notice Thrown when a swap's balance update exceeds the caller's bound in either token.
    error MaxBalanceUpdateExceeded(PoolBalanceUpdate maxBalanceUpdate, PoolBalanceUpdate balanceUpdate);

    constructor(ICore core, address _auction, address _owner)
        BaseOwnableExecutor(_owner)
        UsesCore(core)
        BaseLocker(core)
    {
        auction = _auction;
        bidToken = IContinuousAuction(_auction).bidToken();
    }

    modifier beforeDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        _;
    }

    /// @notice Sets this contract's bid for the pool under `salt` to [timestamp + 1, end) with itself as executor.
    /// Rate zero removes the bid and withdraws any credit. See ContinuousAuction for the bidding rules.
    /// @dev The bid starts the second after inclusion, so a late inclusion buys a shorter tenure. Choose `deadline`
    /// at most `end - 1 - minimum usable tenure`, allowing for the chain's block interval and inclusion latency.
    /// @return delta Bid-token amount paid by this contract (positive) or refunded to it (negative).
    function updateBid(PoolKey memory poolKey, bytes32 salt, uint96 rate, uint64 end, uint32 fee, uint256 deadline)
        external
        payable
        onlyOwner
        beforeDeadline(deadline)
        returns (int256 delta)
    {
        delta = abi.decode(lock(abi.encode(CALL_TYPE_UPDATE_BID, poolKey, salt, rate, end, fee)), (int256));
    }

    /// @notice Swaps through the auction pool. The swap is fee-free only while one of this contract's bids holds the
    /// pool; otherwise it pays the holder's fee like any other locker.
    /// @param maxBalanceUpdate The largest pool balance change accepted in each token, fee included: a positive
    /// delta is the most this contract pays, a negative delta the least it receives. For example, selling at most
    /// `x` token0 for at least `y` token1 is `(x, -y)` for exact-input and exact-output swaps alike, which also
    /// rejects partial fills that would breach either bound.
    function swap(PoolKey memory poolKey, SwapParameters params, PoolBalanceUpdate maxBalanceUpdate, uint256 deadline)
        external
        payable
        onlyOwner
        beforeDeadline(deadline)
        returns (PoolBalanceUpdate balanceUpdate)
    {
        balanceUpdate =
            abi.decode(lock(abi.encode(CALL_TYPE_SWAP, poolKey, params, maxBalanceUpdate)), (PoolBalanceUpdate));
    }

    /// @notice Withdraws the swap fees earned by this contract's bid under `salt` on the pool to this contract.
    function collectSwapFees(PoolKey memory poolKey, bytes32 salt)
        external
        payable
        onlyOwner
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) =
            abi.decode(lock(abi.encode(CALL_TYPE_COLLECT_SWAP_FEES, poolKey, salt)), (uint128, uint128));
    }

    /// @inheritdoc BaseLocker
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_UPDATE_BID) {
            (, PoolKey memory poolKey, bytes32 salt, uint96 rate, uint64 end, uint32 fee) =
                abi.decode(data, (uint256, PoolKey, bytes32, uint96, uint64, uint32));
            int256 delta = ContinuousAuctionLib.updateBid(CORE, auction, poolKey, salt, rate, end, address(this), fee);
            _settle(bidToken, delta);
            result = abi.encode(delta);
        } else if (callType == CALL_TYPE_SWAP) {
            (, PoolKey memory poolKey, SwapParameters params, PoolBalanceUpdate maxBalanceUpdate) =
                abi.decode(data, (uint256, PoolKey, SwapParameters, PoolBalanceUpdate));
            (PoolBalanceUpdate balanceUpdate,) = ContinuousAuctionLib.swap(CORE, auction, poolKey, params);
            if (
                balanceUpdate.delta0() > maxBalanceUpdate.delta0() || balanceUpdate.delta1() > maxBalanceUpdate.delta1()
            ) {
                revert MaxBalanceUpdateExceeded(maxBalanceUpdate, balanceUpdate);
            }
            _settle(poolKey.token0, balanceUpdate.delta0());
            _settle(poolKey.token1, balanceUpdate.delta1());
            result = abi.encode(balanceUpdate);
        } else {
            (, PoolKey memory poolKey, bytes32 salt) = abi.decode(data, (uint256, PoolKey, bytes32));
            (uint128 amount0, uint128 amount1) = ContinuousAuctionLib.collectSwapFees(CORE, auction, poolKey, salt);
            ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, address(this), amount0, amount1);
            result = abi.encode(amount0, amount1);
        }
    }

    /// @dev Pays a positive debt from this contract's balance and withdraws a credit to this contract.
    function _settle(address token, int256 delta) private {
        if (delta > 0) {
            if (token == NATIVE_TOKEN_ADDRESS) SafeTransferLib.safeTransferETH(address(ACCOUNTANT), uint256(delta));
            else ACCOUNTANT.pay(token, uint256(delta));
        } else if (delta < 0) {
            ACCOUNTANT.withdraw(token, address(this), SafeCastLib.toUint128(uint256(-delta)));
        }
    }
}
