// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore, CallPoints} from "../interfaces/ICore.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {BaseLocker} from "../base/BaseLocker.sol";
import {LockedLaunchLiquidity} from "../LockedLaunchLiquidity.sol";
import {PoolState} from "../types/poolState.sol";
import {computeFee, amountBeforeFee} from "../math/fee.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {FlashAccountantLib} from "../libraries/FlashAccountantLib.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";
import {createConcentratedPoolConfig, createFullRangePoolConfig} from "../types/poolConfig.sol";
import {PositionId, createPositionId} from "../types/positionId.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {SwapParameters, createSwapParameters} from "../types/swapParameters.sol";
import {Locker} from "../types/locker.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING} from "../math/constants.sol";
import {maxLiquidity} from "../math/liquidity.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

function scheduledLaunchCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: true,
        afterInitializePool: false,
        beforeSwap: true,
        afterSwap: false,
        beforeUpdatePosition: false,
        afterUpdatePosition: false,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}

/// @notice Fixed-supply launches with linear inventory release and a fixed price target.
/// @dev Create via Core.forward with abi.encode(uint8(0), LaunchConfig). The forwarding locker owes
/// quoteAmount to Core. Principal migrates to permanently locked full-range liquidity at endTime.
contract ScheduledLaunch is BaseExtension, BaseForwardee, BaseLocker {
    using CoreLib for ICore;
    using FlashAccountantLib for *;

    LockedLaunchLiquidity public immutable LIQUIDITY;

    /// @dev Ticks express raw quote units per launch token, independent of address ordering.
    struct LaunchConfig {
        address owner;
        address quoteToken;
        string name;
        string symbol;
        uint8 decimals;
        uint128 totalSupply;
        uint128 quoteAmount;
        uint64 startTime;
        uint64 endTime;
        int32 targetTick;
        int32 upperTick;
        uint32 tickSpacing;
        uint64 initialFee;
        uint64 finalFee;
        int32 migrationTickLower;
        int32 migrationTickUpper;
    }

    struct Launch {
        address owner;
        address token;
        uint64 startTime;
        uint64 endTime;
        uint128 totalSupply;
        uint128 deployed;
        int32 targetTick;
        PositionId positionId;
        bool complete;
        uint64 initialFee;
        uint64 finalFee;
        SqrtRatio migrationLower;
        SqrtRatio migrationUpper;
    }

    mapping(PoolId => Launch) private _launches;

    error InvalidLaunch();
    error UnknownLaunch();
    error InitializationThroughForwardOnly();
    error LaunchNotStarted();
    error LaunchEnded();
    error SwapsThroughForwardOnly();
    error InvalidAction();
    error OwnerOnly();
    error InvalidRecipient();

    event LaunchCreated(PoolId indexed poolId, address indexed token, address indexed owner, LaunchConfig config);
    event LaunchAdvanced(PoolId indexed poolId, uint128 deployed, bool complete);
    event CreatorFeesClaimed(PoolId indexed poolId, address indexed recipient, uint128 amount0, uint128 amount1);

    constructor(ICore core) BaseExtension(core) BaseForwardee(core) BaseLocker(core) {
        LIQUIDITY = new LockedLaunchLiquidity(core, address(this));
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return scheduledLaunchCallPoints();
    }

    function getLaunch(PoolId poolId) external view returns (Launch memory) {
        return _launches[poolId];
    }

    /// @notice Returns cumulative released supply, including tokens already deployed.
    function released(PoolId poolId) public view returns (uint128) {
        Launch storage launch = _launches[poolId];
        if (launch.owner == address(0)) revert UnknownLaunch();
        if (block.timestamp <= launch.startTime) return 0;
        if (block.timestamp >= launch.endTime) return launch.totalSupply;
        return uint128(
            uint256(launch.totalSupply) * (block.timestamp - launch.startTime) / (launch.endTime - launch.startTime)
        );
    }

    /// @dev Core skips this hook when this extension itself initializes the pool.
    function beforeInitializePool(address, PoolKey calldata, int32) external pure override {
        revert InitializationThroughForwardOnly();
    }

    function beforeSwap(Locker, PoolKey memory, SwapParameters) external pure override {
        revert SwapsThroughForwardOnly();
    }

    /// @notice Linearly declining fee charged only on external forwarded launch swaps.
    function feeAt(PoolId poolId) public view returns (uint64) {
        Launch storage launch = _launches[poolId];
        if (launch.owner == address(0)) revert UnknownLaunch();
        if (block.timestamp <= launch.startTime) return launch.initialFee;
        if (block.timestamp >= launch.endTime) return launch.finalFee;
        return launch.initialFee
            - uint64(
            uint256(launch.initialFee - launch.finalFee) * (block.timestamp - launch.startTime)
                / (launch.endTime - launch.startTime)
        );
    }

    function creatorFeeSalt(PoolId poolId) public pure returns (bytes32) {
        return keccak256(abi.encode("ScheduledLaunch creator fees", poolId));
    }

    function terminalPool(PoolKey memory key) public view returns (PoolKey memory) {
        Launch storage launch = _launches[key.toPoolId()];
        if (launch.owner == address(0)) revert UnknownLaunch();
        return PoolKey(key.token0, key.token1, createFullRangePoolConfig(launch.finalFee, address(0)));
    }

    /// @notice Anyone may advance a launch, including completing it without a trade.
    function advance(PoolKey memory key) public {
        Launch storage launch = _launches[key.toPoolId()];
        if (launch.owner == address(0)) revert UnknownLaunch();
        if (!launch.complete) lock(abi.encode(key, address(0)));
    }

    /// @notice Claims creator trading fees; principal is never owner-withdrawable.
    function claimFees(PoolKey memory key, address recipient) external {
        if (msg.sender != _launches[key.toPoolId()].owner) revert OwnerOnly();
        if (recipient == address(0)) revert InvalidRecipient();
        lock(abi.encode(key, recipient));
    }

    /// @dev Forward abi.encode(uint8(0), LaunchConfig) to create, or
    /// abi.encode(uint8(1), PoolKey, SwapParameters) to trade and receive (update, state).
    function handleForwardData(Locker, bytes memory data) internal override returns (bytes memory) {
        uint8 action = abi.decode(data, (uint8));
        if (action == 0) {
            (, LaunchConfig memory config) = abi.decode(data, (uint8, LaunchConfig));
            return _create(config);
        }
        if (action == 1) {
            (, PoolKey memory key, SwapParameters params) = abi.decode(data, (uint8, PoolKey, SwapParameters));
            return _swap(key, params);
        }
        revert InvalidAction();
    }

    function _create(LaunchConfig memory config) private returns (bytes memory) {
        _validateConfig(config);
        address token = LIQUIDITY.createToken(config.name, config.symbol, config.decimals, config.totalSupply);
        PoolKey memory key = _initialize(config, address(token));
        CORE.pay(address(token), config.totalSupply);
        bool tokenIs0 = key.token0 == address(token);
        CORE.updateSavedBalances(
            key.token0,
            key.token1,
            PoolId.unwrap(key.toPoolId()),
            int256(uint256(tokenIs0 ? config.totalSupply : config.quoteAmount)),
            int256(uint256(tokenIs0 ? config.quoteAmount : config.totalSupply))
        );
        emit LaunchCreated(key.toPoolId(), address(token), config.owner, config);
        return abi.encode(key);
    }

    function _swap(PoolKey memory key, SwapParameters params) private returns (bytes memory) {
        Launch storage launch = _launches[key.toPoolId()];
        if (launch.owner == address(0)) revert UnknownLaunch();
        if (block.timestamp < launch.startTime) revert LaunchNotStarted();
        if (block.timestamp >= launch.endTime) revert LaunchEnded();
        _advance(key);
        (PoolBalanceUpdate update, PoolState state) = CORE.swap(0, key, params.withDefaultSqrtRatioLimit());
        update = _chargeFee(key, params, update);
        return abi.encode(update, state);
    }

    function _chargeFee(PoolKey memory key, SwapParameters params, PoolBalanceUpdate update)
        private
        returns (PoolBalanceUpdate)
    {
        // Fee on the calculated side: output for exact-input, input for exact-output.
        // This preserves the specified amount and charges only the actual partial fill.
        bool calculatedIs1 = !params.isToken1();
        int128 calculated = calculatedIs1 ? update.delta1() : update.delta0();
        uint128 amount = uint128(FixedPointMathLib.abs(calculated));
        uint64 fee = feeAt(key.toPoolId());
        uint128 feeAmount = params.isExactOut() ? amountBeforeFee(amount, fee) - amount : computeFee(amount, fee);
        _saveFees(key, calculatedIs1 ? 0 : feeAmount, calculatedIs1 ? feeAmount : 0);
        int128 withFee = SafeCastLib.toInt128(int256(calculated) + int256(uint256(feeAmount)));
        return calculatedIs1
            ? createPoolBalanceUpdate(update.delta0(), withFee)
            : createPoolBalanceUpdate(withFee, update.delta1());
    }

    function _saveFees(PoolKey memory key, uint128 amount0, uint128 amount1) private {
        CORE.updateSavedBalances(
            key.token0, key.token1, creatorFeeSalt(key.toPoolId()), int256(uint256(amount0)), int256(uint256(amount1))
        );
    }

    function _validateConfig(LaunchConfig memory config) private view {
        if (config.owner == address(0) || config.totalSupply == 0) revert InvalidLaunch();
        if (config.startTime < block.timestamp || config.endTime <= config.startTime) revert InvalidLaunch();
        if (config.totalSupply > uint128(type(int128).max) || config.quoteAmount > uint128(type(int128).max)) {
            revert InvalidLaunch();
        }
        if (config.initialFee < config.finalFee) revert InvalidLaunch();
        _validateTicks(config);
        _validateMigrationBounds(config);
    }

    function _validateTicks(LaunchConfig memory config) private pure {
        if (config.targetTick < MIN_TICK || config.upperTick > MAX_TICK || config.targetTick >= config.upperTick) {
            revert InvalidLaunch();
        }
        if (config.tickSpacing == 0 || config.tickSpacing > MAX_TICK_SPACING) revert InvalidLaunch();
        // PositionId.validate checks aligned bounds after accounting for token ordering.
    }

    function _validateMigrationBounds(LaunchConfig memory config) private pure {
        if (
            config.migrationTickLower < MIN_TICK || config.migrationTickUpper > MAX_TICK
                || config.migrationTickLower >= config.migrationTickUpper
        ) revert InvalidLaunch();
    }

    function _initialize(LaunchConfig memory config, address token) private returns (PoolKey memory key) {
        if (config.quoteToken == token) revert InvalidLaunch();
        bool tokenIs0 = token < config.quoteToken;
        key = PoolKey({
            token0: tokenIs0 ? token : config.quoteToken,
            token1: tokenIs0 ? config.quoteToken : token,
            config: createConcentratedPoolConfig(0, config.tickSpacing, address(this))
        });
        key.config.validate();
        int32 targetTick = tokenIs0 ? config.targetTick : -config.targetTick;
        PositionId positionId = createPositionId(
            bytes24(0),
            tokenIs0 ? config.targetTick : -config.upperTick,
            tokenIs0 ? config.upperTick : -config.targetTick
        );
        positionId.validate(key.config);
        _launches[key.toPoolId()] = Launch({
            owner: config.owner,
            token: token,
            startTime: config.startTime,
            endTime: config.endTime,
            totalSupply: config.totalSupply,
            deployed: 0,
            targetTick: targetTick,
            positionId: positionId,
            complete: false,
            initialFee: config.initialFee,
            finalFee: config.finalFee,
            migrationLower: tickToSqrtRatio(tokenIs0 ? config.migrationTickLower : -config.migrationTickUpper),
            migrationUpper: tickToSqrtRatio(tokenIs0 ? config.migrationTickUpper : -config.migrationTickLower)
        });
        CORE.initializePool(key, targetTick);
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory key, address recipient) = abi.decode(data, (PoolKey, address));
        if (recipient == address(0)) _advance(key);
        else _claimFees(key, recipient);
        return "";
    }

    function _advance(PoolKey memory key) private {
        PoolId poolId = key.toPoolId();
        Launch storage launch = _launches[poolId];
        if (block.timestamp < launch.startTime) return;
        if (block.timestamp >= launch.endTime) _finish(key, launch);
        else _release(key, launch);
        emit LaunchAdvanced(poolId, launch.deployed, launch.complete);
    }

    function _release(PoolKey memory key, Launch storage launch) private {
        uint128 available = released(key.toPoolId()) - launch.deployed;
        if (available != 0) _sell(key, launch, available);
        _addLiquidity(key, launch);
    }

    function _sell(PoolKey memory key, Launch storage launch, uint128 available) private {
        SqrtRatio current = CORE.poolState(key.toPoolId()).sqrtRatio();
        SqrtRatio target = tickToSqrtRatio(launch.targetTick);
        bool tokenIs1 = launch.token == key.token1;
        if (tokenIs1 ? current >= target : current <= target) return;
        (uint128 reserve0, uint128 reserve1) = _reserves(key);
        // Leave room for the maximum signed output delta in Core's uint128 saved balance.
        if ((tokenIs1 ? reserve0 : reserve1) > uint128(type(int128).max)) return;
        int128 amount = _saleAmount(current, tokenIs1, available);
        if (amount == 0) return;
        (PoolBalanceUpdate update,) = CORE.swap(0, key, createSwapParameters(target, amount, tokenIs1, 0));
        _saveUpdate(key, launch, update);
    }

    /// @dev At a descending economic price, input * current price bounds quote output.
    /// Two rounded-down sqrt-price conversions avoid squaring a Q128 ratio into overflow.
    function _saleAmount(SqrtRatio current, bool tokenIs1, uint128 available) private pure returns (int128) {
        uint256 numerator = tokenIs1 ? current.toFixed() : 1 << 128;
        uint256 denominator = tokenIs1 ? 1 << 128 : current.toFixed();
        uint256 limit = FixedPointMathLib.fullMulDiv(uint128(type(int128).max), numerator, denominator);
        limit = FixedPointMathLib.fullMulDiv(limit, numerator, denominator);
        return int128(uint128(FixedPointMathLib.min(available, limit)));
    }

    function _addLiquidity(PoolKey memory key, Launch storage launch) private {
        (uint128 amount0, uint128 amount1) = _reserves(key);
        uint128 available = released(key.toPoolId()) - launch.deployed;
        if (key.token0 == launch.token) amount0 = available;
        else amount1 = available;
        uint128 liquidity = maxLiquidity(
            CORE.poolState(key.toPoolId()).sqrtRatio(),
            tickToSqrtRatio(launch.positionId.tickLower()),
            tickToSqrtRatio(launch.positionId.tickUpper()),
            uint128(FixedPointMathLib.min(amount0, uint128(type(int128).max))),
            uint128(FixedPointMathLib.min(amount1, uint128(type(int128).max)))
        );
        liquidity = uint128(FixedPointMathLib.min(liquidity, _liquidityCapacity(key, launch.positionId)));
        if (liquidity != 0) {
            _saveUpdate(key, launch, CORE.updatePosition(key, launch.positionId, int128(liquidity)));
        }
    }

    function _liquidityCapacity(PoolKey memory key, PositionId positionId) private view returns (uint128) {
        (, uint128 lower) = CORE.poolTicks(key.toPoolId(), positionId.tickLower());
        (, uint128 upper) = CORE.poolTicks(key.toPoolId(), positionId.tickUpper());
        return key.config.concentratedMaxLiquidityPerTick() - uint128(FixedPointMathLib.max(lower, upper));
    }

    function _saveUpdate(PoolKey memory key, Launch storage launch, PoolBalanceUpdate update) private {
        int128 spent = launch.token == key.token0 ? update.delta0() : update.delta1();
        // This helper is only used for exact-input launch sales and positive liquidity additions.
        launch.deployed += uint128(spent);
        CORE.updateSavedBalances(
            key.token0, key.token1, PoolId.unwrap(key.toPoolId()), -int256(update.delta0()), -int256(update.delta1())
        );
    }

    function _reserves(PoolKey memory key) private view returns (uint128, uint128) {
        return CORE.savedBalances(address(this), key.token0, key.token1, PoolId.unwrap(key.toPoolId()));
    }

    function _claimFees(PoolKey memory key, address recipient) private {
        bytes32 salt = creatorFeeSalt(key.toPoolId());
        (uint128 amount0, uint128 amount1) = CORE.savedBalances(address(this), key.token0, key.token1, salt);
        CORE.updateSavedBalances(key.token0, key.token1, salt, -int256(uint256(amount0)), -int256(uint256(amount1)));
        CORE.withdrawTwo(key.token0, key.token1, recipient, amount0, amount1);
        emit CreatorFeesClaimed(key.toPoolId(), recipient, amount0, amount1);
    }

    function _sendPrincipal(PoolKey memory key, Launch storage launch) private {
        (uint128 amount0, uint128 amount1) = _reserves(key);
        CORE.updateSavedBalances(
            key.token0, key.token1, PoolId.unwrap(key.toPoolId()), -int256(uint256(amount0)), -int256(uint256(amount1))
        );
        LockedLaunchLiquidity.Registration memory registration = LockedLaunchLiquidity.Registration(
            key.toPoolId(),
            launch.owner,
            terminalPool(key),
            launch.migrationLower,
            launch.migrationUpper,
            amount0,
            amount1
        );
        CORE.forward(address(LIQUIDITY), abi.encode(uint8(0), registration));
    }

    function _removableLiquidity(PoolKey memory key, Launch storage launch, uint128 liquidity)
        private
        view
        returns (uint128)
    {
        (uint128 saved0, uint128 saved1) =
            CORE.savedBalances(address(LIQUIDITY), key.token0, key.token1, PoolId.unwrap(key.toPoolId()));
        return uint128(
            FixedPointMathLib.min(
                liquidity,
                maxLiquidity(
                    CORE.poolState(key.toPoolId()).sqrtRatio(),
                    tickToSqrtRatio(launch.positionId.tickLower()),
                    tickToSqrtRatio(launch.positionId.tickUpper()),
                    uint128(FixedPointMathLib.min(type(uint128).max - saved0, uint128(type(int128).max))),
                    uint128(FixedPointMathLib.min(type(uint128).max - saved1, uint128(type(int128).max)))
                )
            )
        );
    }

    function _finish(PoolKey memory key, Launch storage launch) private {
        // Move reserves first to leave space for a bounded principal withdrawal.
        _sendPrincipal(key, launch);
        uint128 liquidity = CORE.poolPositions(key.toPoolId(), address(this), launch.positionId).liquidity;
        uint128 removable = _removableLiquidity(key, launch, liquidity);
        // Pool fee is zero; any donated position fees still belong to the creator.
        (uint128 fees0, uint128 fees1) = CORE.collectFees(key, launch.positionId);
        _saveFees(key, fees0, fees1);
        PoolBalanceUpdate update = CORE.updatePosition(key, launch.positionId, -int128(removable));
        CORE.updateSavedBalances(
            key.token0, key.token1, PoolId.unwrap(key.toPoolId()), -int256(update.delta0()), -int256(update.delta1())
        );
        _sendPrincipal(key, launch);
        launch.complete = removable == liquidity;
        LIQUIDITY.migrate(key.toPoolId());
    }
}
