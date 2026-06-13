// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ERC20} from "solady/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseLocker} from "../base/BaseLocker.sol";
import {ICore} from "../interfaces/ICore.sol";
import {CallPoints} from "../types/callPoints.sol";
import {createConcentratedPoolConfig} from "../types/poolConfig.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";
import {PositionId, createPositionId} from "../types/positionId.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {Locker} from "../types/locker.sol";
import {NATIVE_TOKEN_ADDRESS, MIN_TICK, MAX_TICK} from "../math/constants.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {maxLiquidity, liquidityDeltaToAmountDelta} from "../math/liquidity.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {FlashAccountantLib} from "../libraries/FlashAccountantLib.sol";

function autoRebalanceCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: true,
        afterInitializePool: false,
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        beforeSwap: true,
        afterSwap: true,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}

/// @notice Fungible vault token for one auto-rebalanced concentrated liquidity position.
contract AutoRebalance is ERC20, BaseExtension, BaseLocker {
    using CoreLib for *;
    using FlashAccountantLib for *;

    uint256 private constant CALL_SYNC = 0;
    uint256 private constant CALL_SWAP = 1;
    uint256 private constant CALL_WITHDRAW = 2;

    error InvalidPoolConfig();
    error InvalidPositionBounds();
    error InvalidTokens();
    error InvalidN();
    error InvalidInitialTick();
    error InvalidContributionLimit();
    error PoolAlreadyInitialized();
    error PoolNotInitialized();
    error InitializerOnly();
    error DirectSwapDisabled();
    error UnauthorizedPositionUpdate();
    error NoActiveLiquidity();
    error ZeroContribution();
    error ZeroShares();
    error ContributionTooLarge();
    error ContributionAlreadySettled();
    error ContributionNotEligible();
    error ContributionExpired();
    error PendingContributionLiquidityFloor();
    error PriceMoveLimitExceeded();
    error SlippageLimitExceeded();

    event PoolInitialized(int32 tick);
    event ContributionSubmitted(
        uint256 indexed contributionId,
        uint64 indexed eligibleBlock,
        address indexed recipient,
        uint128 amount0,
        uint128 amount1,
        uint256 minShares
    );
    event ContributionProcessed(uint64 indexed eligibleBlock, uint256 shares, uint128 amount0, uint128 amount1);
    event ContributionClaimed(uint256 indexed contributionId, address indexed recipient, uint256 shares);
    event ContributionRefunded(
        uint256 indexed contributionId, address indexed recipient, uint128 amount0, uint128 amount1
    );
    event Rebalanced(int32 tick, PositionId positionId, uint128 liquidity, uint128 idle0, uint128 idle1);
    event Withdrawn(address indexed owner, address indexed receiver, uint256 shares, uint128 amount0, uint128 amount1);

    struct Batch {
        uint128 amount0;
        uint128 amount1;
        uint256 value0;
        uint256 shares;
        uint256 value0Processed;
        bool exists;
        bool processed;
    }

    struct Contribution {
        uint64 eligibleBlock;
        uint64 deadlineBlock;
        address recipient;
        uint128 amount0;
        uint128 amount1;
        uint256 minShares;
        uint256 claimableShares;
        bool settled;
        bool refundable;
    }

    ICore public immutable CORE_REF;
    PoolKey public POOL_KEY;
    PoolId public immutable POOL_ID;
    address public immutable TOKEN0;
    address public immutable TOKEN1;
    uint32 public immutable TICK_SPACING;
    uint32 public immutable N;
    int32 public immutable INITIAL_TICK;
    uint64 public immutable MAX_CONTRIBUTION_TO_LIQUIDITY_BPS;
    address public immutable INITIALIZER;

    string private _name;
    string private _symbol;

    bool private _initialized;
    bool private _syncing;
    bool private _updatingPosition;
    bool private _internalSwap;
    PositionId private _allowedPositionId;

    uint64 public lastProcessedBlock;
    int32 public lastBlockStartTick;
    SqrtRatio public lastBlockStartSqrtRatio;

    PositionId public activePositionId;
    uint128 public activeLiquidity;
    uint128 public idle0;
    uint128 public idle1;

    uint256 public nextContributionId = 1;
    uint64[] public pendingBatchBlocks;
    mapping(uint64 => Batch) public batches;
    mapping(uint64 => uint256[]) private _batchContributionIds;
    mapping(uint256 => Contribution) public contributions;

    constructor(
        ICore core,
        address token0,
        address token1,
        uint64 fee,
        uint32 tickSpacing,
        uint32 n,
        int32 initialTick,
        uint64 maxContributionToLiquidityBps,
        address initializer,
        string memory name_,
        string memory symbol_
    ) BaseExtension(core) BaseLocker(core) {
        if (token0 == NATIVE_TOKEN_ADDRESS || token1 == NATIVE_TOKEN_ADDRESS || token0 >= token1) {
            revert InvalidTokens();
        }
        if (tickSpacing == 0) revert InvalidPoolConfig();
        if (n == 0) revert InvalidN();
        if (tickSpacing > uint32(type(int32).max)) revert InvalidPoolConfig();
        if (initialTick % int32(tickSpacing) != 0) revert InvalidInitialTick();
        if (maxContributionToLiquidityBps == 0) revert InvalidContributionLimit();
        if (uint256(n) * uint256(tickSpacing) > uint256(uint32(type(int32).max))) {
            revert InvalidPositionBounds();
        }

        PoolKey memory poolKey = PoolKey({
            token0: token0, token1: token1, config: createConcentratedPoolConfig(fee, tickSpacing, address(this))
        });

        CORE_REF = core;
        POOL_KEY = poolKey;
        POOL_ID = poolKey.toPoolId();
        TOKEN0 = token0;
        TOKEN1 = token1;
        TICK_SPACING = tickSpacing;
        N = n;
        INITIAL_TICK = initialTick;
        MAX_CONTRIBUTION_TO_LIQUIDITY_BPS = maxContributionToLiquidityBps;
        INITIALIZER = initializer;
        _name = name_;
        _symbol = symbol_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return autoRebalanceCallPoints();
    }

    function initializePool() external {
        if (_initialized) revert PoolAlreadyInitialized();
        if (INITIALIZER != address(0) && msg.sender != INITIALIZER) revert InitializerOnly();
        CORE_REF.initializePool(POOL_KEY, INITIAL_TICK);
        _initialized = true;
        lastProcessedBlock = uint64(block.number);
        PoolState state = CORE_REF.poolState(POOL_ID);
        lastBlockStartTick = state.tick();
        lastBlockStartSqrtRatio = state.sqrtRatio();
        emit PoolInitialized(INITIAL_TICK);
    }

    function contribute(uint128 amount0, uint128 amount1, address recipient, uint256 minShares, uint64 deadlineBlock)
        external
        returns (uint256 contributionId)
    {
        if (amount0 == 0 && amount1 == 0) revert ZeroContribution();
        if (deadlineBlock != 0 && deadlineBlock <= block.number) revert ContributionExpired();
        sync();

        PoolState state = CORE_REF.poolState(POOL_ID);
        if (!state.isInitialized()) revert PoolNotInitialized();

        uint256 contributionValue0 = _value0(amount0, amount1, state.sqrtRatio());
        uint64 eligibleBlock = uint64(block.number + 1);

        if (totalSupply() != 0) {
            uint256 activeValue0 = _activeLiquidityValue0(activeLiquidity, state.sqrtRatio(), activePositionId);
            if (activeValue0 != 0) {
                uint256 pendingValue0 = batches[eligibleBlock].value0;
                if (
                    pendingValue0 + contributionValue0
                        > FixedPointMathLib.fullMulDiv(activeValue0, MAX_CONTRIBUTION_TO_LIQUIDITY_BPS, 10_000)
                ) {
                    revert ContributionTooLarge();
                }
            }
        }

        if (amount0 != 0) SafeTransferLib.safeTransferFrom(TOKEN0, msg.sender, address(this), amount0);
        if (amount1 != 0) SafeTransferLib.safeTransferFrom(TOKEN1, msg.sender, address(this), amount1);

        contributionId = nextContributionId++;
        contributions[contributionId] = Contribution({
            eligibleBlock: eligibleBlock,
            deadlineBlock: deadlineBlock,
            recipient: recipient,
            amount0: amount0,
            amount1: amount1,
            minShares: minShares,
            claimableShares: 0,
            settled: false,
            refundable: false
        });

        Batch storage batch = batches[eligibleBlock];
        if (!batch.exists) {
            batch.exists = true;
            pendingBatchBlocks.push(eligibleBlock);
        }
        batch.amount0 += amount0;
        batch.amount1 += amount1;
        batch.value0 += contributionValue0;
        _batchContributionIds[eligibleBlock].push(contributionId);

        emit ContributionSubmitted(contributionId, eligibleBlock, recipient, amount0, amount1, minShares);
    }

    function processPending(uint256 contributionId) external returns (uint256 shares) {
        sync();
        Contribution storage contribution = contributions[contributionId];
        shares = contribution.claimableShares;
    }

    function claimContribution(uint256 contributionId) external returns (uint256 shares) {
        sync();
        Contribution storage contribution = contributions[contributionId];
        if (contribution.settled) revert ContributionAlreadySettled();
        shares = contribution.claimableShares;
        if (shares == 0) revert ContributionNotEligible();
        contribution.settled = true;
        _transfer(address(this), contribution.recipient, shares);
        emit ContributionClaimed(contributionId, contribution.recipient, shares);
    }

    function refundContribution(uint256 contributionId) external returns (uint128 amount0, uint128 amount1) {
        sync();
        Contribution storage contribution = contributions[contributionId];
        if (contribution.settled) revert ContributionAlreadySettled();
        if (contribution.claimableShares != 0) revert ContributionNotEligible();
        if (!contribution.refundable && (contribution.deadlineBlock == 0 || block.number <= contribution.deadlineBlock))
        {
            revert ContributionNotEligible();
        }
        contribution.settled = true;
        amount0 = contribution.amount0;
        amount1 = contribution.amount1;
        if (amount0 != 0) SafeTransferLib.safeTransfer(TOKEN0, contribution.recipient, amount0);
        if (amount1 != 0) SafeTransferLib.safeTransfer(TOKEN1, contribution.recipient, amount1);
        emit ContributionRefunded(contributionId, contribution.recipient, amount0, amount1);
    }

    function withdraw(uint256 shares, uint128 minAmount0, uint128 minAmount1, address receiver)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        bytes memory result = lock(abi.encode(CALL_WITHDRAW, msg.sender, shares, minAmount0, minAmount1, receiver));
        (amount0, amount1) = abi.decode(result, (uint128, uint128));
    }

    function swap(SwapParameters params, int256 calculatedAmountThreshold, address recipient)
        external
        returns (PoolBalanceUpdate balanceUpdate)
    {
        bytes memory result = lock(abi.encode(CALL_SWAP, msg.sender, params, calculatedAmountThreshold, recipient));
        balanceUpdate = abi.decode(result, (PoolBalanceUpdate));
    }

    function sync() public {
        if (_syncing || block.number == lastProcessedBlock) return;
        lock(abi.encode(CALL_SYNC));
    }

    function beforeInitializePool(address caller, PoolKey calldata key, int32 tick)
        external
        override(BaseExtension)
        onlyCore
    {
        if (caller != address(this) || tick != INITIAL_TICK || PoolId.unwrap(key.toPoolId()) != PoolId.unwrap(POOL_ID))
        {
            revert InvalidPoolConfig();
        }
    }

    function beforeUpdatePosition(Locker locker, PoolKey memory poolKey, PositionId positionId, int128)
        external
        override(BaseExtension)
        onlyCore
    {
        if (
            !_updatingPosition || locker.addr() != address(this)
                || PoolId.unwrap(poolKey.toPoolId()) != PoolId.unwrap(POOL_ID)
                || PositionId.unwrap(positionId) != PositionId.unwrap(_allowedPositionId)
        ) {
            revert UnauthorizedPositionUpdate();
        }
    }

    function beforeSwap(Locker locker, PoolKey memory poolKey, SwapParameters)
        external
        view
        override(BaseExtension)
        onlyCore
    {
        if (
            !_internalSwap || locker.addr() != address(this)
                || PoolId.unwrap(poolKey.toPoolId()) != PoolId.unwrap(POOL_ID)
        ) {
            revert DirectSwapDisabled();
        }
    }

    function afterSwap(Locker, PoolKey memory poolKey, SwapParameters, PoolBalanceUpdate, PoolState stateAfter)
        external
        view
        override(BaseExtension)
        onlyCore
    {
        if (PoolId.unwrap(poolKey.toPoolId()) != PoolId.unwrap(POOL_ID)) revert InvalidPoolConfig();
        _validateSwapState(stateAfter);
    }

    function _validateSwapState(PoolState stateAfter) private view {
        uint256 limit = uint256(N) * uint256(TICK_SPACING) * 2;
        if (FixedPointMathLib.dist(int256(stateAfter.tick()), int256(lastBlockStartTick)) > limit) {
            revert PriceMoveLimitExceeded();
        }
        if (activeLiquidity != 0) {
            if (stateAfter.tick() < activePositionId.tickLower() || stateAfter.tick() >= activePositionId.tickUpper()) {
                revert PriceMoveLimitExceeded();
            }
        }
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));
        if (callType == CALL_SYNC) {
            _syncBlockInLock();
            return "";
        }
        if (callType == CALL_SWAP) {
            (, address swapper, SwapParameters params, int256 calculatedAmountThreshold, address recipient) =
                abi.decode(data, (uint256, address, SwapParameters, int256, address));
            _syncBlockInLock();
            if (activeLiquidity == 0) revert NoActiveLiquidity();
            _internalSwap = true;
            (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) =
                CORE_REF.swap(0, POOL_KEY, params.withDefaultSqrtRatioLimit());
            _internalSwap = false;
            _validateSwapState(stateAfter);

            (int256 amountCalculated, int256 amountSpecified) = params.isToken1()
                ? (-int256(balanceUpdate.delta0()), balanceUpdate.delta1())
                : (-int256(balanceUpdate.delta1()), balanceUpdate.delta0());
            if (amountSpecified != params.amount()) revert SlippageLimitExceeded();
            if (amountCalculated < calculatedAmountThreshold) revert SlippageLimitExceeded();

            if (balanceUpdate.delta0() > 0) {
                ACCOUNTANT.payFrom(swapper, TOKEN0, uint128(balanceUpdate.delta0()));
            } else if (balanceUpdate.delta0() < 0) {
                ACCOUNTANT.withdraw(TOKEN0, recipient, uint128(-balanceUpdate.delta0()));
            }
            if (balanceUpdate.delta1() > 0) {
                ACCOUNTANT.payFrom(swapper, TOKEN1, uint128(balanceUpdate.delta1()));
            } else if (balanceUpdate.delta1() < 0) {
                ACCOUNTANT.withdraw(TOKEN1, recipient, uint128(-balanceUpdate.delta1()));
            }
            result = abi.encode(balanceUpdate);
        } else if (callType == CALL_WITHDRAW) {
            (, address owner, uint256 shares, uint128 minAmount0, uint128 minAmount1, address receiver) =
                abi.decode(data, (uint256, address, uint256, uint128, uint128, address));
            _syncBlockInLock();
            (uint128 amount0, uint128 amount1) = _withdrawInLock(owner, shares, minAmount0, minAmount1, receiver);
            result = abi.encode(amount0, amount1);
        }
    }

    function _syncBlockInLock() private {
        if (_syncing || block.number == lastProcessedBlock) return;
        _syncing = true;

        if (!CORE_REF.poolState(POOL_ID).isInitialized()) {
            _syncing = false;
            return;
        }

        if (activeLiquidity != 0) {
            _collectFees(activePositionId);
            _updateLiquidity(activePositionId, -int128(activeLiquidity));
            activeLiquidity = 0;
        }

        PoolState state = CORE_REF.poolState(POOL_ID);
        lastBlockStartTick = state.tick();
        lastBlockStartSqrtRatio = state.sqrtRatio();

        _processEligibleBatches(state.sqrtRatio());
        _rebalance(state);

        lastProcessedBlock = uint64(block.number);
        _syncing = false;
    }

    function _processEligibleBatches(SqrtRatio sqrtRatio) private {
        uint256 supply = totalSupply();
        uint256 length = pendingBatchBlocks.length;
        uint256 i;
        while (i < length) {
            uint64 blockNumber = pendingBatchBlocks[i];
            Batch storage batch = batches[blockNumber];
            if (!batch.processed && blockNumber <= block.number) {
                uint256[] storage ids = _batchContributionIds[blockNumber];
                uint256 assetsBefore = _value0(idle0, idle1, sqrtRatio);

                uint128 accepted0;
                uint128 accepted1;
                uint256 batchValue0;
                uint256 batchShares;
                for (uint256 j = 0; j < ids.length; j++) {
                    Contribution storage contribution = contributions[ids[j]];
                    if (contribution.deadlineBlock != 0 && block.number > contribution.deadlineBlock) {
                        contribution.refundable = true;
                        continue;
                    }
                    uint256 value0 = _value0(contribution.amount0, contribution.amount1, sqrtRatio);
                    uint256 shares;
                    if (supply == 0) {
                        shares = value0;
                    } else {
                        if (assetsBefore == 0) {
                            contribution.refundable = true;
                            continue;
                        }
                        shares = FixedPointMathLib.fullMulDiv(value0, supply, assetsBefore);
                    }
                    if (shares < contribution.minShares) {
                        contribution.refundable = true;
                        continue;
                    }
                    contribution.claimableShares = shares;
                    accepted0 += contribution.amount0;
                    accepted1 += contribution.amount1;
                    batchValue0 += value0;
                    batchShares += shares;
                }

                if (batchShares != 0) {
                    _mint(address(this), batchShares);
                    idle0 += accepted0;
                    idle1 += accepted1;
                    supply += batchShares;
                }
                batch.amount0 = accepted0;
                batch.amount1 = accepted1;
                batch.shares = batchShares;
                batch.value0Processed = batchValue0;
                batch.processed = true;
                emit ContributionProcessed(blockNumber, batchShares, accepted0, accepted1);

                pendingBatchBlocks[i] = pendingBatchBlocks[length - 1];
                pendingBatchBlocks.pop();
                length--;
            } else {
                i++;
            }
        }
    }

    function _rebalance(PoolState state) private {
        (PositionId positionId, int32 lower, int32 upper) = _positionForTick(state.tick());
        uint128 liquidity =
            maxLiquidity(state.sqrtRatio(), tickToSqrtRatio(lower), tickToSqrtRatio(upper), idle0, idle1);
        if (liquidity != 0) {
            (int128 delta0, int128 delta1) = _updateLiquidity(positionId, int128(liquidity));
            idle0 -= uint128(delta0);
            idle1 -= uint128(delta1);
            activeLiquidity = liquidity;
            activePositionId = positionId;
        } else {
            activePositionId = positionId;
        }
        emit Rebalanced(state.tick(), activePositionId, activeLiquidity, idle0, idle1);
    }

    function _withdrawInLock(address owner, uint256 shares, uint128 minAmount0, uint128 minAmount1, address receiver)
        private
        returns (uint128 amount0, uint128 amount1)
    {
        uint256 supply = totalSupply();
        if (shares == 0 || shares > balanceOf(owner)) revert ZeroShares();
        if (activeLiquidity != 0) _collectFees(activePositionId);

        uint128 liquidityToRemove = uint128(FixedPointMathLib.fullMulDiv(activeLiquidity, shares, supply));
        if (liquidityToRemove != 0) {
            uint128 remainingLiquidity = activeLiquidity - liquidityToRemove;
            uint256 floor = _requiredActiveLiquidityValue0();
            if (floor != 0) {
                PoolState state = CORE_REF.poolState(POOL_ID);
                uint256 remainingValue = _activeLiquidityValue0(remainingLiquidity, state.sqrtRatio(), activePositionId);
                if (remainingValue < floor) revert PendingContributionLiquidityFloor();
            }
            _updateLiquidity(activePositionId, -int128(liquidityToRemove));
            activeLiquidity = remainingLiquidity;
        }

        amount0 = uint128(FixedPointMathLib.fullMulDiv(idle0, shares, supply));
        amount1 = uint128(FixedPointMathLib.fullMulDiv(idle1, shares, supply));
        if (amount0 < minAmount0 || amount1 < minAmount1) revert SlippageLimitExceeded();

        _burn(owner, shares);
        idle0 -= amount0;
        idle1 -= amount1;
        if (amount0 != 0) SafeTransferLib.safeTransfer(TOKEN0, receiver, amount0);
        if (amount1 != 0) SafeTransferLib.safeTransfer(TOKEN1, receiver, amount1);
        emit Withdrawn(owner, receiver, shares, amount0, amount1);
    }

    function _collectFees(PositionId positionId) private {
        (uint128 fees0, uint128 fees1) = CORE_REF.collectFees(POOL_KEY, positionId);
        if (fees0 != 0 || fees1 != 0) {
            ACCOUNTANT.withdrawTwo(TOKEN0, TOKEN1, address(this), fees0, fees1);
            idle0 += fees0;
            idle1 += fees1;
        }
    }

    function _updateLiquidity(PositionId positionId, int128 liquidityDelta)
        private
        returns (int128 delta0, int128 delta1)
    {
        _updatingPosition = true;
        _allowedPositionId = positionId;
        PoolBalanceUpdate balanceUpdate = CORE_REF.updatePosition(POOL_KEY, positionId, liquidityDelta);
        _allowedPositionId = PositionId.wrap(bytes32(0));
        _updatingPosition = false;
        delta0 = balanceUpdate.delta0();
        delta1 = balanceUpdate.delta1();
        if (delta0 > 0 || delta1 > 0) {
            if (delta0 > 0) ACCOUNTANT.pay(TOKEN0, uint128(delta0));
            if (delta1 > 0) ACCOUNTANT.pay(TOKEN1, uint128(delta1));
        } else if (delta0 < 0 || delta1 < 0) {
            uint128 amount0 = delta0 < 0 ? uint128(-delta0) : 0;
            uint128 amount1 = delta1 < 0 ? uint128(-delta1) : 0;
            ACCOUNTANT.withdrawTwo(TOKEN0, TOKEN1, address(this), amount0, amount1);
            idle0 += amount0;
            idle1 += amount1;
        }
    }

    function _positionForTick(int32 tick) private view returns (PositionId positionId, int32 lower, int32 upper) {
        int32 spacing = int32(TICK_SPACING);
        int32 center = (tick / spacing) * spacing;
        uint256 widthU256 = uint256(N) * uint256(TICK_SPACING);
        int32 width = int32(uint32(widthU256));
        lower = center - width;
        upper = center + width;
        if (lower < MIN_TICK) lower = (MIN_TICK / spacing) * spacing;
        if (upper > MAX_TICK) upper = (MAX_TICK / spacing) * spacing;
        if (lower >= upper) revert InvalidPositionBounds();
        positionId = createPositionId(bytes24(0), lower, upper);
    }

    function _activeLiquidityValue0(uint128 liquidity, SqrtRatio sqrtRatio, PositionId positionId)
        private
        pure
        returns (uint256)
    {
        if (liquidity == 0) return 0;
        (int128 amount0, int128 amount1) = liquidityDeltaToAmountDelta(
            sqrtRatio,
            int128(liquidity),
            tickToSqrtRatio(positionId.tickLower()),
            tickToSqrtRatio(positionId.tickUpper())
        );
        return _value0(uint128(amount0), uint128(amount1), sqrtRatio);
    }

    function _value0(uint128 amount0, uint128 amount1, SqrtRatio sqrtRatio) private pure returns (uint256 value) {
        value = amount0;
        if (amount1 != 0) {
            uint256 fixedSqrt = sqrtRatio.toFixed();
            uint256 token1Value0 = FixedPointMathLib.fullMulDiv(amount1, 1 << 128, fixedSqrt);
            token1Value0 = FixedPointMathLib.fullMulDiv(token1Value0, 1 << 128, fixedSqrt);
            value += token1Value0;
        }
    }

    function _requiredActiveLiquidityValue0() private view returns (uint256 required) {
        uint256 length = pendingBatchBlocks.length;
        for (uint256 i = 0; i < length; i++) {
            Batch storage batch = batches[pendingBatchBlocks[i]];
            if (!batch.processed) {
                uint256 value = FixedPointMathLib.fullMulDivUp(batch.value0, 10_000, MAX_CONTRIBUTION_TO_LIQUIDITY_BPS);
                required += value;
            }
        }
    }

    function _beforeTokenTransfer(address, address, uint256) internal override {
        sync();
    }
}
