// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {ICore} from "../interfaces/ICore.sol";
import {
    AUCTION_COLLECT_RENT,
    AUCTION_COLLECT_SWAP_FEES,
    AUCTION_FUNDS_SAVED_BALANCE_ID,
    AUCTION_SAVED_BALANCE_PAIR_TOKEN,
    AUCTION_UPDATE_BID,
    IContinuousAuction
} from "../interfaces/extensions/IContinuousAuction.sol";
import {ContinuousAuctionLib} from "../libraries/ContinuousAuctionLib.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {CoreStorageLayout} from "../libraries/CoreStorageLayout.sol";
import {ExposedStorageLib} from "../libraries/ExposedStorageLib.sol";
import {MIN_TICK, MAX_TICK} from "../math/constants.sol";
import {computeFee, amountBeforeFee} from "../math/fee.sol";
import {addLiquidityDelta} from "../math/liquidity.sol";
import {isPowerOfFour} from "../math/isPowerOfFour.sol";
import {CallPoints} from "../types/callPoints.sol";
import {Locker} from "../types/locker.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PositionId} from "../types/positionId.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";

function continuousAuctionCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: true,
        afterInitializePool: false,
        beforeSwap: true,
        afterSwap: false,
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}

/// @notice Continuous first-price auction of privileged swap access to pools whose liquidity providers are paid
/// rent in a single immutable bid token.
/// @dev Everything happens through Core forward calls and is keyed by the forwarding locker. The holder's named
/// executor swaps fee-free; any other locker may swap while the pool is rented and pays the holder's fee. Rent
/// accrues per second to liquidity active over time. A bid is set with one operation that replaces the locker's
/// scheduled bid from the next second on; its funding is a Core saved balance of this extension, so the locker
/// pays or withdraws the difference in the same lock. Without a live bid the pool does not swap. Rent charged
/// while no liquidity is active is never refunded. Any pool naming this extension with a zero Core fee may be
/// initialized directly through Core. The extension has no terms: its parameters are Core and the bid token.
contract ContinuousAuction is IContinuousAuction, BaseExtension, BaseForwardee, ReentrancyGuardTransient {
    using CoreLib for *;
    using ExposedStorageLib for *;

    address public immutable bidToken;

    struct Bid {
        // keccak256(abi.encode(locker, salt)); never zero for a real bid.
        bytes32 bidder;
        uint96 rate;
        address executor;
        uint48 start;
        uint48 end;
        // A 0.32 fixed-point fraction: the upper 32 bits of Core's 0.64 fee format.
        uint32 fee;
    }

    struct Auction {
        Bid current;
        // Only nonempty within the second it was placed; promoted by the next settlement.
        Bid next;
        uint48 lastSettled;
        // Scaled division leftover carried to the next settlement. Packs with `lastSettled`,
        // so it costs no additional storage slot.
        uint128 accrualRemainder;
        uint256 growth;
    }

    struct PositionRent {
        uint256 snapshot;
        uint256 owed;
    }

    mapping(PoolId => Auction) public auctions;
    /// @notice Bid-token credit of a bidder from displaced tenure, netted into its next bid update.
    mapping(bytes32 => uint256) public refundable;
    // NOTE: rent charged while no liquidity is active is discarded (still logged as
    // `RentUnallocated`) rather than counted, so it needs no storage.
    /// @notice Promised rate of the most recently displaced same-start pending bid. Binds every
    /// replacement for that start (including cancel-and-rebid by the displacer) until the second
    /// passes; keyed by start so stale entries expire on their own and no clearing is needed.
    mapping(PoolId => uint96) public pendingFloorRate;
    /// @notice Activation second the pending floor applies to. See `pendingFloorRate`.
    mapping(PoolId => uint48) public pendingFloorStart;
    mapping(PoolId => mapping(int32 => uint256)) public growthOutside;
    mapping(PoolId => mapping(address => mapping(PositionId => PositionRent))) public positionRent;

    error InvalidBidToken();
    error InvalidPool();
    error InvalidBid();
    error BidTooLow();
    error PoolClosed();
    error SwapMustHappenThroughForward();

    event BidUpdated(
        PoolId indexed poolId,
        address indexed locker,
        bytes32 salt,
        uint96 rate,
        uint48 start,
        uint48 end,
        address executor,
        uint32 fee,
        int256 delta
    );
    event RefundCredited(bytes32 indexed bidder, uint256 amount);
    event RentAccrued(PoolId indexed poolId, uint256 amount);
    event RentUnallocated(PoolId indexed poolId, uint256 amount);
    event RentCollected(PoolId indexed poolId, address indexed owner, PositionId positionId, uint256 amount);
    event SwapFeeCharged(PoolId indexed poolId, bytes32 indexed bidder, uint128 amount0, uint128 amount1);
    event SwapFeesCollected(
        PoolId indexed poolId, address indexed locker, bytes32 salt, uint128 amount0, uint128 amount1
    );

    constructor(ICore core, address _bidToken) BaseExtension(core) BaseForwardee(core) {
        if (_bidToken >= AUCTION_SAVED_BALANCE_PAIR_TOKEN) revert InvalidBidToken();
        bidToken = _bidToken;
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return continuousAuctionCallPoints();
    }

    function _validate(PoolKey memory key) private view {
        if (key.config.extension() != address(this) || key.config.fee() != 0) revert InvalidPool();
        if (key.config.isConcentrated() && !isPowerOfFour(key.config.concentratedTickSpacing())) {
            revert InvalidPool();
        }
    }

    function beforeInitializePool(address, PoolKey memory key, int32) external view override onlyCore {
        _validate(key);
    }

    function beforeSwap(Locker, PoolKey memory, SwapParameters) external pure override {
        revert SwapMustHappenThroughForward();
    }

    /// FORWARD INTERFACE

    /// @dev Dispatches on the first word. Call types are hashes, so they never collide with a swap payload's
    /// token0 address.
    function handleForwardData(Locker original, bytes memory data)
        internal
        override
        nonReentrant
        returns (bytes memory result)
    {
        uint256 callType;
        assembly ("memory-safe") {
            callType := mload(add(data, 0x20))
        }
        address locker = original.addr();

        if (callType == AUCTION_UPDATE_BID) {
            (, PoolKey memory key, bytes32 salt, uint96 rate, uint64 end, address executor, uint32 fee) =
                abi.decode(data, (uint256, PoolKey, bytes32, uint96, uint64, address, uint32));
            result = abi.encode(_updateBid(key, locker, salt, rate, end, executor, fee));
        } else if (callType == AUCTION_COLLECT_RENT) {
            (, PoolKey memory key, PositionId positionId) = abi.decode(data, (uint256, PoolKey, PositionId));
            result = abi.encode(_collectRent(key, locker, positionId));
        } else if (callType == AUCTION_COLLECT_SWAP_FEES) {
            (, PoolKey memory key, bytes32 salt) = abi.decode(data, (uint256, PoolKey, bytes32));
            (uint128 amount0, uint128 amount1) = _collectSwapFees(key, locker, salt);
            result = abi.encode(amount0, amount1);
        } else {
            (PoolKey memory key, SwapParameters params) = _decodeSwap(data);
            (PoolBalanceUpdate update, PoolState after_) = _swap(key, locker, params);
            result = abi.encode(update, after_);
        }
    }

    /// @dev Decodes the fixed-size swap payload without copying its pool key, keeping abi.decode's checks.
    function _decodeSwap(bytes memory data) private pure returns (PoolKey memory poolKey, SwapParameters params) {
        assembly ("memory-safe") {
            if lt(mload(data), 0x80) { revert(0, 0) }
            poolKey := add(data, 0x20)
            if or(shr(160, mload(poolKey)), shr(160, mload(add(poolKey, 0x20)))) { revert(0, 0) }
            params := mload(add(poolKey, 0x60))
        }
    }

    /// BIDDING

    /// @notice Sets the locker's bid for [timestamp+1, end): rate base units per second, the authorized executor,
    /// and the fee charged to other swappers. Rate zero removes the locker's scheduled bid.
    /// @dev The locker's previous schedule is credited back and any outstanding credit is netted, so the returned
    /// delta is the net bid-token amount the locker owes (positive) or may withdraw (negative). Another locker's
    /// scheduled bid is displaced only by a strictly higher rate. Displacement of the live incumbent takes
    /// effect at activation, when its relinquished tenure is credited; a displaced pending bid is credited
    /// immediately since its tenure never started, but its promised rate binds same-start replacements.
    /// The executor is a Core locker, NOT tx.origin, and must authenticate its own callers.
    function _updateBid(
        PoolKey memory key,
        address locker,
        bytes32 salt,
        uint96 rate,
        uint64 end,
        address executor,
        uint32 fee
    ) private returns (int256 delta) {
        _validate(key);
        PoolId poolId = key.toPoolId();
        PoolState state = CORE.poolState(poolId);
        if (!state.isInitialized()) revert InvalidPool();
        _accrue(poolId, state.liquidity());
        if (block.timestamp >= type(uint48).max) revert InvalidBid();
        uint48 start = uint48(block.timestamp + 1);
        bytes32 bidder = ContinuousAuctionLib.bidderId(locker, salt);
        Auction storage auction = auctions[poolId];

        uint256 cost;
        if (rate != 0) {
            if (executor == address(0)) revert InvalidBid();
            _checkEnd(end, start);
            cost = uint256(rate) * (end - start);
        }

        // Every new bid must strictly beat every other live schedule covering its start: a
        // same-second pending bid and/or the live incumbent. Displacement takes effect at activation
        // (see _accrue), so the incumbent is never truncated here and cancelling is always harmless.
        // A killed pending promise still binds same-start replacements through the floor below.
        Bid storage scheduled = auction.next.bidder != bytes32(0) ? auction.next : auction.current;
        bool live = scheduled.end > start;
        bool own = live && scheduled.bidder == bidder;
        // A live schedule of yours counts as yours even when someone else holds a pending bid on
        // top of it: a pending bid must never silently veto your exit.
        bool ownLive = auction.current.bidder == bidder && auction.current.end > start;
        if (rate != 0) {
            if (live && !own && rate <= scheduled.rate) revert BidTooLow();
            if (auction.current.bidder != bidder && auction.current.end > start && rate <= auction.current.rate) {
                revert BidTooLow();
            }
            uint96 floor = pendingFloorRate[poolId];
            if (floor != 0 && start == pendingFloorStart[poolId] && rate <= floor) revert BidTooLow();
        }

        uint256 credit = refundable[bidder];
        if (credit != 0) delete refundable[bidder];

        if (rate != 0 || own || ownLive) {
            Bid storage next = auction.next;
            if (next.bidder != bytes32(0) && (rate != 0 || next.bidder == bidder)) {
                if (next.bidder != bidder) {
                    // Replacing another bidder's pending bid fully refunds them: their tenure never
                    // started. Their promised rate binds same-start replacements (see floor), so a
                    // transient high bid cannot be followed by a low one. Only a live promise binds.
                    if (rate != 0 && next.end > start) {
                        pendingFloorRate[poolId] = next.rate;
                        pendingFloorStart[poolId] = start;
                    }
                    credit += _credit(next.bidder, bidder, uint256(next.rate) * (next.end - next.start));
                } else {
                    credit += uint256(next.rate) * (next.end - next.start);
                }
                delete auction.next;
            }
            Bid storage current = auction.current;
            if (current.bidder == bidder && current.end > start) {
                // Shortening your own live schedule nets the relinquished tenure immediately.
                // Another bidder's schedule is only displaced at activation and needs no handling here.
                credit += uint256(current.rate) * (current.end - start);
                current.end = start;
            }
            if (rate != 0) auction.next = Bid(bidder, rate, executor, start, uint48(end), fee);
        }

        delta = int256(cost) - int256(credit);
        if (delta != 0) {
            CORE.updateSavedBalances(
                bidToken, AUCTION_SAVED_BALANCE_PAIR_TOKEN, AUCTION_FUNDS_SAVED_BALANCE_ID, delta, 0
            );
        }
        emit BidUpdated(poolId, locker, salt, rate, start, uint48(end), executor, fee, delta);
    }

    /// @dev Returns the amount when it belongs to the acting bidder, else records it as that bidder's credit.
    function _credit(bytes32 owner, bytes32 acting, uint256 amount) private returns (uint256 netted) {
        if (owner == acting) return amount;
        if (amount != 0) {
            refundable[owner] += amount;
            emit RefundCredited(owner, amount);
        }
    }

    /// @dev Rent between settlements must fit uint128 for the Q128 growth update. Every bid update settles
    /// first, the pending bid overlaps the incumbent for one second, and rates fit uint96, so bounding the
    /// tenure below 2**32 seconds keeps the rent of any settlement window below 2**128.
    function _checkEnd(uint64 end, uint48 from) private pure {
        if (end <= from || end - from > type(uint32).max || end > type(uint48).max) revert InvalidBid();
    }

    /// @dev The bid holding the pool now, if any. Before settlement a pending bid may already be live.
    function _activeBid(Auction storage auction) private view returns (Bid storage active, bool live) {
        active = auction.next;
        if (active.bidder == bytes32(0) || active.start > block.timestamp) active = auction.current;
        live = active.start <= block.timestamp && block.timestamp < active.end;
    }

    /// @notice Returns the bid currently holding the pool, or an empty bid.
    function holder(PoolId poolId) external view returns (Bid memory) {
        (Bid storage active, bool live) = _activeBid(auctions[poolId]);
        if (live) return active;
    }

    /// @notice Returns the currently authorized fee-free locker, or zero if the pool is not rented.
    function executorAt(PoolId poolId) public view returns (address executor) {
        (Bid storage active, bool live) = _activeBid(auctions[poolId]);
        if (live) executor = active.executor;
    }

    /// RENT SETTLEMENT

    /// @notice Accrues rent without requiring a swap or a position operation.
    function accrue(PoolKey calldata key) external nonReentrant {
        _validate(key);
        PoolId poolId = key.toPoolId();
        _accrue(poolId, CORE.poolState(poolId).liquidity());
    }

    function _rentBetween(Bid storage b, uint48 from, uint48 to) private view returns (uint256) {
        uint48 lo = b.start > from ? b.start : from;
        uint48 hi = b.end < to ? b.end : to;
        return hi > lo ? uint256(b.rate) * (hi - lo) : 0;
    }

    function _accrue(PoolId poolId, uint128 liquidity) private {
        Auction storage auction = auctions[poolId];
        uint48 now_ = uint48(block.timestamp);
        uint48 from = auction.lastSettled;
        if (from == now_) return;
        // After the uint48 timestamp boundary, time wraps backward. Settle nothing rather than
        // promoting pending state or attributing rent over an empty interval.
        if (now_ < from) return;
        uint256 rent;
        if (auction.next.bidder != bytes32(0) && now_ >= auction.next.start) {
            // The pending bid was placed at `from`, so it activates now. Clamp the incumbent to the
            // handover (it was never truncated at placement) and credit its relinquished tail.
            uint48 handover = auction.next.start;
            rent = _rentBetween(auction.current, from, handover) + _rentBetween(auction.next, from, now_);
            bytes32 outgoing = auction.current.bidder;
            uint256 tail;
            if (outgoing != bytes32(0) && auction.current.end > handover) {
                tail = uint256(auction.current.rate) * (auction.current.end - handover);
            }
            auction.current = auction.next;
            delete auction.next;
            if (tail != 0) {
                refundable[outgoing] += tail;
                emit RefundCredited(outgoing, tail);
            }
        } else {
            rent = _rentBetween(auction.current, from, now_);
        }
        auction.lastSettled = now_;
        if (rent != 0) {
            if (liquidity == 0) {
                // Access costs rent independently of where the executor leaves the price. Do not award
                // empty-interval rent to a later depositor or refund it to the holder who moved the price.
                // It is discarded, not counted.
                emit RentUnallocated(poolId, rent);
            } else {
                unchecked {
                    // rent < 2**128, see _checkEnd.
                    // The scaled remainder is carried so settling short intervals cannot strand rent.
                    uint256 scaled = (rent << 128) + auction.accrualRemainder;
                    uint256 step = scaled / liquidity;
                    auction.accrualRemainder = uint128(scaled % liquidity);
                    auction.growth += step;
                }
                emit RentAccrued(poolId, rent);
            }
        }
    }

    /// SWAPS

    function _swap(PoolKey memory key, address locker, SwapParameters params)
        private
        returns (PoolBalanceUpdate update, PoolState after_)
    {
        _validate(key);
        PoolId poolId = key.toPoolId();
        Auction storage auction = auctions[poolId];
        PoolState before_ = CORE.poolState(poolId);
        _accrue(poolId, before_.liquidity());
        (Bid storage active, bool live) = _activeBid(auction);
        if (!live) revert PoolClosed();
        (update, after_) = CORE.swap(0, key, params);
        if (locker != active.executor) {
            update = _chargeSwapFee(key, poolId, active.bidder, params, update, uint64(active.fee) << 32);
        }
        if (key.config.isConcentrated()) {
            _cross(poolId, before_.tick(), after_.tick(), key.config.concentratedTickSpacing(), params.skipAhead());
        }
    }

    /// @dev Charges the holder's fee on the swapper's output, or on its input for exact-output swaps, and saves
    /// it for the holder in Core under the bidder's salt.
    function _chargeSwapFee(
        PoolKey memory key,
        PoolId poolId,
        bytes32 bidder,
        SwapParameters params,
        PoolBalanceUpdate update,
        uint64 fee
    ) private returns (PoolBalanceUpdate) {
        int128 delta0 = update.delta0();
        int128 delta1 = update.delta1();
        uint128 fee0;
        uint128 fee1;
        if (params.isExactOut()) {
            if (delta0 > 0) {
                int128 withFee = SafeCastLib.toInt128(amountBeforeFee(uint128(delta0), fee));
                fee0 = uint128(withFee - delta0);
                delta0 = withFee;
            } else if (delta1 > 0) {
                int128 withFee = SafeCastLib.toInt128(amountBeforeFee(uint128(delta1), fee));
                fee1 = uint128(withFee - delta1);
                delta1 = withFee;
            }
        } else {
            if (delta0 < 0) {
                fee0 = computeFee(_abs(delta0), fee);
                delta0 += int128(fee0);
            } else if (delta1 < 0) {
                fee1 = computeFee(_abs(delta1), fee);
                delta1 += int128(fee1);
            }
        }
        if (fee0 != 0 || fee1 != 0) {
            CORE.updateSavedBalances(
                key.token0, key.token1, _feeSalt(poolId, bidder), int256(uint256(fee0)), int256(uint256(fee1))
            );
            emit SwapFeeCharged(poolId, bidder, fee0, fee1);
        }
        return createPoolBalanceUpdate(delta0, delta1);
    }

    function _feeSalt(PoolId poolId, bytes32 bidder) private pure returns (bytes32) {
        return keccak256(abi.encode(poolId, bidder));
    }

    /// @dev Unsigned magnitude of a signed delta. Negating type(int128).min overflows, but its
    /// magnitude 2**127 fits in uint128 and the resulting fee stays below it, so the adjusted
    /// delta still fits int128.
    function _abs(int128 x) private pure returns (uint128) {
        return x == type(int128).min ? uint128(1) << 127 : uint128(-x);
    }

    function _savedFees(PoolKey memory key, bytes32 salt) private view returns (uint128 amount0, uint128 amount1) {
        uint256 packed =
            uint256(CORE.sload(CoreStorageLayout.savedBalancesSlot(address(this), key.token0, key.token1, salt)));
        amount0 = uint128(packed >> 128);
        amount1 = uint128(packed);
    }

    /// @notice Swap fees owed to a bidder for a pool, in the pool's tokens.
    function swapFeesOwed(PoolKey calldata key, address locker, bytes32 salt)
        external
        view
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = _savedFees(key, _feeSalt(key.toPoolId(), ContinuousAuctionLib.bidderId(locker, salt)));
    }

    /// @dev Moves the bidder's saved fees to the forwarding locker, which withdraws them.
    function _collectSwapFees(PoolKey memory key, address locker, bytes32 salt)
        private
        returns (uint128 amount0, uint128 amount1)
    {
        PoolId poolId = key.toPoolId();
        bytes32 feeSalt = _feeSalt(poolId, ContinuousAuctionLib.bidderId(locker, salt));
        (amount0, amount1) = _savedFees(key, feeSalt);
        if (amount0 != 0 || amount1 != 0) {
            CORE.updateSavedBalances(
                key.token0, key.token1, feeSalt, -int256(uint256(amount0)), -int256(uint256(amount1))
            );
        }
        emit SwapFeesCollected(poolId, locker, salt, amount0, amount1);
    }

    /// LIQUIDITY PROVIDER RENT

    function _liquidity(PoolId poolId, address owner, PositionId positionId) private view returns (uint128) {
        return ContinuousAuctionLib.positionLiquidity(CORE, poolId, owner, positionId);
    }

    function _inside(PoolKey memory key, PositionId positionId, int32 tick) private view returns (uint256 value) {
        PoolId poolId = key.toPoolId();
        if (key.config.isStableswap()) return auctions[poolId].growth;
        uint256 lower = growthOutside[poolId][positionId.tickLower()];
        uint256 upper = growthOutside[poolId][positionId.tickUpper()];
        unchecked {
            if (tick < positionId.tickLower()) return lower - upper;
            if (tick < positionId.tickUpper()) return auctions[poolId].growth - lower - upper;
            return upper - lower;
        }
    }

    function _checkpoint(PoolKey memory key, address owner, PositionId positionId, int32 tick, uint128 liquidity)
        private
    {
        PositionRent storage rent = positionRent[key.toPoolId()][owner][positionId];
        uint256 inside = _inside(key, positionId, tick);
        if (liquidity != 0) {
            uint256 delta;
            unchecked {
                delta = inside - rent.snapshot;
            }
            rent.owed += FixedPointMathLib.fullMulDivN(delta, liquidity, 128);
        }
        rent.snapshot = inside;
    }

    function beforeUpdatePosition(Locker locker, PoolKey memory key, PositionId positionId, int128 delta)
        external
        override
        onlyCore
        nonReentrant
    {
        PoolId poolId = key.toPoolId();
        PoolState state = CORE.poolState(poolId);
        _accrue(poolId, state.liquidity());
        uint128 liquidity = _liquidity(poolId, locker.addr(), positionId);
        if (liquidity != 0) _checkpoint(key, locker.addr(), positionId, state.tick(), liquidity);
        bool changed;
        if (delta != 0 && key.config.isConcentrated()) {
            bool lowerChanged = _updateTick(poolId, positionId.tickLower(), delta);
            bool upperChanged = _updateTick(poolId, positionId.tickUpper(), delta);
            changed = lowerChanged || upperChanged;
        }
        // Boundary initialization/deletion changes the coordinate system, not accrued rent.
        // Existing positions with unchanged boundaries already took this snapshot in _checkpoint.
        if (liquidity == 0 || changed) {
            positionRent[poolId][locker.addr()][positionId].snapshot = _inside(key, positionId, state.tick());
        }
    }

    /// @dev Moves the position's earned rent to the forwarding locker, which withdraws the bid token.
    function _collectRent(PoolKey memory key, address owner, PositionId positionId) private returns (uint256 amount) {
        _validate(key);
        PoolId poolId = key.toPoolId();
        PoolState state = CORE.poolState(poolId);
        _accrue(poolId, state.liquidity());
        _checkpoint(key, owner, positionId, state.tick(), _liquidity(poolId, owner, positionId));
        PositionRent storage rent = positionRent[poolId][owner][positionId];
        amount = rent.owed;
        if (amount != 0) {
            rent.owed = 0;
            CORE.updateSavedBalances(
                bidToken, AUCTION_SAVED_BALANCE_PAIR_TOKEN, AUCTION_FUNDS_SAVED_BALANCE_ID, -int256(amount), 0
            );
        }
        emit RentCollected(poolId, owner, positionId, amount);
    }

    /// @notice Claimable rent using already-accrued state. Call accrue first to include elapsed rent.
    function getPositionRent(PoolKey calldata key, address owner, PositionId positionId)
        external
        view
        returns (uint256 amount)
    {
        _validate(key);
        PoolId poolId = key.toPoolId();
        PositionRent storage rent = positionRent[poolId][owner][positionId];
        amount = rent.owed;
        uint128 liquidity = _liquidity(poolId, owner, positionId);
        if (liquidity != 0) {
            uint256 delta;
            unchecked {
                delta = _inside(key, positionId, CORE.poolState(poolId).tick()) - rent.snapshot;
            }
            amount += FixedPointMathLib.fullMulDivN(delta, liquidity, 128);
        }
    }

    // Mirrors Ve33's range-aware external-reward accounting, including nonzero tick sentinels.
    function _updateTick(PoolId poolId, int32 tick, int128 delta) private returns (bool changed) {
        (, uint128 gross) = CORE.poolTicks(poolId, tick);
        uint128 next = addLiquidityDelta(gross, delta);
        changed = (gross == 0) != (next == 0);
        if (changed) growthOutside[poolId][tick] = gross == 0 ? 1 : 0;
    }

    function _cross(PoolId poolId, int32 before_, int32 after_, uint32 spacing, uint256 skip) private {
        if (before_ == after_) return;
        // Concentrated spacing is a power of four. Biasing signed ticks by 2**31 preserves its grid
        // while giving floor division for negative ticks. No initialized tick exists inside a cell.
        if (uint256(int256(before_) + 0x80000000) / spacing == uint256(int256(after_) + 0x80000000) / spacing) {
            return;
        }
        uint256 global = auctions[poolId].growth;
        int32 tick = before_;
        if (after_ < before_) {
            while (true) {
                bool initialized;
                (tick, initialized) = CORE.prevInitializedTick(poolId, tick, spacing, skip);
                if (tick <= after_) break;
                unchecked {
                    if (initialized) growthOutside[poolId][tick] = global - growthOutside[poolId][tick];
                    if (tick == MIN_TICK) break;
                    --tick;
                }
            }
        } else {
            while (true) {
                bool initialized;
                (tick, initialized) = CORE.nextInitializedTick(poolId, tick, spacing, skip);
                if (tick > after_) break;
                unchecked {
                    if (initialized) growthOutside[poolId][tick] = global - growthOutside[poolId][tick];
                    if (tick == MAX_TICK) break;
                }
            }
        }
    }
}
