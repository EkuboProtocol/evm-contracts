// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {Router} from "../../src/Router.sol";
import {Ve33Periphery} from "../../src/Ve33Periphery.sol";
import {Ve33Positions} from "../../src/Ve33Positions.sol";
import {VeToken} from "../../src/VeToken.sol";
import {
    Ve33,
    VE33_POOL_FEES_SAVED_BALANCE_ID,
    VE33_STAKE_TOKEN_SAVED_BALANCE_ID,
    ve33CallPoints
} from "../../src/extensions/Ve33.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IVe33} from "../../src/interfaces/extensions/IVe33.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {Ve33Lib} from "../../src/libraries/Ve33Lib.sol";
import {FeesPerLiquidity} from "../../src/types/feesPerLiquidity.sol";
import {computeFee} from "../../src/math/fee.sol";
import {nextValidTime} from "../../src/math/time.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {liquidityDeltaToAmountDelta} from "../../src/math/liquidity.sol";
import {timeToBitmapWordAndIndex} from "../../src/math/timeBitmap.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PoolConfig, createConcentratedPoolConfig, createStableswapPoolConfig} from "../../src/types/poolConfig.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PositionId} from "../../src/types/positionId.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {StakeId, createStakeId} from "../../src/types/stakeId.sol";
import {Locker} from "../../src/types/locker.sol";
import {VePoolVote} from "../../src/types/vePoolVote.sol";
import {VePoolFeeState} from "../../src/types/vePoolFeeState.sol";
import {Vm} from "forge-std/Test.sol";

contract Ve33Forwarder is BaseLocker {
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_SCHEDULE_EMISSIONS = 0;
    uint256 private constant CALL_TYPE_CLAIM_POOL_FEES = 4;
    uint256 private constant CALL_TYPE_STAKE = 5;
    uint256 private constant CALL_TYPE_UNSTAKE = 6;

    ICore private immutable CORE_REF;
    Ve33 private immutable VE33_REF;
    address private immutable STAKE_TOKEN;

    constructor(ICore core, Ve33 ve33, address stakeToken) BaseLocker(core) {
        CORE_REF = core;
        VE33_REF = ve33;
        STAKE_TOKEN = stakeToken;
    }

    function scheduleEmissions(uint64 startTime, uint64 endTime, uint160 rewardRate) external returns (uint128 amount) {
        amount = abi.decode(
            lock(abi.encode(CALL_TYPE_SCHEDULE_EMISSIONS, msg.sender, startTime, endTime, rewardRate)), (uint128)
        );
    }

    function claimPoolFees(StakeId stakeId, PoolKey calldata poolKey)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) =
            abi.decode(lock(abi.encode(CALL_TYPE_CLAIM_POOL_FEES, stakeId, poolKey)), (uint128, uint128));
    }

    function stake(StakeId stakeId, uint128 amount) external returns (uint128 nextAmount) {
        nextAmount = abi.decode(lock(abi.encode(CALL_TYPE_STAKE, msg.sender, stakeId, amount)), (uint128));
    }

    function unstake(StakeId stakeId) external returns (uint128 unstaked) {
        unstaked = abi.decode(lock(abi.encode(CALL_TYPE_UNSTAKE, stakeId)), (uint128));
    }

    function moveStake(StakeId fromStakeId, StakeId toStakeId, uint128 amount) external returns (uint128 nextAmount) {
        nextAmount = VE33_REF.moveStake(fromStakeId, toStakeId, amount);
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_SCHEDULE_EMISSIONS) {
            (, address payer, uint64 startTime, uint64 endTime, uint160 rewardRate) =
                abi.decode(data, (uint256, address, uint64, uint64, uint160));
            uint128 amount = Ve33Lib.scheduleEmissions(CORE_REF, VE33_REF, startTime, endTime, rewardRate);
            result = abi.encode(amount);
            if (amount != 0) ACCOUNTANT.payFrom(payer, STAKE_TOKEN, amount);
        } else if (callType == CALL_TYPE_CLAIM_POOL_FEES) {
            (, StakeId stakeId, PoolKey memory poolKey) = abi.decode(data, (uint256, StakeId, PoolKey));
            (uint128 amount0, uint128 amount1) = Ve33Lib.claimPoolFees(CORE_REF, VE33_REF, stakeId, poolKey);
            result = abi.encode(amount0, amount1);
        } else if (callType == CALL_TYPE_STAKE) {
            (, address payer, StakeId stakeId, uint128 amount) = abi.decode(data, (uint256, address, StakeId, uint128));
            uint128 nextAmount = Ve33Lib.stake(CORE_REF, VE33_REF, stakeId, amount);
            result = abi.encode(nextAmount);
            if (amount != 0) ACCOUNTANT.payFrom(payer, STAKE_TOKEN, amount);
        } else if (callType == CALL_TYPE_UNSTAKE) {
            (, StakeId stakeId) = abi.decode(data, (uint256, StakeId));
            uint128 unstaked = Ve33Lib.unstake(CORE_REF, VE33_REF, stakeId);
            result = abi.encode(unstaked);
            ACCOUNTANT.withdraw(STAKE_TOKEN, msg.sender, unstaked);
        } else {
            revert();
        }
    }
}

