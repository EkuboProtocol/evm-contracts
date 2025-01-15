// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints, addressToCallPoints} from "./types/callPoints.sol";
import {PoolKey, PositionKey, Bounds} from "./types/keys.sol";
import {FeesPerLiquidity} from "./types/feesPerLiquidity.sol";
import {Position} from "./types/position.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {Bitmap} from "./math/bitmap.sol";
import {shouldCallBeforeInitializePool, shouldCallAfterInitializePool} from "./types/callPoints.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ExposedStorage} from "./base/ExposedStorage.sol";

interface ILocker {
    function locked(uint256 id, bytes calldata data) external returns (bytes memory);
}

interface IForwardee {
    function forwarded(address locker, uint256 id, bytes calldata data) external returns (bytes memory);
}

interface IExtension {
    function beforeInitializePool(PoolKey calldata key, int32 tick) external;
    function afterInitializePool(PoolKey calldata key, int32 tick, uint256 sqrtRatio) external;
}

contract Core is Ownable, ExposedStorage {
    // We pack the delta and net.
    struct TickInfo {
        int128 liquidityDelta;
        uint128 liquidityNet;
    }

    // The pool price, we pack the tick with the sqrt ratio
    struct PoolPrice {
        uint192 sqrtRatio;
        int32 tick;
    }

    mapping(address extension => bool isRegistered) public isExtensionRegistered;
    mapping(address token => uint256 amountCollected) public protocolFeesCollected;

    // Keyed by the pool ID, which is the keccak256 of the ABI-encoded pool key
    mapping(bytes32 poolId => PoolPrice price) public poolPrice;
    mapping(bytes32 poolId => uint128 liquidity) public poolLiquidity;
    mapping(bytes32 poolId => FeesPerLiquidity feesPerLiquidity) public poolFees;
    mapping(bytes32 poolId => mapping(bytes32 positionId => Position position)) public positions;
    mapping(bytes32 poolId => mapping(int32 tick => TickInfo tickInfo)) public ticks;
    mapping(bytes32 poolId => mapping(int32 tick => FeesPerLiquidity feesPerLiquidityOutside)) public
        tickFeesPerLiquidityOutside;
    mapping(bytes32 poolId => mapping(uint256 word => Bitmap bitmap)) public initializedTickBitmaps;

    // Balances saved for later
    mapping(address owner => mapping(address token => mapping(bytes32 salt => uint256))) public savedBalances;

    event ProtocolFeesWithdrawn(address recipient, address token, uint256 amount);

    function withdrawProtocolFees(address recipient, address token, uint256 amount) public onlyOwner {
        protocolFeesCollected[token] -= amount;
        SafeTransferLib.safeTransfer(token, recipient, amount);
        emit ProtocolFeesWithdrawn(recipient, token, amount);
    }

    function withdrawProtocolFees(address recipient, address token) external {
        withdrawProtocolFees(recipient, token, protocolFeesCollected[token]);
    }

    constructor(address owner) {
        _initializeOwner(owner);
    }

    error FailedRegisterInvalidCallPoints();
    error ExtensionAlreadyRegistered();

    event ExtensionRegistered(address extension);

    // Extensions must call this function to become registered. The call points are validated against the caller address
    function registerExtension(CallPoints memory expectedCallPoints) external {
        CallPoints memory computed = addressToCallPoints(msg.sender);
        if (!computed.eq(expectedCallPoints) || !computed.isValid()) revert FailedRegisterInvalidCallPoints();
        if (isExtensionRegistered[msg.sender]) revert ExtensionAlreadyRegistered();
        isExtensionRegistered[msg.sender] = true;

        emit ExtensionRegistered(msg.sender);
    }

    error LockerOnly();

    function requireLocker() private view returns (uint256 id, address locker) {
        assembly ("memory-safe") {
            id := sub(tload(0), 1)
            locker := tload(add(0x100000000, id))
        }
        if (locker != msg.sender) revert LockerOnly();
    }

    function accountDelta(uint256 lockerId, address token, int128 delta) private {
        bytes32 slot = keccak256(abi.encode(lockerId, token));

        int128 current;
        assembly ("memory-safe") {
            current := tload(slot)
        }

        // this is a checked addition, so it will revert if it overflows
        int128 next = current + delta;

        if (current == 0 && next != 0) {
            assembly ("memory-safe") {
                let nzdCountSlot := add(lockerId, 0x200000000)

                tstore(nzdCountSlot, add(tload(nzdCountSlot), 1))
            }
        } else if (current != 0 && next == 0) {
            assembly ("memory-safe") {
                let nzdCountSlot := add(lockerId, 0x200000000)

                tstore(nzdCountSlot, sub(tload(nzdCountSlot), 1))
            }
        }

        assembly ("memory-safe") {
            tstore(slot, next)
        }
    }

    error DeltasNotZeroed(uint256 count);

    // The entrypoint for all operations on the core contract
    function lock(bytes calldata data) external returns (bytes memory result) {
        uint256 id;

        assembly ("memory-safe") {
            id := tload(0)
            // store the count
            tstore(0, add(id, 1))
            // store the address of the locker
            tstore(add(0x100000000, id), caller())
        }

        // We make the assumption that this code can never be called recursively this many times, causing storage slots to overlap
        // This is just the codified assumption
        assert(id < type(uint32).max);

        result = ILocker(msg.sender).locked(id, data);

        uint256 nonzeroDeltaCount;
        assembly ("memory-safe") {
            // reset the locker id
            tstore(0, id)
            // remove the address
            tstore(add(0x100000000, id), 0)
            // load the delta count which should already be reset to zero
            nonzeroDeltaCount := tload(add(0x200000000, id))
        }

        if (nonzeroDeltaCount != 0) revert DeltasNotZeroed(nonzeroDeltaCount);
    }

    function forward(address to, bytes calldata data) external returns (bytes memory result) {
        (uint256 id, address locker) = requireLocker();

        // update this lock's locker to the forwarded address for the duration of the forwarded
        // call, meaning only the forwarded address can update state
        assembly ("memory-safe") {
            tstore(add(0x100000000, id), to)
        }

        result = IForwardee(to).forwarded(locker, id, data);

        assembly ("memory-safe") {
            tstore(add(0x100000000, id), locker)
        }
    }

    error PoolAlreadyInitialized();
    error ExtensionNotRegistered(address extension);

    event PoolInitialized(PoolKey key, int32 tick, uint256 sqrtRatio);

    function initializePool(PoolKey memory key, int32 tick) public returns (uint256 sqrtRatio) {
        key.validatePoolKey();

        if (key.extension != address(0)) {
            if (!isExtensionRegistered[key.extension]) {
                revert ExtensionNotRegistered(key.extension);
            }

            if (shouldCallBeforeInitializePool(key.extension)) {
                IExtension(key.extension).beforeInitializePool(key, tick);
            }
        }

        bytes32 poolId = key.toPoolId();
        PoolPrice memory price = poolPrice[poolId];
        if (price.sqrtRatio != 0) revert PoolAlreadyInitialized();

        sqrtRatio = tickToSqrtRatio(tick);
        poolPrice[poolId] = PoolPrice({sqrtRatio: uint192(sqrtRatio), tick: tick});

        emit PoolInitialized(key, tick, sqrtRatio);

        // we don't need to check if extension is non-zero because a zero extension will always return false
        if (shouldCallAfterInitializePool(key.extension)) {
            IExtension(key.extension).afterInitializePool(key, tick, sqrtRatio);
        }
    }

    // Initializes the pool if it isn't already initialized, otherwise just returns the current price of the pool
    function maybeInitializePool(PoolKey memory key, int32 tick)
        external
        returns (bool didInitialize, uint256 sqrtRatio)
    {
        sqrtRatio = poolPrice[key.toPoolId()].sqrtRatio;
        if (sqrtRatio == 0) {
            sqrtRatio = initializePool(key, tick);
            didInitialize = true;
        }
    }

    error BalanceDeltaNotEqualAllowance(address token);
    error PaymentOverflow(address token, uint256 delta);

    function pay(address token) external {
        (uint256 id, address payer) = requireLocker();
        uint256 allowance = IERC20(token).allowance(payer, address(this));
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        SafeTransferLib.safeTransferFrom(token, payer, address(this), allowance);
        uint256 delta = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (delta != allowance) revert BalanceDeltaNotEqualAllowance(token);
        accountDelta(id, token, -SafeCastLib.toInt128(delta));
    }

    event LoadedBalance(address owner, address token, bytes32 salt, uint128 amount);

    function load(address token, bytes32 salt, uint128 amount) external {
        (uint256 id, address owner) = requireLocker();

        accountDelta(id, token, -SafeCastLib.toInt128(amount));

        savedBalances[owner][token][salt] -= amount;

        emit LoadedBalance(owner, token, salt, amount);
    }

    error TokenAmountTooLarge();

    function withdraw(address token, address recipient, uint128 amount) external {
        (uint256 id,) = requireLocker();

        accountDelta(id, token, SafeCastLib.toInt128(amount));

        SafeTransferLib.safeTransfer(token, recipient, amount);
    }

    event SavedBalance(address owner, address token, bytes32 salt, uint128 amount);

    function save(address owner, address token, bytes32 salt, uint128 amount) external {
        (uint256 id,) = requireLocker();

        accountDelta(id, token, SafeCastLib.toInt128(amount));

        savedBalances[owner][token][salt] += amount;

        emit SavedBalance(owner, token, salt, amount);
    }

    // Returns the pool fees per liquidity inside the given bounds.
    function getPoolFeesPerLiquidityInside(bytes32 poolId, Bounds calldata bounds)
        public
        view
        returns (FeesPerLiquidity memory)
    {
        int32 tick = poolPrice[poolId].tick;
        mapping(int32 => FeesPerLiquidity) storage poolIdEntry = tickFeesPerLiquidityOutside[poolId];
        FeesPerLiquidity memory lower = poolIdEntry[bounds.lower];
        FeesPerLiquidity memory upper = poolIdEntry[bounds.upper];

        if (tick < bounds.lower) {
            return lower.sub(upper);
        } else if (tick < bounds.upper) {
            FeesPerLiquidity memory fees = poolFees[poolId];

            return fees.sub(lower).sub(upper);
        } else {
            return upper.sub(lower);
        }
    }
}
