// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {ICore} from "../interfaces/ICore.sol";
import {IFlashAccountant} from "../interfaces/IFlashAccountant.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {CoreStorageLayout} from "../libraries/CoreStorageLayout.sol";
import {ExposedStorageLib} from "../libraries/ExposedStorageLib.sol";
import {FlashAccountantLib} from "../libraries/FlashAccountantLib.sol";
import {MIN_TICK, MAX_TICK, NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
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
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
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

/// @notice Continuous first-price auction of privileged swap access to pools whose liquidity providers are paid
/// rent in a single immutable bid token.
/// @dev The holder's named executor swaps fee-free. While a pool is rented, any other locker may swap through
/// forward and pays the pool's fee to the holder. That keeps the price within the fee band of the market, which
/// bounds how far a holder can move the price away from other providers' ranges before being arbitraged. Rent
/// accrues per second to liquidity active over time. Bids are fully funded, start at timestamp+1, must beat the
/// scheduled rate by the pool's increment, and can be extended at any time or shortened with the pool's notice.
/// Without an active bid the pool does not swap. Rent charged while no liquidity is active is never refunded.
contract ContinuousAuction is BaseExtension, BaseForwardee, ReentrancyGuardTransient {
    using CoreLib for *;
    using ExposedStorageLib for *;

    address public immutable bidToken;

    struct Bid {
        address bidder;
        uint96 rate;
        address executor;
        uint48 start;
        uint48 end;
    }

    struct Auction {
        Bid current;
        // Only nonempty within the second it was placed; promoted by the next settlement.
        Bid next;
        bool initialized;
        // A 0.32 fixed-point fraction: the upper 32 bits of Core's 0.64 fee format.
        uint32 fee;
        uint96 minRate;
        uint32 noticePeriod;
        uint16 minIncrementBps;
        uint48 lastSettled;
        uint256 growth;
    }

    struct PositionRent {
        uint256 snapshot;
        uint256 owed;
    }

    mapping(PoolId => Auction) public auctions;
    mapping(address => uint256) public refundable;
    mapping(PoolId => uint256) public unallocatedRent;
    mapping(PoolId => mapping(address => uint256)) private _swapFees;
    mapping(PoolId => mapping(int32 => uint256)) public growthOutside;
    mapping(PoolId => mapping(address => mapping(PositionId => PositionRent))) public positionRent;

    error InvalidPool();
    error InvalidBid();
    error BidTooLow();
    error IncorrectFunding();
    error NotHolder();
    error PoolClosed();
    error SwapMustHappenThroughForward();

    event PoolCreated(
        PoolId indexed poolId, PoolKey key, uint32 fee, uint96 minRate, uint32 noticePeriod, uint16 minIncrementBps
    );
    event FeeUpdated(PoolId indexed poolId, address indexed bidder, uint32 fee);
    event BidPlaced(
        PoolId indexed poolId, address indexed bidder, address executor, uint96 rate, uint48 start, uint48 end
    );
    event BidEndUpdated(PoolId indexed poolId, address indexed bidder, uint48 end);
    event RefundCredited(address indexed bidder, uint256 amount);
    event RefundWithdrawn(address indexed bidder, address indexed recipient, uint256 amount);
    event RentAccrued(PoolId indexed poolId, uint256 amount);
    event RentUnallocated(PoolId indexed poolId, uint256 amount);
    event RentCollected(
        PoolId indexed poolId, address indexed owner, PositionId positionId, address recipient, uint256 amount
    );
    event SwapFeeCharged(PoolId indexed poolId, address indexed bidder, uint128 amount0, uint128 amount1);
    event SwapFeesWithdrawn(
        PoolId indexed poolId, address indexed bidder, address recipient, uint128 amount0, uint128 amount1
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

    /// POOL CREATION

    /// @notice Initializes a pool with immutable auction terms. Pools of this extension can only be created here.
    /// @param fee Initial fee charged to non-holder swaps, as a 0.32 fixed-point fraction. The fee is pool
    /// state that each holder may change with setFee; there is no cap. A holder that uses a high fee to hold
    /// the price away from other providers' ranges creates a mispricing any bidder can claim by outbidding it
    /// for one notice period, so the notice period is what prices that defence.
    /// @param minRate Reserve rent in bid-token base units per second.
    /// @param noticePeriod Minimum funded tenure of a bid and minimum remaining tenure after shortening.
    /// @param minIncrementBps Minimum rate increase over the scheduled bid, in basis points.
    function createPool(
        PoolKey calldata key,
        int32 tick,
        uint32 fee,
        uint96 minRate,
        uint32 noticePeriod,
        uint16 minIncrementBps
    ) external nonReentrant returns (SqrtRatio sqrtRatio) {
        _validate(key);
        PoolId poolId = key.toPoolId();
        Auction storage auction = auctions[poolId];
        if (auction.initialized) revert InvalidPool();
        auction.initialized = true;
        auction.fee = fee;
        auction.minRate = minRate;
        auction.noticePeriod = noticePeriod;
        auction.minIncrementBps = minIncrementBps;
        auction.lastSettled = uint48(block.timestamp);
        sqrtRatio = CORE.initializePool(key, tick);
        emit PoolCreated(poolId, key, fee, minRate, noticePeriod, minIncrementBps);
    }

    function beforeInitializePool(address caller, PoolKey memory key, int32) external view override onlyCore {
        if (caller != address(this) || !auctions[key.toPoolId()].initialized) revert InvalidPool();
    }

    function beforeSwap(Locker, PoolKey memory, SwapParameters) external pure override {
        revert SwapMustHappenThroughForward();
    }

    /// BIDDING

    /// @notice Buys the interval [timestamp+1, end) at rate base units per second, displacing the scheduled bid.
    /// @dev Executor is the authorized Core locker, NOT tx.origin. It must authenticate its own callers.
    /// Full native funding or ERC20 allowance is required; native excess becomes refundable credit.
    /// A displaced bid is refunded for the displaced interval. Another bidder must exceed the scheduled rate
    /// by the pool's increment; the scheduled bidder may raise its own rate by any amount.
    function bid(PoolKey calldata key, uint96 rate, uint64 end, address executor) external payable nonReentrant {
        _validate(key);
        PoolId poolId = key.toPoolId();
        Auction storage auction = auctions[poolId];
        if (!auction.initialized) revert InvalidPool();
        _accrue(poolId, CORE.poolState(poolId).liquidity());
        if (block.timestamp >= type(uint48).max) revert InvalidBid();
        uint48 start = uint48(block.timestamp + 1);
        if (rate == 0 || executor == address(0)) revert InvalidBid();
        if (rate < auction.minRate) revert BidTooLow();
        _checkEnd(end, start, auction.noticePeriod);

        // The scheduled bid at activation is a same-second pending bid, else the incumbent if it outlasts start.
        Bid storage scheduled = auction.next.bidder != address(0) ? auction.next : auction.current;
        if (scheduled.end > start) {
            uint256 minimum = uint256(scheduled.rate)
                + (scheduled.bidder == msg.sender
                        ? 1
                        : FixedPointMathLib.fullMulDivUp(scheduled.rate, auction.minIncrementBps, 10000));
            if (rate <= scheduled.rate || rate < minimum) revert BidTooLow();
        }

        _fund(uint256(rate) * (end - start));

        Bid storage next = auction.next;
        if (next.bidder != address(0)) {
            _credit(next.bidder, uint256(next.rate) * (next.end - next.start));
        }
        Bid storage current = auction.current;
        if (current.end > start) {
            _credit(current.bidder, uint256(current.rate) * (current.end - start));
            current.end = start;
        }
        auction.next = Bid(msg.sender, rate, executor, start, uint48(end));
        emit BidPlaced(poolId, msg.sender, executor, rate, start, uint48(end));
    }

    /// @notice Extends the caller's scheduled bid to a later end at the same rate, funding the added interval.
    function extend(PoolKey calldata key, uint64 end) external payable nonReentrant {
        _validate(key);
        PoolId poolId = key.toPoolId();
        Auction storage auction = auctions[poolId];
        _accrue(poolId, CORE.poolState(poolId).liquidity());
        Bid storage own = _ownBid(auction);
        if (end <= own.end) revert InvalidBid();
        uint48 from = own.start > block.timestamp ? own.start : uint48(block.timestamp);
        _checkEnd(end, from, 0);
        _fund(uint256(own.rate) * (end - own.end));
        own.end = uint48(end);
        emit BidEndUpdated(poolId, msg.sender, uint48(end));
    }

    /// @notice Shortens the caller's scheduled bid, keeping at least the pool's notice period from now.
    /// @dev Rent for the relinquished interval becomes refundable credit. This is the only voluntary exit.
    function shorten(PoolKey calldata key, uint64 end) external nonReentrant {
        _validate(key);
        PoolId poolId = key.toPoolId();
        Auction storage auction = auctions[poolId];
        _accrue(poolId, CORE.poolState(poolId).liquidity());
        Bid storage own = _ownBid(auction);
        uint256 floor = block.timestamp + auction.noticePeriod;
        if (floor < own.start) floor = own.start;
        if (end >= own.end || end < floor) revert InvalidBid();
        _credit(msg.sender, uint256(own.rate) * (own.end - end));
        own.end = uint48(end);
        emit BidEndUpdated(poolId, msg.sender, uint48(end));
    }

    /// @notice Sets the fee charged to non-holder swaps. Only the scheduled bidder may call.
    /// @dev The fee is pool state: it persists until the next change, including across holders.
    function setFee(PoolKey calldata key, uint32 fee) external nonReentrant {
        _validate(key);
        PoolId poolId = key.toPoolId();
        Auction storage auction = auctions[poolId];
        _accrue(poolId, CORE.poolState(poolId).liquidity());
        _ownBid(auction);
        auction.fee = fee;
        emit FeeUpdated(poolId, msg.sender, fee);
    }

    /// @dev Rent between settlements must fit uint128 for the Q128 growth update. Every bid or extension
    /// settles first, the pending bid overlaps the incumbent for one second, and rates fit uint96, so bounding
    /// the remaining tenure below 2**32 seconds keeps the rent of any settlement window below 2**128.
    function _checkEnd(uint64 end, uint48 from, uint32 minimumTenure) private pure {
        if (end < uint256(from) + minimumTenure || end <= from || end - from > type(uint32).max) revert InvalidBid();
    }

    /// @dev The caller's own scheduled bid: its same-second pending bid, else the undisplaced live incumbent.
    function _ownBid(Auction storage auction) private view returns (Bid storage own) {
        own = auction.next;
        if (own.bidder == msg.sender) return own;
        own = auction.current;
        if (own.bidder != msg.sender || auction.next.bidder != address(0) || own.end <= block.timestamp) {
            revert NotHolder();
        }
    }

    function _fund(uint256 funding) private {
        if (bidToken == NATIVE_TOKEN_ADDRESS) {
            if (msg.value < funding) revert IncorrectFunding();
            _credit(msg.sender, msg.value - funding);
        } else {
            if (msg.value != 0) revert IncorrectFunding();
            uint256 balance = SafeTransferLib.balanceOf(bidToken, address(this));
            SafeTransferLib.safeTransferFrom(bidToken, msg.sender, address(this), funding);
            if (SafeTransferLib.balanceOf(bidToken, address(this)) - balance != funding) revert IncorrectFunding();
        }
    }

    function _credit(address bidder, uint256 amount) private {
        if (amount != 0) {
            refundable[bidder] += amount;
            emit RefundCredited(bidder, amount);
        }
    }

    /// @notice Withdraws displaced or relinquished funding and excess native payments owned by the caller.
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

    /// @dev The bid holding the pool now, if any. Before settlement a pending bid may already be live.
    function _activeBid(Auction storage auction) private view returns (Bid storage active, bool live) {
        active = auction.next;
        if (active.bidder == address(0) || active.start > block.timestamp) active = auction.current;
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
        uint256 rent = _rentBetween(auction.current, from, now_);
        if (auction.next.bidder != address(0)) {
            // The pending bid was placed at `from`, so it is live now and the incumbent ended at its start.
            rent += _rentBetween(auction.next, from, now_);
            auction.current = auction.next;
            delete auction.next;
        }
        auction.lastSettled = now_;
        if (rent != 0) {
            if (liquidity == 0) {
                // Access costs rent independently of where the executor leaves the price. Do not award
                // empty-interval rent to a later depositor or refund it to the holder who moved the price.
                unallocatedRent[poolId] += rent;
                emit RentUnallocated(poolId, rent);
            } else {
                unchecked {
                    // rent < 2**128, see _checkEnd.
                    auction.growth += (rent << 128) / liquidity;
                }
                emit RentAccrued(poolId, rent);
            }
        }
    }

    /// SWAPS

    function handleForwardData(Locker original, bytes memory data)
        internal
        override
        nonReentrant
        returns (bytes memory result)
    {
        (PoolKey memory key, SwapParameters params) = abi.decode(data, (PoolKey, SwapParameters));
        _validate(key);
        PoolId poolId = key.toPoolId();
        Auction storage auction = auctions[poolId];
        PoolState before_ = CORE.poolState(poolId);
        _accrue(poolId, before_.liquidity());
        (Bid storage active, bool live) = _activeBid(auction);
        if (!live) revert PoolClosed();
        (PoolBalanceUpdate update, PoolState after_) = CORE.swap(0, key, params);
        if (original.addr() != active.executor) {
            update = _chargeSwapFee(key, poolId, active.bidder, params, update, uint64(auction.fee) << 32);
        }
        if (key.config.isConcentrated()) {
            _cross(poolId, before_.tick(), after_.tick(), key.config.concentratedTickSpacing(), params.skipAhead());
        }
        result = abi.encode(update, after_);
    }

    /// @dev Charges the holder's fee on the swapper's output, or on its input for exact-output swaps, and saves
    /// it for the holder in Core under the pool's salt.
    function _chargeSwapFee(
        PoolKey memory key,
        PoolId poolId,
        address bidder,
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
                fee0 = computeFee(uint128(-delta0), fee);
                delta0 += int128(fee0);
            } else if (delta1 < 0) {
                fee1 = computeFee(uint128(-delta1), fee);
                delta1 += int128(fee1);
            }
        }
        if (fee0 != 0 || fee1 != 0) {
            _swapFees[poolId][bidder] += (uint256(fee0) << 128) | fee1;
            CORE.updateSavedBalances(
                key.token0, key.token1, PoolId.unwrap(poolId), int256(uint256(fee0)), int256(uint256(fee1))
            );
            emit SwapFeeCharged(poolId, bidder, fee0, fee1);
        }
        return createPoolBalanceUpdate(delta0, delta1);
    }

    /// @notice Swap fees owed to a bidder for a pool, in the pool's tokens.
    function swapFeesOwed(PoolId poolId, address bidder) external view returns (uint128 amount0, uint128 amount1) {
        uint256 packed = _swapFees[poolId][bidder];
        amount0 = uint128(packed >> 128);
        amount1 = uint128(packed);
    }

    /// @notice Withdraws the caller's swap fees for the pool to recipient.
    function withdrawSwapFees(PoolKey calldata key, address recipient)
        external
        nonReentrant
        returns (uint128 amount0, uint128 amount1)
    {
        PoolId poolId = key.toPoolId();
        uint256 packed = _swapFees[poolId][msg.sender];
        if (packed == 0) return (0, 0);
        delete _swapFees[poolId][msg.sender];
        amount0 = uint128(packed >> 128);
        amount1 = uint128(packed);
        (bool success, bytes memory result) = address(CORE)
            .call(
                abi.encodePacked(
                    IFlashAccountant.lock.selector,
                    abi.encode(key.token0, key.token1, poolId, amount0, amount1, recipient)
                )
            );
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        emit SwapFeesWithdrawn(poolId, msg.sender, recipient, amount0, amount1);
    }

    /// @dev Core lock callback used only by withdrawSwapFees.
    function locked_6416899205(uint256) external onlyCore {
        (address token0, address token1, PoolId poolId, uint128 amount0, uint128 amount1, address recipient) =
            abi.decode(msg.data[36:], (address, address, PoolId, uint128, uint128, address));
        CORE.updateSavedBalances(
            token0, token1, PoolId.unwrap(poolId), -int256(uint256(amount0)), -int256(uint256(amount1))
        );
        FlashAccountantLib.withdrawTwo(CORE, token0, token1, recipient, amount0, amount1);
    }

    /// LIQUIDITY PROVIDER RENT

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

    /// @notice Collects rent for a Core position owned by msg.sender, including after full withdrawal.
    function collectRent(PoolKey calldata key, PositionId positionId, address recipient)
        external
        nonReentrant
        returns (uint256 amount)
    {
        _validate(key);
        PoolId poolId = key.toPoolId();
        PoolState state = CORE.poolState(poolId);
        _accrue(poolId, state.liquidity());
        _checkpoint(key, msg.sender, positionId, state.tick(), _liquidity(poolId, msg.sender, positionId));
        PositionRent storage rent = positionRent[poolId][msg.sender][positionId];
        amount = rent.owed;
        rent.owed = 0;
        _pay(recipient, amount);
        emit RentCollected(poolId, msg.sender, positionId, recipient, amount);
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