contract Ve33Test is FullTest {
    using CoreLib for *;
    using Ve33Lib for Ve33;

    Ve33 internal ve;
    VeToken internal veToken;
    Ve33Positions internal vePositions;
    Ve33Forwarder internal forwarder;
    Ve33Periphery internal periphery;
    TestToken internal stakeToken;
    uint256 internal nextPositionSalt = 1;
    mapping(bytes32 positionKey => uint256 nftId) internal positionNftIds;

    function setUp() public override {
        super.setUp();

        stakeToken = new TestToken(address(this));
        address deployAddress = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("Ve33.sol", abi.encode(core, address(stakeToken)), deployAddress);
        ve = Ve33(payable(deployAddress));
        router = new Router(core, address(0), address(ve));
        veToken = new VeToken(core, ve, "Vote Escrow TestToken", "veTT", "TestToken", "TT", 18);
        vePositions = new Ve33Positions(core, ve, owner);
        forwarder = new Ve33Forwarder(core, ve, address(stakeToken));
        periphery = new Ve33Periphery(core, ve);

        stakeToken.approve(address(ve), type(uint256).max);
        stakeToken.approve(address(veToken), type(uint256).max);
        stakeToken.approve(address(forwarder), type(uint256).max);
        stakeToken.approve(address(periphery), type(uint256).max);
        stakeToken.approve(address(vePositions), type(uint256).max);
        token0.approve(address(forwarder), type(uint256).max);
        token1.approve(address(forwarder), type(uint256).max);
        token0.approve(address(periphery), type(uint256).max);
        token1.approve(address(periphery), type(uint256).max);
        token0.approve(address(vePositions), type(uint256).max);
        token1.approve(address(vePositions), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
    }

    function coolAllContracts() internal virtual override {
        FullTest.coolAllContracts();
        vm.cool(address(ve));
        vm.cool(address(veToken));
        vm.cool(address(vePositions));
        vm.cool(address(forwarder));
        vm.cool(address(periphery));
        vm.cool(address(stakeToken));
    }

    function _createConcentratedPool() internal returns (PoolKey memory poolKey, PositionId positionId) {
        poolKey = createPool({tick: 0, fee: 0, tickSpacing: 64, extension: address(ve)});
        positionId = _mintPosition(-64, 64);
    }

    function _createConcentratedPool(uint32 tickSpacing, bytes24 salt)
        internal
        returns (PoolKey memory poolKey, PositionId positionId)
    {
        poolKey = createPool({tick: 0, fee: 0, tickSpacing: tickSpacing, extension: address(ve)});
        positionId = _mintPosition(bytes32(salt), -int32(tickSpacing), int32(tickSpacing));
    }

    function _createStableswapPool(uint8 amplification, int32 tick)
        internal
        returns (PoolKey memory poolKey, PositionId positionId)
    {
        PoolConfig config = createStableswapPoolConfig(0, amplification, 0, address(ve));
        poolKey = createPool(address(token0), address(token1), tick, config);
        (int32 lower, int32 upper) = config.stableswapActiveLiquidityTickRange();
        positionId = _mintPosition(lower, upper);
    }

    function _mintPosition(int32 tickLower, int32 tickUpper) internal returns (PositionId positionId) {
        bytes32 salt = bytes32(nextPositionSalt);
        unchecked {
            ++nextPositionSalt;
        }
        positionId = _mintPosition(salt, tickLower, tickUpper);
    }

    function _mintPosition(bytes32 salt, int32 tickLower, int32 tickUpper) internal returns (PositionId positionId) {
        uint256 id = vePositions.mint(salt);
        positionId = vePositions.positionId(id, tickLower, tickUpper);
        positionNftIds[PositionId.unwrap(positionId)] = id;
    }

    function _positionNftId(PositionId positionId) internal view returns (uint256 id) {
        id = positionNftIds[PositionId.unwrap(positionId)];
        assertNotEq(id, 0);
    }

    function _positionLiquidity(PoolKey memory poolKey, PositionId positionId) internal view returns (uint128) {
        return core.poolPositions(poolKey.toPoolId(), address(vePositions), positionId).liquidity;
    }

    function _createStake() internal returns (uint256 veId) {
        veId = veToken.createStake(1e18, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()));
    }

    function _stakeId(uint256 veId) internal view returns (StakeId) {
        return veToken.stakeId(veId);
    }

    function _updatePosition(PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta)
        internal
        returns (PoolBalanceUpdate balanceUpdate)
    {
        uint256 id = _positionNftId(positionId);
        if (liquidityDelta > 0) {
            (int128 delta0, int128 delta1) = liquidityDeltaToAmountDelta(
                core.poolState(poolKey.toPoolId()).sqrtRatio(),
                liquidityDelta,
                tickToSqrtRatio(positionId.tickLower()),
                tickToSqrtRatio(positionId.tickUpper())
            );
            (, uint128 amount0, uint128 amount1) = vePositions.deposit(
                id,
                poolKey,
                positionId.tickLower(),
                positionId.tickUpper(),
                uint128(delta0),
                uint128(delta1),
                uint128(liquidityDelta)
            );
            balanceUpdate = createPoolBalanceUpdate(int128(amount0), int128(amount1));
        } else {
            (uint128 amount0, uint128 amount1) = vePositions.withdraw(
                id,
                poolKey,
                positionId.tickLower(),
                positionId.tickUpper(),
                uint128(uint256(-int256(liquidityDelta))),
                address(this)
            );
            balanceUpdate = createPoolBalanceUpdate(-int128(amount0), -int128(amount1));
        }
    }

    function _claimRewards(PoolKey memory poolKey, PositionId positionId, address recipient)
        internal
        returns (uint256 amount)
    {
        amount = vePositions.claimRewards(
            _positionNftId(positionId), poolKey, positionId.tickLower(), positionId.tickUpper(), recipient
        );
    }

    function _routerSwap(PoolKey memory poolKey, bool isToken1, int128 amount, address recipient)
        internal
        returns (PoolBalanceUpdate balanceUpdate)
    {
        balanceUpdate = _routerSwap(
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: amount, _isToken1: isToken1, _skipAhead: 0
            }),
            recipient
        );
    }

    function _routerSwap(PoolKey memory poolKey, SwapParameters params, address recipient)
        internal
        returns (PoolBalanceUpdate balanceUpdate)
    {
        balanceUpdate = router.swapAllowPartialFill(poolKey, params, recipient);
    }

    function _vote(uint256 veId, PoolKey memory poolKey, uint64 swapFee) internal {
        veToken.vote(veId, poolKey, swapFee);
    }

    function _poolVoteTotals(PoolId poolId)
        internal
        view
        returns (uint256 weight, uint256 feeWeightSum, uint64 swapFee)
    {
        VePoolFeeState feeState = ve.poolFeeState(poolId);
        weight = ve.poolTotalWeight(poolId);
        feeWeightSum = feeState.feeWeightSum();
        swapFee = feeState.swapFee();
    }

    function _fundAndVote(PoolKey memory poolKey, uint64 swapFee) internal returns (uint256 veId) {
        veId = _createStake();
        _vote(veId, poolKey, swapFee);
    }

    function _nextValidRewardTime(uint256 afterTime) internal view returns (uint64) {
        return uint64(nextValidTime(vm.getBlockTimestamp(), afterTime));
    }

    function _defaultEmissionEnd() internal view returns (uint64) {
        return _nextValidRewardTime(vm.getBlockTimestamp() + 1 weeks - 1);
    }

    function _emissionRateForAmount(uint128 amount, uint64 endTime) internal view returns (uint160) {
        return uint160((uint256(amount) << 32) / (endTime - vm.getBlockTimestamp()));
    }

    function _scheduleEmissions(uint128 amount, uint64 endTime) internal returns (uint128 scheduledAmount) {
        scheduledAmount = forwarder.scheduleEmissions(0, endTime, _emissionRateForAmount(amount, endTime));
    }

    function _rewardSavedBalance(bytes32 salt) internal view returns (uint128 saved) {
        (saved,) = core.savedBalances(address(ve), address(stakeToken), address(type(uint160).max), salt);
    }

    function _assertEmissionTimeInitialized(uint64 time, bool initialized) internal view {
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
        assertEq((ve.emissionInitializedTimeBitmap(word) & (uint256(1) << index)) != 0, initialized);
    }

    function test_gas_veTokenVote() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        uint256 veId = _createStake();

        coolAllContracts();
        _vote(veId, poolKey, uint64(1 << 62));
        vm.snapshotGasLastCall("Ve33#vote one pool");
    }

    function test_gas_forwardedSwap() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _fundAndVote(poolKey, uint64(1 << 62));

        coolAllContracts();
        _routerSwap(poolKey, false, 100_000, address(this));
        vm.snapshotGasLastCall("Router#ve33Swap");
    }

    function test_gas_claimPoolFees() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        uint256 veId = _fundAndVote(poolKey, uint64(1 << 62));
        _routerSwap(poolKey, false, 100_000, address(this));

        coolAllContracts();
        veToken.claimPoolFeesToSelf(veId, poolKey);
        vm.snapshotGasLastCall("VeToken#claimPoolFees");
    }

    function test_gas_accrueEmissionsOnPoolTouch() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _fundAndVote(poolKey, uint64(1 << 62));
        _scheduleEmissions(10_000, _defaultEmissionEnd());
        vm.warp(vm.getBlockTimestamp() + 1 days);

        coolAllContracts();
        ve.maybeAccumulateRewards(poolKey);
        vm.snapshotGasLastCall("Ve33#emissionAccrualOnPoolTouch");
    }

    function test_gas_stableswapForwardedSwap() public {
        (PoolKey memory poolKey, PositionId positionId) = _createStableswapPool(20, 0);
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _fundAndVote(poolKey, uint64(1 << 62));

        coolAllContracts();
        _routerSwap(poolKey, true, 100_000, address(this));
        vm.snapshotGasLastCall("Router#ve33Stableswap");
    }

    function test_gas_vote() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        uint256 veId = _createStake();

        coolAllContracts();
        veToken.vote(veId, poolKey, uint64(1 << 62));
        vm.snapshotGasLastCall("VeToken#vote");
    }

    function test_gas_updatePosition() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();

        coolAllContracts();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        vm.snapshotGasLastCall("Ve33Positions#deposit");
    }

    function test_gas_routerSwapVe33Position() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _fundAndVote(poolKey, uint64(1 << 62));

        coolAllContracts();
        _routerSwap(
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: int128(100_000), _isToken1: false, _skipAhead: 0
            }),
            address(this)
        );
        vm.snapshotGasLastCall("Router#ve33SwapVe33Position");
    }

    function test_gas_claimRewards() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _fundAndVote(poolKey, uint64(1 << 62));
        _scheduleEmissions(10_000, _defaultEmissionEnd());
        vm.warp(vm.getBlockTimestamp() + 1 days);
        ve.maybeAccumulateRewards(poolKey);

        coolAllContracts();
        _claimRewards(poolKey, positionId, address(this));
        vm.snapshotGasLastCall("Ve33Positions#claimRewards");
    }

    function test_gas_peripheryScheduleEmissions() public {
        uint64 end = _defaultEmissionEnd();

        coolAllContracts();
        periphery.scheduleEmissions(0, end, _emissionRateForAmount(10_000, end));
        vm.snapshotGasLastCall("Ve33Periphery#scheduleEmissions");
    }

    function test_gas_peripheryAccruedEmissionsClaimRewards() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _fundAndVote(poolKey, uint64(1 << 62));
        uint64 end = _defaultEmissionEnd();
        periphery.scheduleEmissions(0, end, _emissionRateForAmount(10_000, end));
        vm.warp(vm.getBlockTimestamp() + 1 days);

        coolAllContracts();
        _claimRewards(poolKey, positionId, address(this));
        vm.snapshotGasLastCall("Ve33Positions#claimAccruedEmissions");
    }

    function test_registrationAndCallPoints() public view {
        assertTrue(core.isExtensionRegistered(address(ve)));
        assertTrue(ve33CallPoints().beforeInitializePool);
        assertTrue(ve33CallPoints().afterInitializePool);
        assertTrue(ve33CallPoints().beforeSwap);
        assertTrue(ve33CallPoints().beforeUpdatePosition);
        assertFalse(ve33CallPoints().afterSwap);
        assertFalse(ve33CallPoints().afterUpdatePosition);
        assertFalse(ve33CallPoints().beforeCollectFees);
        assertFalse(ve33CallPoints().afterCollectFees);
        assertEq(ve.stakeToken(), address(stakeToken));
    }

    function test_poolInitializationRejectsInvalidConfig() public {
        vm.expectRevert(IVe33.FeeMustBeZero.selector);
        createPool({tick: 0, fee: 1, tickSpacing: 64, extension: address(ve)});

        vm.expectRevert(IVe33.TickSpacingMustBePowerOfFour.selector);
        createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(ve)});

        vm.expectRevert(IVe33.TickSpacingMustBePowerOfFour.selector);
        createPool({tick: 0, fee: 0, tickSpacing: 2, extension: address(ve)});

        PoolConfig config = createConcentratedPoolConfig(0, 64, address(ve));
        PoolKey memory poolKey = PoolKey({token0: address(token0), token1: address(token1), config: config});
        PoolId poolId = poolKey.toPoolId();
        core.initializePool(poolKey, 0);

        assertEq(ve.poolTotalWeight(poolId), 0);
        assertEq(ve.poolFeeState(poolId).feeWeightSum(), 0);
    }

    function test_poolInitialization_preservesPreInitializationVotedFee() public {
        PoolConfig config = createConcentratedPoolConfig(0, 64, address(ve));
        PoolKey memory poolKey = PoolKey({token0: address(token0), token1: address(token1), config: config});
        PoolId poolId = poolKey.toPoolId();
        uint64 votedFee = uint64(1 << 62);

        uint256 veId = _createStake();
        _vote(veId, poolKey, votedFee);

        (uint256 weight, uint256 feeWeightSum, uint64 swapFee) = _poolVoteTotals(poolId);
        assertEq(weight, veToken.votingPower(veId));
        assertEq(feeWeightSum, weight * votedFee);
        assertEq(swapFee, votedFee);

        core.initializePool(poolKey, 0);

        (weight, feeWeightSum, swapFee) = _poolVoteTotals(poolId);
        assertEq(weight, veToken.votingPower(veId));
        assertEq(feeWeightSum, weight * votedFee);
        assertEq(swapFee, votedFee);
    }

    function test_voteWeightAppliedEventsDescribeCurrentVoteState() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        PoolId poolId = poolKey.toPoolId();
        uint64 fee0 = 100;
        uint64 fee1 = 300;

        uint256 veId0 = _createStake();
        uint256 veId1 = _createStake();
        uint128 power0 = uint128(veToken.votingPower(veId0));
        uint128 power1 = uint128(veToken.votingPower(veId1));

        vm.expectEmit(address(ve));
        emit IVe33.VoteWeightApplied(address(veToken), _stakeId(veId0), poolId, power0, fee0);
        _vote(veId0, poolKey, fee0);

        uint64 currentSwapFee = uint64((uint256(power0) * fee0 + uint256(power1) * fee1) / (power0 + power1));
        vm.expectEmit(address(ve));
        emit IVe33.VoteWeightApplied(address(veToken), _stakeId(veId1), poolId, power1, currentSwapFee);
        _vote(veId1, poolKey, fee1);

        vm.expectEmit(address(ve));
        emit IVe33.VoteWeightApplied(address(veToken), _stakeId(veId0), poolId, 0, fee1);
        veToken.clearVote(veId0);

        vm.warp(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        vm.expectEmit(address(ve));
        emit IVe33.VoteWeightApplied(address(veToken), _stakeId(veId1), poolId, 0, 0);
        veToken.withdrawStake(veId1);
    }

    function test_directHooksAndInvalidCoreLockRevert() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        SwapParameters params = createSwapParameters({
            _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: int128(1), _isToken1: false, _skipAhead: 0
        });

        vm.expectRevert(IVe33.SwapMustHappenThroughForward.selector);
        ve.beforeSwap(Locker.wrap(bytes32(0)), poolKey, params);

        vm.expectRevert();
        ve.beforeUpdatePosition(Locker.wrap(bytes32(0)), poolKey, positionId, 0);

        vm.prank(address(ve));
        (bool success,) = address(core).call(abi.encodeWithSelector(core.lock.selector, uint256(999)));
        assertFalse(success);
    }

    function test_voteValidation() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        uint256 veId = _createStake();

        PoolKey memory wrongExtensionPool = createPool({tick: 0, fee: 0, tickSpacing: 64, extension: address(0)});
        vm.expectRevert(IVe33.IncorrectPoolExtension.selector);
        veToken.vote(veId, wrongExtensionPool, 1);

        PoolConfig wrongFeeConfig = createConcentratedPoolConfig(1, 64, address(ve));
        PoolKey memory wrongFeePool =
            PoolKey({token0: address(token0), token1: address(token1), config: wrongFeeConfig});
        vm.expectRevert(IVe33.FeeMustBeZero.selector);
        veToken.vote(veId, wrongFeePool, 1);

        PoolConfig invalidTickSpacingConfig = createConcentratedPoolConfig(0, 100, address(ve));
        PoolKey memory invalidTickSpacingPool =
            PoolKey({token0: address(token0), token1: address(token1), config: invalidTickSpacingConfig});
        vm.expectRevert(IVe33.TickSpacingMustBePowerOfFour.selector);
        veToken.vote(veId, invalidTickSpacingPool, 1);

        veToken.vote(veId, poolKey, type(uint64).max);
        VePoolVote vote = ve.vePoolVote(address(veToken), _stakeId(veId));
        (uint256 weight, uint256 feeWeightSum, uint64 swapFee) = _poolVoteTotals(poolKey.toPoolId());
        assertEq(vote.timestamp(), vm.getBlockTimestamp());
        assertEq(feeWeightSum, weight * type(uint64).max);
        assertEq(swapFee, type(uint64).max);

        vm.warp(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        uint256 expiredVeId = veToken.createStake(1, uint64(vm.getBlockTimestamp() + 1));
        vm.warp(vm.getBlockTimestamp() + 1);
        veToken.vote(expiredVeId, poolKey, 1);
        (uint256 weightAfterExpiredVote, uint256 feeWeightSumAfterExpiredVote, uint64 swapFeeAfterExpiredVote) =
            _poolVoteTotals(poolKey.toPoolId());
        assertEq(weightAfterExpiredVote, weight);
        assertEq(feeWeightSumAfterExpiredVote, feeWeightSum);
        assertEq(swapFeeAfterExpiredVote, swapFee);
    }

    function test_forwardedSwapAccountsVoterFee() public {
        vm.warp(1);

        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint64 swapFee = uint64(1 << 62);
        uint256 veId = _fundAndVote(poolKey, swapFee);

        vm.recordLogs();
        PoolBalanceUpdate balanceUpdate = _routerSwap(poolKey, false, 100_000, address(this));
        Vm.Log[] memory swapLogs = vm.getRecordedLogs();

        (uint128 saved0, uint128 saved1) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, VE33_POOL_FEES_SAVED_BALANCE_ID);
        uint128 outputAfterFee = uint128(uint256(-int256(balanceUpdate.delta1())));
        uint128 expectedFee = computeFee(outputAfterFee + saved1, swapFee);
        assertEq(saved0, 0);
        assertEq(saved1, expectedFee);

        bytes32 poolFeesAccountedTopic = keccak256("PoolFeesAccounted(bytes32,uint128,uint128)");
        bool sawPoolFeesAccounted;
        for (uint256 i = 0; i < swapLogs.length; i++) {
            if (
                swapLogs[i].emitter == address(ve) && swapLogs[i].topics.length != 0
                    && swapLogs[i].topics[0] == poolFeesAccountedTopic
            ) {
                (PoolId emittedPoolId, uint128 amount0, uint128 amount1) =
                    abi.decode(swapLogs[i].data, (PoolId, uint128, uint128));
                assertEq(PoolId.unwrap(emittedPoolId), PoolId.unwrap(poolKey.toPoolId()));
                assertEq(amount0, 0);
                assertEq(amount1, expectedFee);
                sawPoolFeesAccounted = true;
            }
        }
        assertTrue(sawPoolFeesAccounted);

        uint256 balanceBefore = token1.balanceOf(address(this));
        StakeId stakeId = _stakeId(veId);
        vm.expectRevert(IVe33.PoolNotVoted.selector);
        forwarder.claimPoolFees(stakeId, poolKey);
        (uint128 claimed0, uint128 claimed1) = veToken.claimPoolFeesToSelf(veId, poolKey);
        assertEq(claimed0, 0);
        assertApproxEqAbs(claimed1, expectedFee, 2);
        assertEq(token1.balanceOf(address(this)), balanceBefore + claimed1);

        (saved0, saved1) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, VE33_POOL_FEES_SAVED_BALANCE_ID);
        assertEq(saved0, 0);
        assertEq(saved1, expectedFee - claimed1);

        FeesPerLiquidity memory snapshotBefore = ve.vePoolFeeGrowthSnapshot(address(veToken), stakeId);
        vm.recordLogs();
        (uint128 zeroClaim0, uint128 zeroClaim1) = veToken.claimPoolFeesToSelf(veId, poolKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(zeroClaim0, 0);
        assertEq(zeroClaim1, 0);
        FeesPerLiquidity memory snapshotAfter = ve.vePoolFeeGrowthSnapshot(address(veToken), stakeId);
        assertEq(snapshotAfter.value0, snapshotBefore.value0);
        assertEq(snapshotAfter.value1, snapshotBefore.value1);

        bytes32 poolFeesClaimedTopic = keccak256("PoolFeesClaimed(bytes32,address,bytes32,uint128,uint128)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(ve) && logs[i].topics.length != 0) {
                assertNotEq(logs[i].topics[0], poolFeesClaimedTopic);
            }
        }
    }

    function test_veTokenClaimPoolFees_requiresAuthorizationAndSupportsRecipient() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint64 swapFee = uint64(1 << 62);
        uint256 veId = _fundAndVote(poolKey, swapFee);
        address operator = address(0x1234);
        address recipient = address(0xBEEF);
        address unauthorized = address(0xBAD);

        _routerSwap(poolKey, false, 100_000, address(this));

        vm.expectRevert(abi.encodeWithSelector(VeToken.NotAuthorizedForToken.selector, unauthorized, veId));
        vm.prank(unauthorized);
        veToken.claimPoolFees(veId, poolKey, recipient);

        vm.expectRevert(abi.encodeWithSelector(VeToken.NotAuthorizedForToken.selector, unauthorized, veId));
        vm.prank(unauthorized);
        veToken.claimPoolFeesToSelf(veId, poolKey);

        veToken.approve(operator, veId);

        (PoolKey memory otherPoolKey,) = _createConcentratedPool(256, bytes24("other-pool"));
        vm.expectRevert(IVe33.PoolNotVoted.selector);
        vm.prank(operator);
        veToken.claimPoolFees(veId, otherPoolKey, recipient);

        uint256 recipientBalanceBefore = token1.balanceOf(recipient);
        StakeId stakeId = _stakeId(veId);
        PoolId poolId = poolKey.toPoolId();
        (uint128 expected0, uint128 expected1) = ve.vePoolVote(address(veToken), stakeId)
            .fees(ve.poolFeeGrowth(poolId), ve.vePoolFeeGrowthSnapshot(address(veToken), stakeId));
        vm.expectEmit(address(ve));
        emit IVe33.PoolFeesClaimed(poolId, address(veToken), stakeId, expected0, expected1);
        vm.prank(operator);
        (uint128 claimed0, uint128 claimed1) = veToken.claimPoolFees(veId, poolKey, recipient);
        assertEq(claimed0, 0);
        assertGt(claimed1, 0);
        assertEq(claimed0, expected0);
        assertEq(claimed1, expected1);
        assertEq(token1.balanceOf(recipient), recipientBalanceBefore + claimed1);
        assertEq(token1.balanceOf(operator), 0);

        _routerSwap(poolKey, false, 100_000, address(this));

        uint256 operatorBalanceBefore = token1.balanceOf(operator);
        vm.prank(operator);
        (claimed0, claimed1) = veToken.claimPoolFeesToSelf(veId, poolKey);
        assertEq(claimed0, 0);
        assertGt(claimed1, 0);
        assertEq(token1.balanceOf(operator), operatorBalanceBefore + claimed1);
    }

    function test_veTokenMulticallClaimsFeesBeforeExtendingAndRevoting() public {
        (PoolKey memory oldPoolKey, PositionId oldPositionId) = _createConcentratedPool();
        (PoolKey memory newPoolKey, PositionId newPositionId) = _createConcentratedPool(256, bytes24("new-pool"));
        _updatePosition(oldPoolKey, oldPositionId, int128(uint128(1e18)));
        _updatePosition(newPoolKey, newPositionId, int128(uint128(1e18)));

        uint256 veId = _fundAndVote(oldPoolKey, uint64(1 << 62));
        _routerSwap(oldPoolKey, false, 100_000, address(this));

        uint256 balanceBefore = token1.balanceOf(address(this));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint64 newEnd = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(veToken.claimPoolFeesToSelf, (veId, oldPoolKey));
        calls[1] = abi.encodeCall(veToken.extendStake, (veId, newEnd));
        calls[2] = abi.encodeCall(veToken.vote, (veId, newPoolKey, uint64(1 << 61)));

        veToken.multicall(calls);

        (, uint64 end) = veToken.stakes(veId);
        assertEq(end, newEnd);
        assertGt(token1.balanceOf(address(this)), balanceBefore);
        assertEq(PoolId.unwrap(ve.votedPool(address(veToken), _stakeId(veId))), PoolId.unwrap(newPoolKey.toPoolId()));
        assertEq(ve.poolTotalWeight(oldPoolKey.toPoolId()), 0);
        assertGt(ve.poolTotalWeight(newPoolKey.toPoolId()), 0);
    }

    function test_claimPoolFeesAndExtendStakeClaimsBeforeClearingVote() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint256 veId = _fundAndVote(poolKey, uint64(1 << 62));
        _routerSwap(poolKey, false, 100_000, address(this));

        uint256 balanceBefore = token1.balanceOf(address(this));
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint64 newEnd = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        (uint128 claimed0, uint128 claimed1) = veToken.claimPoolFeesAndExtendStakeToSelf(veId, newEnd, poolKey);

        (, uint64 end) = veToken.stakes(veId);
        assertEq(claimed0, 0);
        assertGt(claimed1, 0);
        assertEq(token1.balanceOf(address(this)), balanceBefore + claimed1);
        assertEq(end, newEnd);
        assertEq(PoolId.unwrap(ve.votedPool(address(veToken), _stakeId(veId))), 0);
        assertEq(ve.poolTotalWeight(poolKey.toPoolId()), 0);
    }

    function test_claimPoolFeesAndMergeStakesClaimsSourceFeesBeforeBurning() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint64 fromEnd = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION() - 1 days);
        uint64 toEnd = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        uint256 fromVeId = veToken.createStake(2e18, fromEnd);
        uint256 toVeId = veToken.createStake(1e18, toEnd);
        _vote(fromVeId, poolKey, uint64(1 << 62));
        _routerSwap(poolKey, false, 100_000, address(this));

        uint256 balanceBefore = token1.balanceOf(address(this));
        (uint128 claimed0, uint128 claimed1, uint128 nextAmount) =
            veToken.claimPoolFeesAndMergeStakesToSelf(fromVeId, toVeId, poolKey);

        (uint128 toAmount, uint64 end) = veToken.stakes(toVeId);
        assertEq(claimed0, 0);
        assertGt(claimed1, 0);
        assertEq(token1.balanceOf(address(this)), balanceBefore + claimed1);
        assertEq(nextAmount, 3e18);
        assertEq(toAmount, 3e18);
        assertEq(end, toEnd);
        vm.expectRevert();
        veToken.ownerOf(fromVeId);
        assertEq(ve.poolTotalWeight(poolKey.toPoolId()), 0);
    }

    function test_forwardedExactInputPartialToken0SwapAccountsExecutedInputFee() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint64 swapFee = uint64(1 << 62);
        _fundAndVote(poolKey, swapFee);

        uint128 amount = 1e30;
        SwapParameters params = createSwapParameters({
            _sqrtRatioLimit: tickToSqrtRatio(-50), _amount: int128(amount), _isToken1: false, _skipAhead: 0
        });

        PoolBalanceUpdate balanceUpdate = _routerSwap(poolKey, params, address(this));
        (uint128 saved0, uint128 saved1) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, VE33_POOL_FEES_SAVED_BALANCE_ID);
        uint128 outputAfterFee = uint128(uint256(-int256(balanceUpdate.delta1())));

        assertEq(saved0, 0);
        assertEq(saved1, computeFee(outputAfterFee + saved1, swapFee));
        assertGt(saved1, 0);
        assertLe(uint128(uint256(int256(balanceUpdate.delta0()))), amount);
    }

    function test_forwardedExactInputPartialToken1SwapAccountsExecutedInputFee() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint64 swapFee = uint64(1 << 62);
        _fundAndVote(poolKey, swapFee);

        uint128 amount = 1e30;
        SwapParameters params = createSwapParameters({
            _sqrtRatioLimit: tickToSqrtRatio(50), _amount: int128(amount), _isToken1: true, _skipAhead: 0
        });

        PoolBalanceUpdate balanceUpdate = _routerSwap(poolKey, params, address(this));
        (uint128 saved0, uint128 saved1) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, VE33_POOL_FEES_SAVED_BALANCE_ID);
        uint128 outputAfterFee = uint128(uint256(-int256(balanceUpdate.delta0())));

        assertEq(saved0, computeFee(outputAfterFee + saved0, swapFee));
        assertGt(saved0, 0);
        assertEq(saved1, 0);
        assertLe(uint128(uint256(int256(balanceUpdate.delta1()))), amount);
    }

    function test_forwardedSwapCoversToken1AndExactOutFeeBranches() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _fundAndVote(poolKey, uint64(1 << 62));

        _routerSwap(poolKey, true, 100_000, address(this));
        (uint128 saved0AfterExactIn,) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, VE33_POOL_FEES_SAVED_BALANCE_ID);
        assertGt(saved0AfterExactIn, 0);

        SwapParameters token1Out = createSwapParameters({
            _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: -int128(1_000), _isToken1: true, _skipAhead: 0
        });
        _routerSwap(poolKey, token1Out, address(this));
        (uint128 saved0AfterExactOut,) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, VE33_POOL_FEES_SAVED_BALANCE_ID);
        assertGt(saved0AfterExactOut, saved0AfterExactIn);

        SwapParameters token0Out = createSwapParameters({
            _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: -int128(1_000), _isToken1: false, _skipAhead: 0
        });
        _routerSwap(poolKey, token0Out, address(this));
        (, uint128 saved1AfterExactOut) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, VE33_POOL_FEES_SAVED_BALANCE_ID);
        assertGt(saved1AfterExactOut, 0);
    }

    function test_zeroFeeVoteAndUnweightedFees() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint256 veId = _fundAndVote(poolKey, 0);
        _routerSwap(poolKey, false, 100_000, address(this));
        (uint128 saved0, uint128 saved1) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, VE33_POOL_FEES_SAVED_BALANCE_ID);
        assertEq(saved0, 0);
        assertEq(saved1, 0);
        (uint128 claimed0, uint128 claimed1) = veToken.claimPoolFeesToSelf(veId, poolKey);
        assertEq(claimed0, 0);
        assertEq(claimed1, 0);

        (PoolKey memory unvotedPool, PositionId unvotedPosition) = _createConcentratedPool(256, bytes24(uint192(2)));
        _updatePosition(unvotedPool, unvotedPosition, int128(uint128(1e18)));
        _routerSwap(unvotedPool, false, 100_000, address(this));
        (saved0, saved1) =
            core.savedBalances(address(ve), unvotedPool.token0, unvotedPool.token1, VE33_POOL_FEES_SAVED_BALANCE_ID);
        assertEq(saved0, 0);
        assertEq(saved1, 0);
    }

    function test_stakeIncreaseAdjustsVoteButMovingOrRemovingClearsVote() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        uint256 veId = _fundAndVote(poolKey, 0);
        (uint256 initialWeight,, uint64 swapFee) = _poolVoteTotals(poolKey.toPoolId());
        assertGt(initialWeight, 0);
        assertEq(swapFee, 0);

        veToken.increaseStakeAmount(veId, 1);
        (uint256 weight, uint256 feeWeightSum, uint64 swapFeeAfterIncrease) = _poolVoteTotals(poolKey.toPoolId());
        assertGt(weight, initialWeight);
        assertEq(weight, ve.votingPower(address(veToken), _stakeId(veId)));
        assertEq(feeWeightSum, 0);
        assertEq(swapFeeAfterIncrease, 0);
        assertEq(PoolId.unwrap(ve.votedPool(address(veToken), _stakeId(veId))), PoolId.unwrap(poolKey.toPoolId()));

        vm.warp(vm.getBlockTimestamp() + 1);
        veToken.extendStake(veId, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()));
        (uint256 weightAfterExtend, uint256 feeWeightSumAfterExtend, uint64 swapFeeAfterExtend) =
            _poolVoteTotals(poolKey.toPoolId());
        assertEq(weightAfterExtend, 0);
        assertEq(feeWeightSumAfterExtend, 0);
        assertEq(swapFeeAfterExtend, 0);

        _vote(veId, poolKey, 0);
        vm.warp(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        veToken.withdrawStake(veId);
        (uint256 weightAfterWithdraw, uint256 feeWeightSumAfterWithdraw, uint64 swapFeeAfterWithdraw) =
            _poolVoteTotals(poolKey.toPoolId());
        assertEq(weightAfterWithdraw, 0);
        assertEq(feeWeightSumAfterWithdraw, 0);
        assertEq(swapFeeAfterWithdraw, 0);
    }

    function test_moveStakeAdjustsSourceAndDestinationVotes() public {
        (PoolKey memory fromPool,) = _createConcentratedPool();
        (PoolKey memory toPool,) = _createConcentratedPool(256, bytes24("move-to-vote"));
        uint64 fromFee = 100;
        uint64 toFee = 300;
        StakeId fromStakeId = createStakeId(bytes24("move-from"), uint64(vm.getBlockTimestamp() + 2 weeks));
        StakeId toStakeId = createStakeId(bytes24("move-to"), uint64(vm.getBlockTimestamp() + 3 weeks));

        forwarder.stake(fromStakeId, 3e18);
        forwarder.stake(toStakeId, 2e18);
        vm.prank(address(forwarder));
        ve.vote(fromStakeId, fromPool, fromFee);
        vm.prank(address(forwarder));
        ve.vote(toStakeId, toPool, toFee);

        forwarder.moveStake(fromStakeId, toStakeId, 1e18);

        uint128 fromPower = ve.votingPower(address(forwarder), fromStakeId);
        uint128 toPower = ve.votingPower(address(forwarder), toStakeId);
        assertEq(ve.vePoolVote(address(forwarder), fromStakeId).weight(), fromPower);
        assertEq(ve.vePoolVote(address(forwarder), toStakeId).weight(), toPower);

        (uint256 fromWeight, uint256 fromFeeWeightSum, uint64 fromSwapFee) = _poolVoteTotals(fromPool.toPoolId());
        assertEq(fromWeight, fromPower);
        assertEq(fromFeeWeightSum, uint256(fromPower) * fromFee);
        assertEq(fromSwapFee, fromFee);

        (uint256 toWeight, uint256 toFeeWeightSum, uint64 toSwapFee) = _poolVoteTotals(toPool.toPoolId());
        assertEq(toWeight, toPower);
        assertEq(toFeeWeightSum, uint256(toPower) * toFee);
        assertEq(toSwapFee, toFee);
    }

    function test_splitStakePreservesSourceVoteAndAccruedFees() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint64 votedFee = uint64(1 << 62);
        uint64 end = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        uint256 veId = veToken.createStake(4e18, end);
        _vote(veId, poolKey, votedFee);

        PoolId poolId = poolKey.toPoolId();
        StakeId sourceStakeId = _stakeId(veId);
        uint256 initialWeight = ve.vePoolVote(address(veToken), sourceStakeId).weight();

        PoolBalanceUpdate balanceUpdate = _routerSwap(poolKey, false, 100_000, address(this));
        (, uint128 saved1) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, VE33_POOL_FEES_SAVED_BALANCE_ID);
        uint128 outputAfterFee = uint128(uint256(-int256(balanceUpdate.delta1())));
        uint128 expectedFee = computeFee(outputAfterFee + saved1, votedFee);

        uint256 splitVeId = veToken.splitStake(veId, 1e18);
        StakeId splitStakeId = _stakeId(splitVeId);
        uint256 sourcePower = ve.votingPower(address(veToken), sourceStakeId);

        assertGt(initialWeight, sourcePower);
        assertEq(PoolId.unwrap(ve.votedPool(address(veToken), sourceStakeId)), PoolId.unwrap(poolId));
        assertEq(PoolId.unwrap(ve.votedPool(address(veToken), splitStakeId)), 0);
        assertEq(ve.vePoolVote(address(veToken), sourceStakeId).weight(), sourcePower);
        assertEq(ve.vePoolVote(address(veToken), sourceStakeId).swapFee(), votedFee);
        assertEq(ve.vePoolVote(address(veToken), splitStakeId).weight(), 0);

        (uint256 weight, uint256 feeWeightSum, uint64 swapFee) = _poolVoteTotals(poolId);
        assertEq(weight, sourcePower);
        assertEq(feeWeightSum, sourcePower * votedFee);
        assertEq(swapFee, votedFee);
        assertEq(ve.totalVoteWeight(), sourcePower);

        (uint128 claimed0, uint128 claimed1) = veToken.claimPoolFeesToSelf(veId, poolKey);
        assertEq(claimed0, 0);
        assertApproxEqAbs(claimed1, expectedFee, 2);
    }

    function test_splitStakesVoteMultiplePoolsIndependently() public {
        (PoolKey memory pool0,) = _createConcentratedPool();
        (PoolKey memory pool1,) = _createConcentratedPool(256, bytes24(uint192(2)));

        uint64 end = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        uint256 veId0 = veToken.createStake(4e18, end);
        uint256 veId1 = veToken.splitStake(veId0, 3e18);

        uint64 fee0 = uint64(1 << 60);
        uint64 fee1 = uint64(1 << 62);
        _vote(veId0, pool0, fee0);
        _vote(veId1, pool1, fee1);

        PoolId poolId0 = pool0.toPoolId();
        uint256 veVoteWeight0 = ve.vePoolVote(address(veToken), _stakeId(veId0)).weight();
        (uint256 poolWeight0, uint256 feeWeightSum0, uint64 swapFee0) = _poolVoteTotals(poolId0);
        assertEq(poolWeight0, veVoteWeight0);
        assertEq(feeWeightSum0, veVoteWeight0 * fee0);
        assertEq(swapFee0, fee0);

        PoolId poolId1 = pool1.toPoolId();
        uint256 veVoteWeight1 = ve.vePoolVote(address(veToken), _stakeId(veId1)).weight();
        (uint256 poolWeight1, uint256 feeWeightSum1, uint64 swapFee1) = _poolVoteTotals(poolId1);
        assertEq(poolWeight1, veVoteWeight1);
        assertEq(feeWeightSum1, veVoteWeight1 * fee1);
        assertEq(swapFee1, fee1);

        assertEq(ve.totalVoteWeight(), veVoteWeight0 + veVoteWeight1);
    }

    function test_multipleVotersSetWeightedFeeAndClaimProRataFees() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        PoolId poolId = poolKey.toPoolId();

        uint64 fee0 = uint64(1 << 61);
        uint64 fee1 = uint64(1 << 62);
        uint256 veId0 = _fundAndVote(poolKey, fee0);
        uint256 veId1 = _createStake();
        _vote(veId1, poolKey, fee1);

        (uint256 totalWeight, uint256 feeWeightSum, uint64 swapFee) = _poolVoteTotals(poolId);
        uint256 weight0 = ve.vePoolVote(address(veToken), _stakeId(veId0)).weight();
        uint256 weight1 = ve.vePoolVote(address(veToken), _stakeId(veId1)).weight();
        assertEq(totalWeight, weight0 + weight1);
        assertEq(feeWeightSum, weight0 * fee0 + weight1 * fee1);
        assertEq(uint256(swapFee), feeWeightSum / totalWeight);

        PoolBalanceUpdate balanceUpdate = _routerSwap(poolKey, false, 100_000, address(this));
        (, uint128 saved1) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, VE33_POOL_FEES_SAVED_BALANCE_ID);
        uint128 outputAfterFee = uint128(uint256(-int256(balanceUpdate.delta1())));
        assertEq(saved1, computeFee(outputAfterFee + saved1, swapFee));

        (uint128 claimed0A, uint128 claimed1A) = veToken.claimPoolFeesToSelf(veId0, poolKey);
        (uint128 claimed0B, uint128 claimed1B) = veToken.claimPoolFeesToSelf(veId1, poolKey);
        assertEq(claimed0A, 0);
        assertEq(claimed0B, 0);
        assertApproxEqAbs(claimed1A, (uint256(saved1) * weight0) / totalWeight, 1);
        assertApproxEqAbs(claimed1B, (uint256(saved1) * weight1) / totalWeight, 1);
        assertApproxEqAbs(uint256(claimed1A) + claimed1B, saved1, 2);
    }

    function test_stakeActionsReturnUsefulAmounts() public {
        bytes24 salt = bytes24("salt");
        bytes24 toSalt = bytes24("to salt");
        uint64 endTime = uint64(vm.getBlockTimestamp() + 1 weeks);
        uint64 toEndTime = uint64(vm.getBlockTimestamp() + 2 weeks);
        StakeId stakeId = createStakeId(salt, endTime);
        StakeId toStakeId = createStakeId(toSalt, toEndTime);

        assertEq(forwarder.stake(stakeId, 0), 0);
        assertEq(forwarder.stake(stakeId, 100), 100);
        assertEq(forwarder.stake(stakeId, 50), 150);
        assertEq(forwarder.stake(stakeId, 0), 150);
        assertEq(ve.stakeAmount(address(forwarder), stakeId), 150);

        assertEq(forwarder.moveStake(stakeId, stakeId, 40), 150);
        assertEq(ve.stakeAmount(address(forwarder), stakeId), 150);
        vm.expectRevert(IVe33.StakeAmountExceedsBalance.selector);
        forwarder.moveStake(stakeId, stakeId, 151);

        assertEq(forwarder.moveStake(stakeId, toStakeId, 40), 40);
        assertEq(forwarder.moveStake(stakeId, toStakeId, 10), 50);
        assertEq(forwarder.moveStake(stakeId, toStakeId, 0), 50);
        assertEq(ve.stakeAmount(address(forwarder), stakeId), 100);
        assertEq(ve.stakeAmount(address(forwarder), toStakeId), 50);

        StakeId shorterStakeId = createStakeId(bytes24("shorter"), uint64(vm.getBlockTimestamp() + 3 days));
        assertEq(forwarder.moveStake(stakeId, shorterStakeId, 0), 0);
        vm.expectRevert(IVe33.MoveStakeToEarlierEndTime.selector);
        forwarder.moveStake(stakeId, shorterStakeId, 1);

        vm.warp(endTime);
        assertEq(forwarder.unstake(stakeId), 100);
        assertEq(ve.stakeAmount(address(forwarder), stakeId), 0);

        assertEq(forwarder.unstake(stakeId), 0);
    }

    function test_maybeAccumulateRewardsValidationAndOutOfRangeStableswap() public {
        PoolConfig wrongConfig = createConcentratedPoolConfig(0, 64, address(0));
        PoolKey memory wrongPool = PoolKey({token0: address(token0), token1: address(token1), config: wrongConfig});
        vm.expectRevert(IVe33.IncorrectPoolExtension.selector);
        ve.maybeAccumulateRewards(wrongPool);

        (PoolKey memory initializedPool,) = _createConcentratedPool(256, bytes24(uint192(2)));
        ve.maybeAccumulateRewards(initializedPool);
        assertEq(ve.rewardsGlobalPerLiquidity(initializedPool.toPoolId()), 0);

        (PoolKey memory stablePool, PositionId stablePosition) = _createStableswapPool(20, 0);
        _updatePosition(stablePool, stablePosition, int128(uint128(1e18)));
        _fundAndVote(stablePool, uint64(1 << 62));
        uint256 beforeGlobal = ve.rewardsGlobalPerLiquidity(stablePool.toPoolId());

        _scheduleEmissions(10_000, _defaultEmissionEnd());
        _routerSwap(stablePool, true, int128(1e30), address(this));
        PoolState stateAfter = core.poolState(stablePool.toPoolId());
        (, int32 upper) = stablePool.config.stableswapActiveLiquidityTickRange();
        assertGe(stateAfter.tick(), upper);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        ve.maybeAccumulateRewards(stablePool);
        assertGt(ve.rewardsGlobalPerLiquidity(stablePool.toPoolId()), beforeGlobal);
    }

    function test_scheduleEmissionsStartsAccruingWhenPoolReceivesVotes() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint64 end = _defaultEmissionEnd();
        uint128 scheduled = _scheduleEmissions(1e18, end);
        assertGt(scheduled, 0);

        uint256 voteTime = vm.getBlockTimestamp() + 1 days;
        vm.warp(voteTime);
        _fundAndVote(poolKey, uint64(1 << 62));
        uint256 fundedRewardsBeforeClaim = _rewardSavedBalance(VE33_STAKE_TOKEN_SAVED_BALANCE_ID);

        vm.warp(voteTime + 1 days);
        ve.maybeAccumulateRewards(poolKey);
        assertEq(_rewardSavedBalance(VE33_STAKE_TOKEN_SAVED_BALANCE_ID), fundedRewardsBeforeClaim);
        uint256 claimed = _claimRewards(poolKey, positionId, address(this));
        assertGt(claimed, 0);
        assertLt(claimed, fundedRewardsBeforeClaim);
        assertEq(_rewardSavedBalance(VE33_STAKE_TOKEN_SAVED_BALANCE_ID), fundedRewardsBeforeClaim - claimed);
    }

    function test_rewardsAccruedBeforePoolInitializationAreNotClaimableByLaterLiquidity() public {
        PoolConfig config = createConcentratedPoolConfig(0, 64, address(ve));
        PoolKey memory poolKey = PoolKey({token0: address(token0), token1: address(token1), config: config});
        PoolId poolId = poolKey.toPoolId();
        PositionId positionId = _mintPosition(-64, 64);
        _fundAndVote(poolKey, uint64(1 << 62));

        uint64 end = _defaultEmissionEnd();
        uint160 rewardRate = _emissionRateForAmount(1e18, end);
        _scheduleEmissions(1e18, end);
        vm.warp(vm.getBlockTimestamp() + 1 days);

        uint128 weight = ve.poolTotalWeight(poolId);
        uint256 rawEmissionsAccrued = (uint256(rewardRate) * 1 days) >> 32;
        uint256 expectedEmissionGrowthGlobalX128 = (rawEmissionsAccrued << 128) / weight;
        uint256 expectedPoolEmissionsAccrued = (expectedEmissionGrowthGlobalX128 * weight) >> 128;

        vm.expectEmit(address(ve));
        emit IVe33.PoolEmissionsAccrued(poolId, expectedPoolEmissionsAccrued);
        core.initializePool(poolKey, 0);
        assertEq(ve.rewardsGlobalPerLiquidity(poolId), 0);
        assertEq(ve.emissionGrowthGlobalX128(), expectedEmissionGrowthGlobalX128);
        assertEq(ve.poolEmissionGrowthGlobalX128Snapshot(poolId), expectedEmissionGrowthGlobalX128);

        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        assertEq(_claimRewards(poolKey, positionId, address(this)), 0);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        ve.maybeAccumulateRewards(poolKey);
        assertGt(_claimRewards(poolKey, positionId, address(this)), 0);
    }

    function test_rewardsAccruedBeforePoolLiquidityAreNotClaimableByLaterLiquidity() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        PoolId poolId = poolKey.toPoolId();
        _fundAndVote(poolKey, uint64(1 << 62));

        _scheduleEmissions(1e18, _defaultEmissionEnd());
        vm.warp(vm.getBlockTimestamp() + 1 days);
        ve.maybeAccumulateRewards(poolKey);

        assertEq(ve.rewardsGlobalPerLiquidity(poolId), 0);
        assertEq(ve.poolEmissionGrowthGlobalX128Snapshot(poolId), ve.emissionGrowthGlobalX128());

        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        assertEq(_claimRewards(poolKey, positionId, address(this)), 0);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        ve.maybeAccumulateRewards(poolKey);
        assertGt(_claimRewards(poolKey, positionId, address(this)), 0);
    }

    function test_scheduleEmissionsWithoutVotesDoesNotAccrueRewards() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint64 end = _defaultEmissionEnd();
        uint128 scheduled = _scheduleEmissions(1_000, end);
        assertGt(scheduled, 0);
        assertEq(_rewardSavedBalance(VE33_STAKE_TOKEN_SAVED_BALANCE_ID), scheduled);

        vm.warp(end);
        ve.maybeAccumulateRewards(poolKey);

        assertEq(ve.emissionRate(), 0);
        assertEq(_rewardSavedBalance(VE33_STAKE_TOKEN_SAVED_BALANCE_ID), scheduled);
        assertEq(_claimRewards(poolKey, positionId, address(this)), 0);
    }

    function test_poolWithLiquidityButNoVotesDoesNotAccrueRetroactiveRewardsAfterVote() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        PoolId poolId = poolKey.toPoolId();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        _scheduleEmissions(1e18, _defaultEmissionEnd());
        vm.warp(vm.getBlockTimestamp() + 1 days);
        ve.maybeAccumulateRewards(poolKey);

        assertEq(ve.poolTotalWeight(poolId), 0);
        assertEq(ve.rewardsGlobalPerLiquidity(poolId), 0);
        assertEq(_claimRewards(poolKey, positionId, address(this)), 0);

        _fundAndVote(poolKey, uint64(1 << 62));
        ve.maybeAccumulateRewards(poolKey);
        assertEq(_claimRewards(poolKey, positionId, address(this)), 0);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        ve.maybeAccumulateRewards(poolKey);
        assertGt(_claimRewards(poolKey, positionId, address(this)), 0);
    }

    function test_scheduleEmissionsDistributesProRataToTouchedVotedPools() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        (PoolKey memory otherPool, PositionId otherPositionId) = _createConcentratedPool(256, bytes24(uint192(2)));
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _updatePosition(otherPool, otherPositionId, int128(uint128(1e18)));

        uint64 end = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        uint256 veId0 = veToken.createStake(4e18, end);
        uint256 veId1 = veToken.splitStake(veId0, 3e18);
        _vote(veId0, poolKey, 0);
        _vote(veId1, otherPool, 0);

        _scheduleEmissions(1e18, _defaultEmissionEnd());
        vm.warp(vm.getBlockTimestamp() + 1 days);
        ve.maybeAccumulateRewards(poolKey);
        ve.maybeAccumulateRewards(otherPool);

        uint256 claimed0 = _claimRewards(poolKey, positionId, address(this));
        uint256 claimed1 = _claimRewards(otherPool, otherPositionId, address(this));
        assertGt(claimed0, 0);
        assertApproxEqAbs(claimed1, claimed0 * 3, 4);
    }

    function test_peripherySchedulesEmissionsAndClaimsRewards() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _fundAndVote(poolKey, uint64(1 << 62));

        uint64 end = _defaultEmissionEnd();
        uint128 amount = periphery.scheduleEmissions(0, end, _emissionRateForAmount(1e18, end));
        assertGt(amount, 0);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        ve.maybeAccumulateRewards(poolKey);

        uint256 balanceBefore = stakeToken.balanceOf(address(this));
        uint256 claimed = _claimRewards(poolKey, positionId, address(this));
        assertGt(claimed, 0);
        assertEq(stakeToken.balanceOf(address(this)), balanceBefore + claimed);
    }

    function test_vePositionsWithdrawAndClaimRewards() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        uint256 id = _positionNftId(positionId);
        int32 tickLower = positionId.tickLower();
        int32 tickUpper = positionId.tickUpper();

        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        uint128 liquidity = _positionLiquidity(poolKey, positionId);
        _fundAndVote(poolKey, uint64(1 << 62));
        _scheduleEmissions(10_000, _defaultEmissionEnd());

        vm.warp(vm.getBlockTimestamp() + 1 days);
        ve.maybeAccumulateRewards(poolKey);

        address recipient = address(0xBEEF);
        uint256 token0BalanceBefore = token0.balanceOf(recipient);
        uint256 token1BalanceBefore = token1.balanceOf(recipient);
        uint256 rewardBalanceBefore = stakeToken.balanceOf(recipient);

        (uint128 amount0, uint128 amount1, uint256 rewardAmount) =
            vePositions.withdrawAndClaimRewards(id, poolKey, tickLower, tickUpper, liquidity, recipient);

        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertGt(rewardAmount, 0);
        assertEq(token0.balanceOf(recipient), token0BalanceBefore + amount0);
        assertEq(token1.balanceOf(recipient), token1BalanceBefore + amount1);
        assertEq(stakeToken.balanceOf(recipient), rewardBalanceBefore + rewardAmount);
        assertEq(_positionLiquidity(poolKey, positionId), 0);
        assertEq(_claimRewards(poolKey, positionId, address(this)), 0);
    }

    function test_peripherySettlesEmissionPaymentsAfterRouterSwap() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _fundAndVote(poolKey, uint64(1 << 62));

        uint256 token1BalanceBefore = token1.balanceOf(address(1234));
        _routerSwap(
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: int128(100_000), _isToken1: false, _skipAhead: 0
            }),
            address(1234)
        );
        assertGt(token1.balanceOf(address(1234)), token1BalanceBefore);

        uint64 emissionEnd = _defaultEmissionEnd();
        uint256 stakeBalanceBefore = stakeToken.balanceOf(address(this));
        uint128 amount = periphery.scheduleEmissions(0, emissionEnd, _emissionRateForAmount(10_000, emissionEnd));
        assertGt(amount, 0);
        assertEq(stakeToken.balanceOf(address(this)), stakeBalanceBefore - amount);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        ve.maybeAccumulateRewards(poolKey);

        uint256 rewardBalanceBefore = stakeToken.balanceOf(address(1234));
        uint256 claimed = _claimRewards(poolKey, positionId, address(1234));
        assertGt(claimed, 0);
        assertEq(stakeToken.balanceOf(address(1234)), rewardBalanceBefore + claimed);
    }

    function test_vePositionsAuthorizesByNftAndKeepsIndependentPositions() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        int32 tickLower = positionId.tickLower();
        int32 tickUpper = positionId.tickUpper();
        uint256 id = _positionNftId(positionId);

        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        PoolId poolId = poolKey.toPoolId();
        uint128 ownerLiquidity = _positionLiquidity(poolKey, positionId);
        assertGt(ownerLiquidity, 0);

        address other = address(1234);
        vm.prank(other);
        vm.expectRevert();
        vePositions.withdraw(id, poolKey, tickLower, tickUpper, uint128(1e18), other);
        assertEq(core.poolPositions(poolId, address(vePositions), positionId).liquidity, ownerLiquidity);

        _fundAndVote(poolKey, uint64(1 << 62));
        _scheduleEmissions(10_000, _defaultEmissionEnd());
        vm.warp(vm.getBlockTimestamp() + 1 days);
        ve.maybeAccumulateRewards(poolKey);
        uint256 otherBalanceBefore = stakeToken.balanceOf(other);
        vm.prank(other);
        vm.expectRevert();
        vePositions.claimRewards(id, poolKey, tickLower, tickUpper, other);
        assertEq(stakeToken.balanceOf(other), otherBalanceBefore);
        assertGt(_claimRewards(poolKey, positionId, address(this)), 0);

        token0.transfer(other, 1e18);
        token1.transfer(other, 1e18);
        vm.startPrank(other);
        token0.approve(address(vePositions), type(uint256).max);
        token1.approve(address(vePositions), type(uint256).max);
        uint256 otherId = vePositions.mint(bytes32(uint256(1234)));
        PositionId otherPositionId = vePositions.positionId(otherId, tickLower, tickUpper);
        positionNftIds[PositionId.unwrap(otherPositionId)] = otherId;
        _updatePosition(poolKey, otherPositionId, int128(uint128(1e18)));
        vm.stopPrank();

        assertEq(core.poolPositions(poolId, address(vePositions), positionId).liquidity, ownerLiquidity);
        assertGt(core.poolPositions(poolId, address(vePositions), otherPositionId).liquidity, 0);
    }

    function test_vePositionsRejectsDepositsThatOverflowQueryableLiquidity() public {
        PoolKey memory poolKey = createFullRangePool(0, 0, address(ve));
        PositionId positionId = _mintPosition(MIN_TICK, MAX_TICK);
        uint256 id = _positionNftId(positionId);

        _updatePosition(poolKey, positionId, type(int128).max);

        (uint128 liquidity,,) = vePositions.getPositionLiquidity(id, poolKey, MIN_TICK, MAX_TICK);
        assertEq(liquidity, uint128(type(int128).max));

        vm.expectRevert(Ve33Positions.DepositOverflow.selector);
        vePositions.deposit(id, poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 1);
    }

    function test_scheduleEmissionsAccruesMultipleEventsAtSameTime() public {
        uint64 end = _defaultEmissionEnd();
        assertEq(forwarder.scheduleEmissions(0, end, 0), 0);
        assertEq(_rewardSavedBalance(VE33_STAKE_TOKEN_SAVED_BALANCE_ID), 0);
        assertEq(ve.emissionRate(), 0);
        assertEq(ve.emissionRateDeltaAtTime(end), 0);
        _assertEmissionTimeInitialized(end, false);

        vm.expectRevert(IVe33.InvalidTimestamps.selector);
        forwarder.scheduleEmissions(0, uint64(vm.getBlockTimestamp()), uint160(1 << 32));

        forwarder.scheduleEmissions(0, end, _emissionRateForAmount(1_000, end));
        forwarder.scheduleEmissions(0, end, _emissionRateForAmount(2_000, end));
        assertGt(ve.emissionRate(), 0);
        assertLt(ve.emissionRateDeltaAtTime(end), int256(0));
        _assertEmissionTimeInitialized(end, true);

        vm.warp(end);
        (PoolKey memory poolKey,) = _createConcentratedPool();
        ve.maybeAccumulateRewards(poolKey);
        assertEq(ve.emissionRateDeltaAtTime(end), 0);
        _assertEmissionTimeInitialized(end, false);
        assertEq(ve.emissionRate(), 0);
        assertEq(_rewardSavedBalance(VE33_STAKE_TOKEN_SAVED_BALANCE_ID), 3_000);
    }

    function test_scheduleEmissionsAccruesBeforeAddingNewRate() public {
        uint64 firstEnd = _defaultEmissionEnd();
        forwarder.scheduleEmissions(0, firstEnd, _emissionRateForAmount(1_000, firstEnd));
        vm.warp(firstEnd);

        uint64 secondEnd = _defaultEmissionEnd();
        forwarder.scheduleEmissions(0, secondEnd, _emissionRateForAmount(1_000, secondEnd));

        assertEq(ve.emissionRateDeltaAtTime(firstEnd), 0);
        _assertEmissionTimeInitialized(firstEnd, false);
        assertLt(ve.emissionRateDeltaAtTime(secondEnd), int256(0));
        _assertEmissionTimeInitialized(secondEnd, true);
        assertEq(ve.emissionGrowthGlobalX128(), 0);
        assertGt(ve.emissionRate(), 0);
    }

    function test_scheduleEmissionsAccruesAcrossUint32Wrap() public {
        vm.warp(uint256(type(uint32).max) - 1 days);

        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _fundAndVote(poolKey, uint64(1 << 62));

        uint256 realEndTime = nextValidTime(vm.getBlockTimestamp(), vm.getBlockTimestamp() + 2 days);
        uint64 end = uint64(realEndTime);
        uint128 scheduled = _scheduleEmissions(10_000, end);

        assertGt(scheduled, 0);
        assertGt(end, vm.getBlockTimestamp());
        assertGt(end, type(uint32).max);
        assertLt(uint32(end), uint32(vm.getBlockTimestamp()));
        assertLt(ve.emissionRateDeltaAtTime(end), int256(0));
        assertEq(ve.emissionRateDeltaAtTime(uint32(end)), 0);
        _assertEmissionTimeInitialized(end, true);

        vm.warp(realEndTime);
        ve.maybeAccumulateRewards(poolKey);

        assertEq(ve.emissionsLastAccrued(), uint32(end));
        assertEq(ve.emissionRate(), 0);
        assertEq(ve.emissionRateDeltaAtTime(end), 0);
        _assertEmissionTimeInitialized(end, false);
        assertGt(_claimRewards(poolKey, positionId, address(this)), 0);
    }

    function test_rewardSnapshotsAcrossConcentratedAndStableswapBoundaries() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        PoolId poolId = poolKey.toPoolId();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _fundAndVote(poolKey, uint64(1 << 62));
        _scheduleEmissions(10_000, _defaultEmissionEnd());
        vm.warp(vm.getBlockTimestamp() + 1 days);
        ve.maybeAccumulateRewards(poolKey);
        uint256 global = ve.rewardsGlobalPerLiquidity(poolId);
        assertGt(global, 0);

        SwapParameters upToUpper = createSwapParameters({
            _sqrtRatioLimit: tickToSqrtRatio(65), _amount: int128(1e30), _isToken1: true, _skipAhead: 0
        });
        _routerSwap(poolKey, upToUpper, address(this));
        PoolState stateAfterUpper = core.poolState(poolId);
        assertGe(stateAfterUpper.tick(), 64);
        assertEq(ve.tickRewardsOutsidePerLiquidity(poolId, 64), global);
        assertGt(_claimRewards(poolKey, positionId, address(this)), 0);

        SwapParameters downToLower = createSwapParameters({
            _sqrtRatioLimit: tickToSqrtRatio(-65), _amount: int128(1e30), _isToken1: false, _skipAhead: 0
        });
        _routerSwap(poolKey, downToLower, address(this));
        PoolState stateAfterLower = core.poolState(poolId);
        assertLt(stateAfterLower.tick(), -64);
        assertEq(ve.tickRewardsOutsidePerLiquidity(poolId, -64), global);

        _updatePosition(poolKey, positionId, -int128(_positionLiquidity(poolKey, positionId)));
        assertEq(ve.positionRewardsSnapshotPerLiquidity(poolId, address(vePositions), positionId), 0);
        assertEq(ve.tickRewardsOutsidePerLiquidity(poolId, -64), 0);
        assertEq(ve.tickRewardsOutsidePerLiquidity(poolId, 64), 0);

        (PoolKey memory stablePool, PositionId stablePosition) = _createStableswapPool(20, 0);
        PoolId stablePoolId = stablePool.toPoolId();
        (, int32 upper) = stablePool.config.stableswapActiveLiquidityTickRange();
        _updatePosition(stablePool, stablePosition, int128(uint128(1e18)));
        _fundAndVote(stablePool, uint64(1 << 62));
        _scheduleEmissions(10_000, _defaultEmissionEnd());
        vm.warp(vm.getBlockTimestamp() + 1 days);
        ve.maybeAccumulateRewards(stablePool);
        global = ve.rewardsGlobalPerLiquidity(stablePoolId);
        assertGt(global, 0);

        upToUpper = createSwapParameters({
            _sqrtRatioLimit: tickToSqrtRatio(upper + 1), _amount: int128(1e30), _isToken1: true, _skipAhead: 0
        });
        _routerSwap(stablePool, upToUpper, address(this));
        stateAfterUpper = core.poolState(stablePoolId);
        assertGe(stateAfterUpper.tick(), upper);
        assertEq(ve.tickRewardsOutsidePerLiquidity(stablePoolId, upper), 0);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        ve.maybeAccumulateRewards(stablePool);
        assertGt(ve.rewardsGlobalPerLiquidity(stablePoolId), global);
        assertGt(_claimRewards(stablePool, stablePosition, address(this)), 0);

        _updatePosition(stablePool, stablePosition, -int128(_positionLiquidity(stablePool, stablePosition)));
        assertEq(ve.tickRewardsOutsidePerLiquidity(stablePoolId, upper), 0);
    }

    function test_concentratedRewardsPauseWhilePositionIsOutOfRangeAcrossCrossings() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        PositionId upperPositionId = _mintPosition(64, 128);
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _updatePosition(poolKey, upperPositionId, int128(uint128(2e18)));
        _fundAndVote(poolKey, uint64(1 << 62));
        _scheduleEmissions(30_000, _defaultEmissionEnd());

        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertGt(_claimRewards(poolKey, positionId, address(this)), 0);

        SwapParameters upToUpper = createSwapParameters({
            _sqrtRatioLimit: tickToSqrtRatio(65), _amount: int128(1e30), _isToken1: true, _skipAhead: 0
        });
        _routerSwap(poolKey, upToUpper, address(this));
        assertGe(core.poolState(poolKey.toPoolId()).tick(), 64);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        ve.maybeAccumulateRewards(poolKey);
        vm.recordLogs();
        assertEq(_claimRewards(poolKey, positionId, address(this)), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 rewardsClaimedTopic = keccak256("RewardsClaimed(bytes32,address,bytes32,uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(ve) && logs[i].topics.length != 0) {
                assertNotEq(logs[i].topics[0], rewardsClaimedTopic);
            }
        }
        assertGt(_claimRewards(poolKey, upperPositionId, address(this)), 0);

        SwapParameters downIntoRange = createSwapParameters({
            _sqrtRatioLimit: tickToSqrtRatio(0), _amount: int128(1e30), _isToken1: false, _skipAhead: 0
        });
        _routerSwap(poolKey, downIntoRange, address(this));
        PoolState stateAfterReenteringRange = core.poolState(poolKey.toPoolId());
        assertGe(stateAfterReenteringRange.tick(), -64);
        assertLt(stateAfterReenteringRange.tick(), 64);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertGt(_claimRewards(poolKey, positionId, address(this)), 0);
    }

    function test_stableswapPoolStartsWithZeroDerivedFee() public {
        PoolConfig config = createStableswapPoolConfig(0, 20, 0, address(ve));
        PoolKey memory poolKey = createPool(address(token0), address(token1), 0, config);
        PoolId poolId = poolKey.toPoolId();

        (uint256 weight, uint256 feeWeightSum, uint64 swapFee) = _poolVoteTotals(poolId);

        assertEq(weight, 0);
        assertEq(feeWeightSum, 0);
        assertEq(swapFee, 0);
    }

    function test_moveStakeAllowsSameEndTime() public {
        uint64 sameEnd = uint64(vm.getBlockTimestamp() + 2 weeks);
        StakeId fromStakeId = createStakeId(bytes24("same-end-from"), sameEnd);
        StakeId toStakeId = createStakeId(bytes24("same-end-to"), sameEnd);

        forwarder.stake(fromStakeId, 2e18);
        forwarder.moveStake(fromStakeId, toStakeId, 1e18);

        assertEq(ve.stakeAmount(address(forwarder), fromStakeId), 1e18);
        assertEq(ve.stakeAmount(address(forwarder), toStakeId), 1e18);
    }

    function test_moveStakeRevertsForEarlierEndTime() public {
        uint64 later = uint64(vm.getBlockTimestamp() + 3 weeks);
        uint64 earlier = uint64(vm.getBlockTimestamp() + 2 weeks);
        StakeId fromStakeId = createStakeId(bytes24("from-later"), later);
        StakeId toStakeId = createStakeId(bytes24("to-earlier"), earlier);

        forwarder.stake(fromStakeId, 2e18);
        vm.expectRevert(IVe33.MoveStakeToEarlierEndTime.selector);
        forwarder.moveStake(fromStakeId, toStakeId, 1e18);
    }

    function test_voteClearsExistingVoteWhenPowerIsZero() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        uint64 end = uint64(vm.getBlockTimestamp() + 1);
        uint256 veId = veToken.createStake(1e18, end);
        _vote(veId, poolKey, uint64(1 << 62));

        PoolId poolId = poolKey.toPoolId();
        (uint256 weightBefore,,) = _poolVoteTotals(poolId);
        assertGt(weightBefore, 0);

        vm.warp(end);

        veToken.vote(veId, poolKey, uint64(1 << 62));

        (uint256 weightAfter,,) = _poolVoteTotals(poolId);
        assertEq(weightAfter, 0);
        assertEq(PoolId.unwrap(ve.votedPool(address(veToken), _stakeId(veId))), bytes32(0));
    }
}
