// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {Router} from "../../src/Router.sol";
import {Ve33Periphery} from "../../src/Ve33Periphery.sol";
import {Ve33Positions} from "../../src/Ve33Positions.sol";
import {VeToken} from "../../src/VeToken.sol";
import {Ve33, VE33_LP_REWARD_SAVED_BALANCE_ID, ve33CallPoints} from "../../src/extensions/Ve33.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {Ve33Lib} from "../../src/libraries/Ve33Lib.sol";
import {Ve33StorageLayout} from "../../src/libraries/Ve33StorageLayout.sol";
import {amountBeforeFee, computeFee} from "../../src/math/fee.sol";
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
import {StorageSlot} from "../../src/types/storageSlot.sol";

contract Ve33Forwarder is BaseLocker {
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_SCHEDULE_EMISSIONS = 0;
    uint256 private constant CALL_TYPE_CLAIM_POOL_FEES = 4;
    uint256 private constant CALL_TYPE_STAKE = 5;
    uint256 private constant CALL_TYPE_UNSTAKE = 6;
    uint256 private constant CALL_TYPE_MOVE_STAKE = 7;

    ICore private immutable CORE_REF;
    Ve33 private immutable VE33_REF;
    address private immutable STAKE_TOKEN;

    constructor(ICore core, Ve33 ve33, address stakeToken) BaseLocker(core) {
        CORE_REF = core;
        VE33_REF = ve33;
        STAKE_TOKEN = stakeToken;
    }

    function scheduleEmissions(uint64 startTime, uint64 endTime, uint224 rewardRate) external returns (uint224 amount) {
        amount = abi.decode(
            lock(abi.encode(CALL_TYPE_SCHEDULE_EMISSIONS, msg.sender, startTime, endTime, rewardRate)), (uint224)
        );
    }

    function claimPoolFees(StakeId stakeId, PoolKey memory poolKey)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = abi.decode(
            lock(abi.encode(CALL_TYPE_CLAIM_POOL_FEES, stakeId, poolKey)), (uint128, uint128)
        );
    }

    function stake(StakeId stakeId, uint128 amount) external returns (uint128 nextAmount) {
        nextAmount = abi.decode(lock(abi.encode(CALL_TYPE_STAKE, msg.sender, stakeId, amount)), (uint128));
    }

    function unstake(StakeId stakeId) external returns (uint128 unstaked) {
        unstaked = abi.decode(lock(abi.encode(CALL_TYPE_UNSTAKE, stakeId)), (uint128));
    }

    function moveStake(StakeId fromStakeId, StakeId toStakeId, uint128 amount) external returns (uint128 nextAmount) {
        nextAmount = abi.decode(lock(abi.encode(CALL_TYPE_MOVE_STAKE, fromStakeId, toStakeId, amount)), (uint128));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_SCHEDULE_EMISSIONS) {
            (, address payer, uint64 startTime, uint64 endTime, uint224 rewardRate) =
                abi.decode(data, (uint256, address, uint64, uint64, uint224));
            uint224 amount = Ve33Lib.scheduleEmissions(CORE_REF, VE33_REF, startTime, endTime, rewardRate);
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
        } else if (callType == CALL_TYPE_MOVE_STAKE) {
            (, StakeId fromStakeId, StakeId toStakeId, uint128 amount) =
                abi.decode(data, (uint256, StakeId, StakeId, uint128));
            result = abi.encode(Ve33Lib.moveStake(CORE_REF, VE33_REF, fromStakeId, toStakeId, amount));
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
        veToken = new VeToken(core, ve);
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

    function _poolVoteState(PoolId poolId)
        internal
        view
        returns (uint256 weight, uint256 feeWeightSum, uint64 swapFee)
    {
        Ve33.PoolVoteState memory state = ve.poolVoteState(poolId);
        weight = state.weight;
        feeWeightSum = state.feeWeightSum;
        assembly ("memory-safe") {
            swapFee := div(feeWeightSum, weight)
        }
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

    function _emissionRateForAmount(uint128 amount, uint64 endTime) internal view returns (uint224) {
        return uint224((uint256(amount) << 32) / (endTime - vm.getBlockTimestamp()));
    }

    function _scheduleEmissions(uint128 amount, uint64 endTime) internal returns (uint224 scheduledAmount) {
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

    function test_gas_poke() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        uint256 veId = _fundAndVote(poolKey, uint64(1 << 62));
        vm.warp(vm.getBlockTimestamp() + 1 weeks);

        coolAllContracts();
        ve.poke(address(veToken), _stakeId(veId));
        vm.snapshotGasLastCall("Ve33#poke");
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
        veToken.claimPoolFees(veId, poolKey);
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
        vm.expectRevert(Ve33.FeeMustBeZero.selector);
        createPool({tick: 0, fee: 1, tickSpacing: 64, extension: address(ve)});

        vm.expectRevert(Ve33.TickSpacingMustBePowerOfFour.selector);
        createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(ve)});

        vm.expectRevert(Ve33.TickSpacingMustBePowerOfFour.selector);
        createPool({tick: 0, fee: 0, tickSpacing: 2, extension: address(ve)});

        PoolConfig config = createConcentratedPoolConfig(0, 64, address(ve));
        PoolKey memory poolKey = PoolKey({token0: address(token0), token1: address(token1), config: config});
        PoolId poolId = poolKey.toPoolId();
        core.initializePool(poolKey, 0);

        Ve33.PoolVoteState memory state = ve.poolVoteState(poolId);
        assertEq(state.weight, 0);
        assertEq(state.feeWeightSum, 0);
    }

    function test_poolInitialization_preservesPreInitializationVotedFee() public {
        PoolConfig config = createConcentratedPoolConfig(0, 64, address(ve));
        PoolKey memory poolKey = PoolKey({token0: address(token0), token1: address(token1), config: config});
        PoolId poolId = poolKey.toPoolId();
        uint64 votedFee = uint64(1 << 62);

        uint256 veId = _createStake();
        _vote(veId, poolKey, votedFee);

        (uint256 weight, uint256 feeWeightSum, uint64 swapFee) = _poolVoteState(poolId);
        assertEq(weight, veToken.votingPower(veId));
        assertEq(feeWeightSum, weight * votedFee);
        assertEq(swapFee, votedFee);

        core.initializePool(poolKey, 0);

        (weight, feeWeightSum, swapFee) = _poolVoteState(poolId);
        assertEq(weight, veToken.votingPower(veId));
        assertEq(feeWeightSum, weight * votedFee);
        assertEq(swapFee, votedFee);
    }

    function test_directHooksAndInvalidCoreLockRevert() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        SwapParameters params = createSwapParameters({
            _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: int128(1), _isToken1: false, _skipAhead: 0
        });

        vm.expectRevert(Ve33.SwapMustHappenThroughForward.selector);
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
        vm.expectRevert(Ve33.InvalidPoolKey.selector);
        veToken.vote(veId, wrongExtensionPool, 1);

        PoolConfig wrongFeeConfig = createConcentratedPoolConfig(1, 64, address(ve));
        PoolKey memory wrongFeePool =
            PoolKey({token0: address(token0), token1: address(token1), config: wrongFeeConfig});
        vm.expectRevert(Ve33.FeeMustBeZero.selector);
        veToken.vote(veId, wrongFeePool, 1);

        PoolConfig invalidTickSpacingConfig = createConcentratedPoolConfig(0, 100, address(ve));
        PoolKey memory invalidTickSpacingPool =
            PoolKey({token0: address(token0), token1: address(token1), config: invalidTickSpacingConfig});
        vm.expectRevert(Ve33.TickSpacingMustBePowerOfFour.selector);
        veToken.vote(veId, invalidTickSpacingPool, 1);

        vm.warp(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        uint256 expiredVeId = veToken.createStake(1, uint64(vm.getBlockTimestamp() + 1));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(Ve33.InvalidVote.selector);
        veToken.vote(expiredVeId, poolKey, 1);
    }

    function test_forwardedSwapAccountsVoterFee() public {
        vm.warp(1);

        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint64 swapFee = uint64(1 << 62);
        uint256 veId = _fundAndVote(poolKey, swapFee);

        _routerSwap(poolKey, false, 100_000, address(this));

        uint128 expectedFee = computeFee(100_000, swapFee);
        (uint128 saved0, uint128 saved1) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        assertEq(saved0, expectedFee);
        assertEq(saved1, 0);

        uint256 balanceBefore = token0.balanceOf(address(this));
        (uint128 emptyClaim0, uint128 emptyClaim1) = forwarder.claimPoolFees(_stakeId(veId), poolKey);
        assertEq(emptyClaim0, 0);
        assertEq(emptyClaim1, 0);
        (uint128 claimed0, uint128 claimed1) = veToken.claimPoolFees(veId, poolKey);
        assertApproxEqAbs(claimed0, expectedFee, 2);
        assertEq(claimed1, 0);
        assertEq(token0.balanceOf(address(this)), balanceBefore + claimed0);

        (saved0, saved1) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        assertEq(saved0, expectedFee - claimed0);
        assertEq(saved1, 0);
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
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        uint128 coreInput = uint128(uint256(int256(balanceUpdate.delta0()))) - saved0;

        assertEq(saved0, amountBeforeFee(coreInput, swapFee) - coreInput);
        assertLt(saved0, computeFee(amount, swapFee));
        assertEq(saved1, 0);
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
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        uint128 coreInput = uint128(uint256(int256(balanceUpdate.delta1()))) - saved1;

        assertEq(saved0, 0);
        assertEq(saved1, amountBeforeFee(coreInput, swapFee) - coreInput);
        assertLt(saved1, computeFee(amount, swapFee));
    }

    function test_forwardedSwapCoversToken1AndExactOutFeeBranches() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _fundAndVote(poolKey, uint64(1 << 62));

        _routerSwap(poolKey, true, 100_000, address(this));
        (, uint128 saved1AfterExactIn) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        assertGt(saved1AfterExactIn, 0);

        SwapParameters token1Out = createSwapParameters({
            _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: -int128(1_000), _isToken1: true, _skipAhead: 0
        });
        _routerSwap(poolKey, token1Out, address(this));
        (uint128 saved0AfterExactOut,) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        assertGt(saved0AfterExactOut, 0);

        SwapParameters token0Out = createSwapParameters({
            _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: -int128(1_000), _isToken1: false, _skipAhead: 0
        });
        _routerSwap(poolKey, token0Out, address(this));
        (, uint128 saved1AfterExactOut) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        assertGt(saved1AfterExactOut, saved1AfterExactIn);
    }

    function test_zeroFeeVoteAndUnweightedFees() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint256 veId = _fundAndVote(poolKey, 0);
        _routerSwap(poolKey, false, 100_000, address(this));
        (uint128 saved0, uint128 saved1) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        assertEq(saved0, 0);
        assertEq(saved1, 0);
        (uint128 claimed0, uint128 claimed1) = veToken.claimPoolFees(veId, poolKey);
        assertEq(claimed0, 0);
        assertEq(claimed1, 0);

        (PoolKey memory unvotedPool, PositionId unvotedPosition) = _createConcentratedPool(256, bytes24(uint192(2)));
        _updatePosition(unvotedPool, unvotedPosition, int128(uint128(1e18)));
        _routerSwap(unvotedPool, false, 100_000, address(this));
        (saved0, saved1) = core.savedBalances(
            address(ve), unvotedPool.token0, unvotedPool.token1, PoolId.unwrap(unvotedPool.toPoolId())
        );
        assertEq(saved0, 0);
        assertEq(saved1, 0);
    }

    function test_clearVotesOnStakeChangesZerosDerivedFee() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        uint256 veId = _fundAndVote(poolKey, 0);
        (,, uint64 swapFee) = _poolVoteState(poolKey.toPoolId());
        assertEq(swapFee, 0);

        veToken.increaseStakeAmount(veId, 1);
        (uint256 weight, uint256 feeWeightSum, uint64 swapFeeAfterIncrease) = _poolVoteState(poolKey.toPoolId());
        assertEq(weight, 0);
        assertEq(feeWeightSum, 0);
        assertEq(swapFeeAfterIncrease, 0);

        _vote(veId, poolKey, 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        veToken.extendStake(veId, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()));
        (uint256 weightAfterExtend, uint256 feeWeightSumAfterExtend, uint64 swapFeeAfterExtend) =
            _poolVoteState(poolKey.toPoolId());
        assertEq(weightAfterExtend, 0);
        assertEq(feeWeightSumAfterExtend, 0);
        assertEq(swapFeeAfterExtend, 0);

        _vote(veId, poolKey, 0);
        vm.warp(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        veToken.withdrawStake(veId);
        (uint256 weightAfterWithdraw, uint256 feeWeightSumAfterWithdraw, uint64 swapFeeAfterWithdraw) =
            _poolVoteState(poolKey.toPoolId());
        assertEq(weightAfterWithdraw, 0);
        assertEq(feeWeightSumAfterWithdraw, 0);
        assertEq(swapFeeAfterWithdraw, 0);
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
        uint256 initialWeight = ve.vePoolPosition(address(veToken), sourceStakeId).weight;

        _routerSwap(poolKey, false, 100_000, address(this));
        uint128 expectedFee = computeFee(100_000, votedFee);

        uint256 splitVeId = veToken.splitStake(veId, 1e18);
        StakeId splitStakeId = _stakeId(splitVeId);
        uint256 sourcePower = ve.votingPower(address(veToken), sourceStakeId);

        assertGt(initialWeight, sourcePower);
        assertEq(PoolId.unwrap(ve.votedPool(address(veToken), sourceStakeId)), PoolId.unwrap(poolId));
        assertEq(PoolId.unwrap(ve.votedPool(address(veToken), splitStakeId)), 0);
        assertEq(ve.vePoolPosition(address(veToken), sourceStakeId).weight, sourcePower);
        assertEq(ve.vePoolPosition(address(veToken), sourceStakeId).swapFee, votedFee);
        assertEq(ve.vePoolPosition(address(veToken), splitStakeId).weight, 0);

        (uint256 weight, uint256 feeWeightSum, uint64 swapFee) = _poolVoteState(poolId);
        assertEq(weight, sourcePower);
        assertEq(feeWeightSum, sourcePower * votedFee);
        assertEq(swapFee, votedFee);
        assertEq(ve.totalVoteWeight(), sourcePower);

        (uint128 claimed0, uint128 claimed1) = veToken.claimPoolFees(veId, poolKey);
        assertApproxEqAbs(claimed0, expectedFee, 2);
        assertEq(claimed1, 0);
    }

    function test_pokeRefreshesDecayedVotesAndPreservesAccruedFees() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));
        uint64 votedFee = uint64(1 << 62);
        uint256 veId = _fundAndVote(poolKey, votedFee);
        PoolId poolId = poolKey.toPoolId();

        (uint256 initialWeight,,) = _poolVoteState(poolId);
        _routerSwap(poolKey, false, 100_000, address(this));
        uint128 expectedFee = computeFee(100_000, votedFee);

        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        StakeId stakeId = _stakeId(veId);
        uint256 currentPower = ve.votingPower(address(veToken), stakeId);
        vm.prank(address(1234));
        (uint256 previousWeight, uint256 nextWeight) = ve.poke(address(veToken), stakeId);

        assertEq(previousWeight, initialWeight);
        assertEq(nextWeight, currentPower);
        (uint256 weight, uint256 feeWeightSum, uint64 swapFee) = _poolVoteState(poolId);
        assertEq(weight, currentPower);
        assertEq(feeWeightSum, currentPower * votedFee);
        assertEq(swapFee, votedFee);
        assertEq(ve.totalVoteWeight(), currentPower);
        assertEq(ve.poolVoteState(poolId).emissionGrowthGlobalX128Snapshot, ve.emissionGrowthGlobalX128());

        (uint128 claimed0, uint128 claimed1) = veToken.claimPoolFees(veId, poolKey);
        assertApproxEqAbs(claimed0, expectedFee, 2);
        assertEq(claimed1, 0);
    }

    function test_pokeNoopsWithoutVotesOrWithoutDecay() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        uint256 veId = _createStake();
        StakeId stakeId = _stakeId(veId);

        (uint256 previousWeight, uint256 nextWeight) = ve.poke(address(veToken), stakeId);
        assertEq(previousWeight, 0);
        assertEq(nextWeight, 0);

        _vote(veId, poolKey, uint64(1 << 62));
        (uint256 weightBefore,,) = _poolVoteState(poolKey.toPoolId());
        (previousWeight, nextWeight) = ve.poke(address(veToken), stakeId);
        assertEq(previousWeight, weightBefore);
        assertEq(nextWeight, weightBefore);
        (uint256 weightAfter,,) = _poolVoteState(poolKey.toPoolId());
        assertEq(weightAfter, weightBefore);
    }

    function test_splitStakesVoteMultiplePoolsAndPokeIndependently() public {
        (PoolKey memory pool0,) = _createConcentratedPool();
        (PoolKey memory pool1,) = _createConcentratedPool(256, bytes24(uint192(2)));

        uint64 end = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        uint256 veId0 = veToken.createStake(4e18, end);
        uint256 veId1 = veToken.splitStake(veId0, 3e18);

        uint64 fee0 = uint64(1 << 60);
        uint64 fee1 = uint64(1 << 62);
        _vote(veId0, pool0, fee0);
        _vote(veId1, pool1, fee1);

        StakeId stakeId0 = _stakeId(veId0);
        StakeId stakeId1 = _stakeId(veId1);
        vm.warp(vm.getBlockTimestamp() + 3 weeks);
        (uint256 previousWeight0, uint256 nextWeight0) = ve.poke(address(veToken), stakeId0);
        (uint256 previousWeight1, uint256 nextWeight1) = ve.poke(address(veToken), stakeId1);

        assertGt(previousWeight0, nextWeight0);
        assertGt(previousWeight1, nextWeight1);

        PoolId poolId0 = pool0.toPoolId();
        uint256 vePoolWeight0 = ve.vePoolPosition(address(veToken), stakeId0).weight;
        (uint256 poolWeight0, uint256 feeWeightSum0, uint64 swapFee0) = _poolVoteState(poolId0);
        assertEq(poolWeight0, vePoolWeight0);
        assertEq(feeWeightSum0, vePoolWeight0 * fee0);
        assertEq(swapFee0, fee0);

        PoolId poolId1 = pool1.toPoolId();
        uint256 vePoolWeight1 = ve.vePoolPosition(address(veToken), stakeId1).weight;
        (uint256 poolWeight1, uint256 feeWeightSum1, uint64 swapFee1) = _poolVoteState(poolId1);
        assertEq(poolWeight1, vePoolWeight1);
        assertEq(feeWeightSum1, vePoolWeight1 * fee1);
        assertEq(swapFee1, fee1);

        assertEq(ve.totalVoteWeight(), nextWeight0 + nextWeight1);
    }

    function test_pokeClearsExpiredVotes() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        uint64 votedFee = uint64(1 << 62);
        uint256 veId = _fundAndVote(poolKey, votedFee);
        PoolId poolId = poolKey.toPoolId();
        (uint256 initialWeight,,) = _poolVoteState(poolId);

        vm.warp(_stakeId(veId).endTime());
        (uint256 previousWeight, uint256 nextWeight) = ve.poke(address(veToken), _stakeId(veId));

        assertEq(previousWeight, initialWeight);
        assertEq(nextWeight, 0);
        (uint256 weight, uint256 feeWeightSum, uint64 swapFee) = _poolVoteState(poolId);
        assertEq(weight, 0);
        assertEq(feeWeightSum, 0);
        assertEq(swapFee, 0);
        assertEq(ve.totalVoteWeight(), 0);
        assertEq(ve.vePoolPosition(address(veToken), _stakeId(veId)).weight, 0);
        assertEq(PoolId.unwrap(ve.votedPool(address(veToken), _stakeId(veId))), 0);
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

        (uint256 totalWeight, uint256 feeWeightSum, uint64 swapFee) = _poolVoteState(poolId);
        uint256 weight0 = ve.vePoolPosition(address(veToken), _stakeId(veId0)).weight;
        uint256 weight1 = ve.vePoolPosition(address(veToken), _stakeId(veId1)).weight;
        assertEq(totalWeight, weight0 + weight1);
        assertEq(feeWeightSum, weight0 * fee0 + weight1 * fee1);
        assertEq(uint256(swapFee), feeWeightSum / totalWeight);

        _routerSwap(poolKey, false, 100_000, address(this));
        (uint128 saved0,) = core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolId));
        assertEq(saved0, computeFee(100_000, swapFee));

        (uint128 claimed0A, uint128 claimed1A) = veToken.claimPoolFees(veId0, poolKey);
        (uint128 claimed0B, uint128 claimed1B) = veToken.claimPoolFees(veId1, poolKey);
        assertEq(claimed1A, 0);
        assertEq(claimed1B, 0);
        assertApproxEqAbs(claimed0A, (uint256(saved0) * weight0) / totalWeight, 1);
        assertApproxEqAbs(claimed0B, (uint256(saved0) * weight1) / totalWeight, 1);
        assertApproxEqAbs(uint256(claimed0A) + claimed0B, saved0, 2);
    }

    function test_stakeActionsReturnUsefulAmounts() public {
        bytes24 salt = bytes24("salt");
        bytes24 toSalt = bytes24("to salt");
        uint64 endTime = uint64(vm.getBlockTimestamp() + 1 weeks);
        uint64 toEndTime = uint64(vm.getBlockTimestamp() + 2 weeks);
        StakeId stakeId = createStakeId(salt, endTime);
        StakeId toStakeId = createStakeId(toSalt, toEndTime);

        assertEq(forwarder.stake(stakeId, 100), 100);
        assertEq(forwarder.stake(stakeId, 50), 150);
        assertEq(ve.stakeAmount(address(forwarder), stakeId), 150);

        assertEq(forwarder.moveStake(stakeId, toStakeId, 40), 40);
        assertEq(forwarder.moveStake(stakeId, toStakeId, 10), 50);
        assertEq(ve.stakeAmount(address(forwarder), stakeId), 100);
        assertEq(ve.stakeAmount(address(forwarder), toStakeId), 50);

        vm.warp(endTime);
        assertEq(forwarder.unstake(stakeId), 100);
        assertEq(ve.stakeAmount(address(forwarder), stakeId), 0);

        assertEq(forwarder.unstake(stakeId), 0);
    }

    function test_maybeAccumulateRewardsValidationAndOutOfRangeStableswap() public {
        PoolConfig wrongConfig = createConcentratedPoolConfig(0, 64, address(0));
        PoolKey memory wrongPool = PoolKey({token0: address(token0), token1: address(token1), config: wrongConfig});
        vm.expectRevert(Ve33.InvalidPoolKey.selector);
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
        uint224 scheduled = _scheduleEmissions(1e18, end);
        assertGt(scheduled, 0);

        uint256 voteTime = vm.getBlockTimestamp() + 1 days;
        vm.warp(voteTime);
        _fundAndVote(poolKey, uint64(1 << 62));
        uint256 fundedRewardsBeforeClaim = _rewardSavedBalance(VE33_LP_REWARD_SAVED_BALANCE_ID);

        vm.warp(voteTime + 1 days);
        ve.maybeAccumulateRewards(poolKey);
        assertEq(_rewardSavedBalance(VE33_LP_REWARD_SAVED_BALANCE_ID), fundedRewardsBeforeClaim);
        uint256 claimed = _claimRewards(poolKey, positionId, address(this));
        assertGt(claimed, 0);
        assertLt(claimed, fundedRewardsBeforeClaim);
        assertEq(_rewardSavedBalance(VE33_LP_REWARD_SAVED_BALANCE_ID), fundedRewardsBeforeClaim - claimed);
    }

    function test_scheduleEmissionsWithoutVotesDoesNotAccrueRewards() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint64 end = _defaultEmissionEnd();
        uint224 scheduled = _scheduleEmissions(1_000, end);
        assertGt(scheduled, 0);
        assertEq(_rewardSavedBalance(VE33_LP_REWARD_SAVED_BALANCE_ID), scheduled);

        vm.warp(end);
        ve.maybeAccumulateRewards(poolKey);

        assertEq(ve.emissionRate(), 0);
        assertEq(_rewardSavedBalance(VE33_LP_REWARD_SAVED_BALANCE_ID), scheduled);
        assertEq(_claimRewards(poolKey, positionId, address(this)), 0);
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
        uint224 amount = periphery.scheduleEmissions(0, end, _emissionRateForAmount(1e18, end));
        assertGt(amount, 0);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        ve.maybeAccumulateRewards(poolKey);

        uint256 balanceBefore = stakeToken.balanceOf(address(this));
        uint256 claimed = _claimRewards(poolKey, positionId, address(this));
        assertGt(claimed, 0);
        assertEq(stakeToken.balanceOf(address(this)), balanceBefore + claimed);
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
        uint224 amount = periphery.scheduleEmissions(0, emissionEnd, _emissionRateForAmount(10_000, emissionEnd));
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
        vm.expectRevert(Ve33.EmissionAmountTooSmall.selector);
        forwarder.scheduleEmissions(0, end, 0);

        vm.expectRevert(Ve33.InvalidTimestamps.selector);
        forwarder.scheduleEmissions(0, uint64(vm.getBlockTimestamp()), uint224(1 << 32));

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
        assertEq(_rewardSavedBalance(VE33_LP_REWARD_SAVED_BALANCE_ID), 3_000);
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

    function test_claimRewardsOverflowReverts() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        PoolId poolId = poolKey.toPoolId();
        _updatePosition(poolKey, positionId, int128(uint128(1e18)));

        vm.store(
            address(ve),
            StorageSlot.unwrap(Ve33StorageLayout.rewardsGlobalPerLiquiditySlot(poolId)),
            bytes32(type(uint256).max)
        );

        vm.expectRevert(Ve33.RewardAmountOverflow.selector);
        _claimRewards(poolKey, positionId, address(this));
    }

    function test_stableswapPoolStartsWithZeroDerivedFee() public {
        PoolConfig config = createStableswapPoolConfig(0, 20, 0, address(ve));
        PoolKey memory poolKey = createPool(address(token0), address(token1), 0, config);
        PoolId poolId = poolKey.toPoolId();

        (uint256 weight, uint256 feeWeightSum, uint64 swapFee) = _poolVoteState(poolId);

        assertEq(weight, 0);
        assertEq(feeWeightSum, 0);
        assertEq(swapFee, 0);
    }
}
