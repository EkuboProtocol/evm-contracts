// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {ICore} from "../interfaces/ICore.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {CoreStorageLayout} from "../libraries/CoreStorageLayout.sol";
import {ExposedStorageLib} from "../libraries/ExposedStorageLib.sol";
import {MIN_TICK, MAX_TICK, NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {addLiquidityDelta} from "../math/liquidity.sol";
import {isPowerOfFour} from "../math/isPowerOfFour.sol";
import {isTimeValid} from "../math/time.sol";
import {CallPoints} from "../types/callPoints.sol";
import {Locker} from "../types/locker.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PositionId} from "../types/positionId.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
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

/// @notice Fully funded, continuous first-price auction of exclusive access to zero-fee pools.
/// @dev Rent is denominated in immutable bidToken (address(0) means native). A bid starts at timestamp+1
/// and cannot execute until a later block. This is next-block activation on chains with one-second blocks;
/// same-timestamp blocks do not activate bids. Rent accrues at the scheduled time even across missed blocks.
/// Displaced intervals are refunded, but lower-rate funded tails remain scheduled. End times use TWAMM's
/// grid, bounding the surviving future endpoints. Rent is charged even without active liquidity; such
/// rent is permanently unallocated, never refunded or gifted to a later liquidity provider.
contract ContinuousAuction is BaseExtension, BaseForwardee, ReentrancyGuardTransient {
    using CoreLib for *;
    using ExposedStorageLib for *;

    address public immutable bidToken;

    struct Segment {
        address bidder;
        uint96 rate;
        address executor;
        uint48 start;
        uint48 end;
        uint64 activationBlock;
        uint64 next;
    }

    struct Auction {
        uint64 head;
        uint48 lastSettled;
        uint256 growth;
    }

    struct PositionFees {
        uint256 snapshot;
        uint256 owed;
    }

    uint64 public nextSegmentId;
    mapping(uint64 => Segment) public segments;
    mapping(PoolId => Auction) public auctions;
    mapping(address => uint256) public refundable;
    mapping(PoolId => uint256) public unallocatedRent;
    mapping(PoolId => mapping(int32 => uint256)) public growthOutside;
    mapping(PoolId => mapping(address => mapping(PositionId => PositionFees))) public positionFees;

    error InvalidPool();
    error InvalidBid();
    error BidTooLow();
    error IncorrectFunding();
    error SwapMustHappenThroughForward();
    error UnauthorizedExecutor();

    event BidPlaced(
        PoolId indexed poolId,
        uint256 indexed segmentId,
        address indexed bidder,
        address executor,
        uint96 rate,
        uint64 start,
        uint64 end
    );
    event RefundCredited(address indexed bidder, uint256 amount);
    event RefundWithdrawn(address indexed bidder, address indexed recipient, uint256 amount);
    event RentAccrued(PoolId indexed poolId, uint256 amount);
    event RentUnallocated(PoolId indexed poolId, uint256 amount);
    event FeesCollected(
        PoolId indexed poolId, address indexed owner, PositionId positionId, address recipient, uint256 amount
    );

    constructor(ICore core, address _bidToken) BaseExtension(core) BaseForwardee(core) {
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

    function beforeInitializePool(address, PoolKey memory key, int32) external override onlyCore {
        _validate(key);
    }

    function beforeSwap(Locker, PoolKey memory, SwapParameters) external pure override {
        revert SwapMustHappenThroughForward();
    }

    /// @notice Buys the interval [timestamp+1,end) at rate base units/second, replacing lower bids.
    /// @dev Executor is the authorized Core locker, NOT tx.origin. It must authenticate its own callers.
    /// Full native funding or ERC20 allowance is required; native excess becomes refundable credit.
    /// There is no cancellation or voluntary rate reduction.
    function bid(PoolKey calldata key, uint96 rate, uint64 end, address executor)
        external
        payable
        nonReentrant
        returns (uint64 id)
    {
        _validate(key);
        PoolId poolId = key.toPoolId();
        PoolState state = CORE.poolState(poolId);
        if (!state.isInitialized()) revert InvalidPool();
        if (block.timestamp >= type(uint48).max || end > type(uint48).max || block.number >= type(uint64).max) {
            revert InvalidBid();
        }
        uint48 start = uint48(block.timestamp + 1);
        if (rate == 0 || executor == address(0) || end <= start || !isTimeValid(block.timestamp, end)) {
            revert InvalidBid();
        }
        _accrue(poolId, state.liquidity());
        Auction storage auction = auctions[poolId];
        uint64 cursor = auction.head;
        uint64 prefix;

        // Check price before any schedule writes. An expiring incumbent need not be outbid.
        if (cursor != 0) {
            uint64 candidate = segments[cursor].end <= start ? segments[cursor].next : cursor;
            if (candidate != 0 && rate <= segments[candidate].rate) revert BidTooLow();
        }

        // Preserve the current holder until the next activation boundary. Splitting retains its funded tail.
        if (cursor != 0 && segments[cursor].start < start) {
            Segment storage current = segments[cursor];
            prefix = cursor;
            cursor = current.next;
            if (current.end > start) {
                uint48 until = current.end < end ? current.end : uint48(end);
                _credit(current.bidder, uint256(current.rate) * (until - start));
                // Only materialize a surviving tail, not a temporary node immediately deleted below.
                if (current.end > end) {
                    uint64 tail = ++nextSegmentId;
                    segments[tail] = current;
                    segments[tail].start = uint48(end);
                    cursor = tail;
                }
                current.end = start;
            }
        }

        uint256 funding = uint256(rate) * (end - start);
        if (bidToken == NATIVE_TOKEN_ADDRESS) {
            if (msg.value < funding) revert IncorrectFunding();
            _credit(msg.sender, msg.value - funding);
        } else {
            if (msg.value != 0) revert IncorrectFunding();
            uint256 balance = SafeTransferLib.balanceOf(bidToken, address(this));
            SafeTransferLib.safeTransferFrom(bidToken, msg.sender, address(this), funding);
            if (SafeTransferLib.balanceOf(bidToken, address(this)) - balance != funding) revert IncorrectFunding();
        }

        // The post-activation suffix has decreasing rates and increasing ends. Permanently refund overlap.
        while (cursor != 0 && segments[cursor].start < end) {
            Segment storage displaced = segments[cursor];
            uint64 until = displaced.end < end ? displaced.end : end;
            _credit(displaced.bidder, uint256(displaced.rate) * (until - displaced.start));
            if (displaced.end > end) {
                displaced.start = uint48(end);
                break;
            }
            uint64 next = displaced.next;
            delete segments[cursor];
            cursor = next;
        }

        id = ++nextSegmentId;
        segments[id] = Segment(msg.sender, rate, executor, start, uint48(end), uint64(block.number + 1), cursor);
        if (prefix == 0) auction.head = id;
        else segments[prefix].next = id;
        emit BidPlaced(poolId, id, msg.sender, executor, rate, start, end);
    }

    function _credit(address bidder, uint256 amount) private {
        if (amount != 0) {
            refundable[bidder] += amount;
            emit RefundCredited(bidder, amount);
        }
    }

    /// @notice Withdraws displaced funding and excess native payments owned by the caller.
    function withdrawRefund(address recipient) external nonReentrant returns (uint256 amount) {
        amount = refundable[msg.sender];
        delete refundable[msg.sender];
        _pay(recipient, amount);
        emit RefundWithdrawn(msg.sender, recipient, amount);
    }

    function _pay(address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (bidToken == NATIVE_TOKEN_ADDRESS) SafeTransferLib.safeTransferETH(recipient, amount);
        else SafeTransferLib.safeTransfer(bidToken, recipient, amount);
    }

    /// @notice Returns the currently authorized locker, or zero if the auction has no active bid.
    function executorAt(PoolId poolId) public view returns (address executor) {
        uint64 cursor = auctions[poolId].head;
        while (cursor != 0 && segments[cursor].end <= block.timestamp) cursor = segments[cursor].next;
        if (cursor != 0) {
            Segment storage s = segments[cursor];
            if (s.start <= block.timestamp && s.activationBlock <= block.number) executor = s.executor;
        }
    }

    /// @notice Accrues rent without requiring a swap or a position operation.
    function accrue(PoolKey calldata key) external nonReentrant {
        _validate(key);
        PoolId poolId = key.toPoolId();
        _accrue(poolId, CORE.poolState(poolId).liquidity());
    }

    function _accrue(PoolId poolId, uint128 liquidity) private {
        Auction storage auction = auctions[poolId];
        uint48 now_ = uint48(block.timestamp);
        uint48 from = auction.lastSettled;
        if (from == now_) return;
        uint64 cursor = auction.head;
        uint256 rent;
        while (cursor != 0) {
            Segment storage s = segments[cursor];
            if (s.start >= now_) break;
            uint64 start = s.start > from ? s.start : from;
            uint64 end = s.end < now_ ? s.end : now_;
            if (end > start) {
                rent += uint256(s.rate) * (end - start);
            }
            if (s.end > now_) break;
            uint64 next = s.next;
            delete segments[cursor];
            cursor = next;
        }
        auction.head = cursor;
        auction.lastSettled = now_;
        if (rent != 0) {
            if (liquidity == 0) {
                // Access costs rent independently of where the executor leaves the price. Do not award
                // empty-interval rent to a later depositor or refund it to the holder who moved the price.
                unallocatedRent[poolId] += rent;
                emit RentUnallocated(poolId, rent);
            } else {
                unchecked {
                    // Every bid settles first. Remaining ends are < 2**32 seconds away, and rates fit uint96,
                    // so rent between settlements fits uint128, including multiple expired tails.
                    auction.growth += (rent << 128) / liquidity;
                }
                emit RentAccrued(poolId, rent);
            }
        }
    }

    function handleForwardData(Locker original, bytes memory data)
        internal
        override
        nonReentrant
        returns (bytes memory result)
    {
        (PoolKey memory key, SwapParameters params) = abi.decode(data, (PoolKey, SwapParameters));
        _validate(key);
        PoolId poolId = key.toPoolId();
        PoolState before_ = CORE.poolState(poolId);
        _accrue(poolId, before_.liquidity());
        if (original.addr() != executorAt(poolId) || original.addr() == address(0)) revert UnauthorizedExecutor();
        (PoolBalanceUpdate update, PoolState after_) = CORE.swap(0, key, params);
        if (key.config.isConcentrated()) {
            _cross(poolId, before_.tick(), after_.tick(), key.config.concentratedTickSpacing(), params.skipAhead());
        }
        result = abi.encode(update, after_);
    }

    function _liquidity(PoolId poolId, address owner, PositionId positionId) private view returns (uint128) {
        return uint128(uint256(CORE.sload(CoreStorageLayout.poolPositionsSlot(poolId, owner, positionId))) >> 128);
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
        PositionFees storage fees = positionFees[key.toPoolId()][owner][positionId];
        uint256 inside = _inside(key, positionId, tick);
        if (liquidity != 0) {
            uint256 delta;
            unchecked {
                delta = inside - fees.snapshot;
            }
            fees.owed += FixedPointMathLib.fullMulDivN(delta, liquidity, 128);
        }
        fees.snapshot = inside;
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
        // Boundary initialization/deletion changes the coordinate system, not accrued fees.
        // Existing positions with unchanged boundaries already took this snapshot in _checkpoint.
        if (liquidity == 0 || changed) {
            positionFees[poolId][locker.addr()][positionId].snapshot = _inside(key, positionId, state.tick());
        }
    }

    /// @notice Collects auction fees for a Core position owned by msg.sender, including after full withdrawal.
    function collectFees(PoolKey calldata key, PositionId positionId, address recipient)
        external
        nonReentrant
        returns (uint256 amount)
    {
        _validate(key);
        PoolId poolId = key.toPoolId();
        PoolState state = CORE.poolState(poolId);
        _accrue(poolId, state.liquidity());
        _checkpoint(key, msg.sender, positionId, state.tick(), _liquidity(poolId, msg.sender, positionId));
        PositionFees storage fees = positionFees[poolId][msg.sender][positionId];
        amount = fees.owed;
        fees.owed = 0;
        _pay(recipient, amount);
        emit FeesCollected(poolId, msg.sender, positionId, recipient, amount);
    }

    /// @notice Claimable fees using already-accrued state. Call accrue first to include elapsed rent.
    function getPositionFees(PoolKey calldata key, address owner, PositionId positionId)
        external
        view
        returns (uint256 amount)
    {
        _validate(key);
        PoolId poolId = key.toPoolId();
        PositionFees storage fees = positionFees[poolId][owner][positionId];
        amount = fees.owed;
        uint128 liquidity = _liquidity(poolId, owner, positionId);
        if (liquidity != 0) {
            uint256 delta;
            unchecked {
                delta = _inside(key, positionId, CORE.poolState(poolId).tick()) - fees.snapshot;
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
