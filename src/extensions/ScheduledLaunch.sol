// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore, CallPoints} from "../interfaces/ICore.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {BaseLocker} from "../base/BaseLocker.sol";
import {MintableERC20} from "../MintableERC20.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {FlashAccountantLib} from "../libraries/FlashAccountantLib.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";
import {createConcentratedPoolConfig} from "../types/poolConfig.sol";
import {PositionId, createPositionId} from "../types/positionId.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
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
/// @dev Create via Core.forward with abi.encode(LaunchConfig). The forwarding locker owes
/// quoteAmount to Core. Automatic management ends after endTime; the owner may then withdraw.
contract ScheduledLaunch is BaseExtension, BaseForwardee, BaseLocker {
    using CoreLib for ICore;
    using FlashAccountantLib for *;

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
        uint64 fee;
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
    }

    mapping(PoolId => Launch) private _launches;

    error InvalidLaunch();
    error UnknownLaunch();
    error InitializationThroughForwardOnly();
    error LaunchNotStarted();
    error LaunchNotComplete();
    error OwnerOnly();
    error InvalidRecipient();

    event LaunchCreated(PoolId indexed poolId, address indexed token, address indexed owner, LaunchConfig config);
    event LaunchAdvanced(PoolId indexed poolId, uint128 deployed, bool complete);
    event LaunchWithdrawn(PoolId indexed poolId, address indexed recipient);

    constructor(ICore core) BaseExtension(core) BaseForwardee(core) BaseLocker(core) {}

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

    function beforeSwap(Locker, PoolKey memory key, SwapParameters) external override onlyCore {
        Launch storage launch = _launches[key.toPoolId()];
        if (launch.owner == address(0)) revert UnknownLaunch();
        if (block.timestamp < launch.startTime) revert LaunchNotStarted();
        if (!launch.complete) advance(key);
    }

    /// @notice Anyone may advance a launch, including completing it without a trade.
    function advance(PoolKey memory key) public {
        Launch storage launch = _launches[key.toPoolId()];
        if (launch.owner == address(0)) revert UnknownLaunch();
        if (!launch.complete) lock(abi.encode(key, address(0)));
    }

    /// @notice After completion, withdraw reserves, fees, and liquidity up to Core's per-call amount limits.
    /// @dev Repeat to remove any liquidity remaining after a large withdrawal.
    /// @dev This is an owner action, not automatic pool management. Liquidity is not permanently locked.
    function withdraw(PoolKey memory key, address recipient) external {
        Launch storage launch = _launches[key.toPoolId()];
        if (msg.sender != launch.owner) revert OwnerOnly();
        if (!launch.complete) revert LaunchNotComplete();
        if (recipient == address(0)) revert InvalidRecipient();
        lock(abi.encode(key, recipient));
    }

    function handleForwardData(Locker, bytes memory data) internal override returns (bytes memory) {
        LaunchConfig memory config = abi.decode(data, (LaunchConfig));
        _validateConfig(config);
        MintableERC20 token = new MintableERC20(address(this), config.name, config.symbol, config.decimals);
        token.mint(address(this), config.totalSupply);
        token.renounceOwnership();
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

    function _validateConfig(LaunchConfig memory config) private view {
        if (config.owner == address(0) || config.totalSupply == 0) revert InvalidLaunch();
        if (config.startTime < block.timestamp || config.endTime <= config.startTime) revert InvalidLaunch();
        if (config.totalSupply > uint128(type(int128).max) || config.quoteAmount > uint128(type(int128).max)) {
            revert InvalidLaunch();
        }
        _validateTicks(config);
    }

    function _validateTicks(LaunchConfig memory config) private pure {
        if (config.targetTick < MIN_TICK || config.upperTick > MAX_TICK || config.targetTick >= config.upperTick) {
            revert InvalidLaunch();
        }
        if (config.tickSpacing == 0 || config.tickSpacing > MAX_TICK_SPACING) revert InvalidLaunch();
        // PositionId.validate checks aligned bounds after accounting for token ordering.
    }

    function _initialize(LaunchConfig memory config, address token) private returns (PoolKey memory key) {
        if (config.quoteToken == token) revert InvalidLaunch();
        bool tokenIs0 = token < config.quoteToken;
        key = PoolKey({
            token0: tokenIs0 ? token : config.quoteToken,
            token1: tokenIs0 ? config.quoteToken : token,
            config: createConcentratedPoolConfig(config.fee, config.tickSpacing, address(this))
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
            complete: false
        });
        CORE.initializePool(key, targetTick);
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory key, address recipient) = abi.decode(data, (PoolKey, address));
        if (recipient == address(0)) _advance(key);
        else _withdraw(key, recipient);
        return "";
    }

    function _advance(PoolKey memory key) private {
        PoolId poolId = key.toPoolId();
        Launch storage launch = _launches[poolId];
        if (block.timestamp < launch.startTime) return;
        uint128 available = released(poolId) - launch.deployed;
        if (available != 0) _sell(key, launch, available);
        _addLiquidity(key, launch);
        if (block.timestamp >= launch.endTime) launch.complete = true;
        emit LaunchAdvanced(poolId, launch.deployed, launch.complete);
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

    function _withdraw(PoolKey memory key, address recipient) private {
        Launch storage launch = _launches[key.toPoolId()];
        uint128 liquidity = CORE.poolPositions(key.toPoolId(), address(this), launch.positionId).liquidity;
        liquidity = uint128(
            FixedPointMathLib.min(
                liquidity,
                maxLiquidity(
                    CORE.poolState(key.toPoolId()).sqrtRatio(),
                    tickToSqrtRatio(launch.positionId.tickLower()),
                    tickToSqrtRatio(launch.positionId.tickUpper()),
                    uint128(type(int128).max),
                    uint128(type(int128).max)
                )
            )
        );
        // Core clears fee accounting when the last liquidity is removed. Collect first.
        (uint128 fees0, uint128 fees1) = CORE.collectFees(key, launch.positionId);
        PoolBalanceUpdate update = CORE.updatePosition(key, launch.positionId, -int128(liquidity));
        (uint128 reserve0, uint128 reserve1) = _reserves(key);
        CORE.updateSavedBalances(
            key.token0,
            key.token1,
            PoolId.unwrap(key.toPoolId()),
            -int256(uint256(reserve0)),
            -int256(uint256(reserve1))
        );
        CORE.withdrawTwo(key.token0, key.token1, recipient, reserve0, reserve1);
        CORE.withdrawTwo(key.token0, key.token1, recipient, uint128(-update.delta0()), uint128(-update.delta1()));
        CORE.withdrawTwo(key.token0, key.token1, recipient, fees0, fees1);
        emit LaunchWithdrawn(key.toPoolId(), recipient);
    }
}
