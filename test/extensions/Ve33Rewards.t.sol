// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {VeToken} from "../../src/VeToken.sol";
import {
    VE33_ADD_REWARDS,
    VE33_CLAIM_REWARDS,
    VE33_DONATE_REWARDS,
    VE33_SWAP,
    Ve33Rewards,
    ve33RewardsCallPoints
} from "../../src/extensions/Ve33Rewards.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {computeFee} from "../../src/math/fee.sol";
import {MAX_NUM_VALID_TIMES, nextValidTime} from "../../src/math/time.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PoolConfig, createConcentratedPoolConfig, createStableswapPoolConfig} from "../../src/types/poolConfig.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PositionId, createPositionId} from "../../src/types/positionId.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {Locker} from "../../src/types/locker.sol";

contract Ve33RewardsForwarder is BaseLocker {
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_UPDATE_POSITION = 0;
    uint256 private constant CALL_TYPE_SWAP = 1;
    uint256 private constant CALL_TYPE_CLAIM_REWARDS = 2;
    uint256 private constant CALL_TYPE_DONATE_REWARDS = 3;
    uint256 private constant CALL_TYPE_ADD_REWARDS = 4;
    uint256 private constant CALL_TYPE_RAW_FORWARD = 5;

    ICore private immutable CORE_REF;
    address private immutable STAKE_TOKEN;

    constructor(ICore core, address stakeToken) BaseLocker(core) {
        CORE_REF = core;
        STAKE_TOKEN = stakeToken;
    }

    function updatePosition(PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta)
        external
        returns (PoolBalanceUpdate balanceUpdate)
    {
        balanceUpdate = abi.decode(
            lock(abi.encode(CALL_TYPE_UPDATE_POSITION, msg.sender, poolKey, positionId, liquidityDelta)),
            (PoolBalanceUpdate)
        );
    }

    function swap(PoolKey memory poolKey, bool isToken1, int128 amount, address recipient)
        external
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        SwapParameters params = createSwapParameters({
                _isToken1: isToken1, _amount: amount, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
        return swap(poolKey, params, recipient);
    }

    function swap(PoolKey memory poolKey, SwapParameters params, address recipient)
        public
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        (balanceUpdate, stateAfter) = abi.decode(
            lock(abi.encode(CALL_TYPE_SWAP, msg.sender, poolKey, params, recipient)), (PoolBalanceUpdate, PoolState)
        );
    }

    function claimRewards(PoolKey memory poolKey, PositionId positionId, address recipient)
        external
        returns (uint256 amount)
    {
        amount = abi.decode(lock(abi.encode(CALL_TYPE_CLAIM_REWARDS, poolKey, positionId, recipient)), (uint256));
    }

    function donateRewards(PoolKey memory poolKey, uint128 amount) external returns (uint128 donated) {
        donated = abi.decode(lock(abi.encode(CALL_TYPE_DONATE_REWARDS, msg.sender, poolKey, amount)), (uint128));
    }

    function addRewards(PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate)
        external
        returns (uint224 amount)
    {
        amount = abi.decode(
            lock(abi.encode(CALL_TYPE_ADD_REWARDS, msg.sender, poolKey, startTime, endTime, rewardRate)), (uint224)
        );
    }

    function rawForward(address extension, bytes memory forwardData) external returns (bytes memory result) {
        result = lock(abi.encode(CALL_TYPE_RAW_FORWARD, extension, forwardData));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_UPDATE_POSITION) {
            (, address payer, PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta) =
                abi.decode(data, (uint256, address, PoolKey, PositionId, int128));
            PoolBalanceUpdate balanceUpdate = CORE_REF.updatePosition(poolKey, positionId, liquidityDelta);
            _settle(poolKey, payer, payer, balanceUpdate);
            result = abi.encode(balanceUpdate);
        } else if (callType == CALL_TYPE_SWAP) {
            (, address payer, PoolKey memory poolKey, bytes32 params, address recipient) =
                abi.decode(data, (uint256, address, PoolKey, bytes32, address));
            (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) = abi.decode(
                CORE_REF.forward(poolKey.config.extension(), abi.encode(VE33_SWAP, poolKey, params)),
                (PoolBalanceUpdate, PoolState)
            );
            _settle(poolKey, payer, recipient, balanceUpdate);
            result = abi.encode(balanceUpdate, stateAfter);
        } else if (callType == CALL_TYPE_CLAIM_REWARDS) {
            (, PoolKey memory poolKey, PositionId positionId, address recipient) =
                abi.decode(data, (uint256, PoolKey, PositionId, address));
            result = CORE_REF.forward(
                poolKey.config.extension(), abi.encode(VE33_CLAIM_REWARDS, poolKey, positionId, recipient)
            );
        } else if (callType == CALL_TYPE_DONATE_REWARDS) {
            (, address payer, PoolKey memory poolKey, uint128 amount) =
                abi.decode(data, (uint256, address, PoolKey, uint128));
            result = CORE_REF.forward(poolKey.config.extension(), abi.encode(VE33_DONATE_REWARDS, poolKey, amount));
            uint128 donated = abi.decode(result, (uint128));
            if (donated != 0) ACCOUNTANT.payFrom(payer, STAKE_TOKEN, donated);
        } else if (callType == CALL_TYPE_ADD_REWARDS) {
            (, address payer, PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate) =
                abi.decode(data, (uint256, address, PoolKey, uint64, uint64, uint224));
            result = CORE_REF.forward(
                poolKey.config.extension(), abi.encode(VE33_ADD_REWARDS, poolKey, startTime, endTime, rewardRate)
            );
            uint224 amount = abi.decode(result, (uint224));
            if (amount != 0) ACCOUNTANT.payFrom(payer, STAKE_TOKEN, amount);
        } else if (callType == CALL_TYPE_RAW_FORWARD) {
            (, address extension, bytes memory forwardData) = abi.decode(data, (uint256, address, bytes));
            result = CORE_REF.forward(extension, forwardData);
        } else {
            revert();
        }
    }

    function _settle(PoolKey memory poolKey, address payer, address recipient, PoolBalanceUpdate balanceUpdate)
        private
    {
        int128 delta0 = balanceUpdate.delta0();
        int128 delta1 = balanceUpdate.delta1();

        if (delta0 > 0) {
            ACCOUNTANT.payFrom(payer, poolKey.token0, uint128(delta0));
        } else if (delta0 < 0) {
            ACCOUNTANT.withdraw(poolKey.token0, recipient, uint128(-delta0));
        }

        if (delta1 > 0) {
            ACCOUNTANT.payFrom(payer, poolKey.token1, uint128(delta1));
        } else if (delta1 < 0) {
            ACCOUNTANT.withdraw(poolKey.token1, recipient, uint128(-delta1));
        }
    }
}

contract Ve33RewardsTest is FullTest {
    using CoreLib for *;

    Ve33Rewards internal ve;
    VeToken internal veToken;
    Ve33RewardsForwarder internal forwarder;
    TestToken internal stakeToken;

    function setUp() public override {
        super.setUp();

        stakeToken = new TestToken(address(this));
        address deployAddress = address(uint160(ve33RewardsCallPoints().toUint8()) << 152);
        veToken = new VeToken(address(stakeToken), deployAddress);
        deployCodeTo("Ve33Rewards.sol", abi.encode(core, address(stakeToken), veToken), deployAddress);
        ve = Ve33Rewards(payable(deployAddress));
        forwarder = new Ve33RewardsForwarder(core, address(stakeToken));

        stakeToken.approve(address(ve), type(uint256).max);
        stakeToken.approve(address(veToken), type(uint256).max);
        stakeToken.approve(address(forwarder), type(uint256).max);
        token0.approve(address(forwarder), type(uint256).max);
        token1.approve(address(forwarder), type(uint256).max);
    }

    function coolAllContracts() internal virtual override {
        FullTest.coolAllContracts();
        vm.cool(address(ve));
        vm.cool(address(veToken));
        vm.cool(address(forwarder));
        vm.cool(address(stakeToken));
    }

    function _createConcentratedPool() internal returns (PoolKey memory poolKey, PositionId positionId) {
        poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(ve)});
        positionId = createPositionId(bytes24(uint192(1)), -100, 100);
    }

    function _createConcentratedPool(uint32 tickSpacing, bytes24 salt)
        internal
        returns (PoolKey memory poolKey, PositionId positionId)
    {
        poolKey = createPool({tick: 0, fee: 0, tickSpacing: tickSpacing, extension: address(ve)});
        positionId = createPositionId(salt, -int32(tickSpacing), int32(tickSpacing));
    }

    function _createStableswapPool(uint8 amplification, int32 tick)
        internal
        returns (PoolKey memory poolKey, PositionId positionId)
    {
        PoolConfig config = createStableswapPoolConfig(0, amplification, 0, address(ve));
        poolKey = createPool(address(token0), address(token1), tick, config);
        (int32 lower, int32 upper) = config.stableswapActiveLiquidityTickRange();
        positionId = createPositionId(bytes24(uint192(1)), lower, upper);
    }

    function _createLock() internal returns (uint256 veId) {
        veId = veToken.createLock(1e18, uint64(block.timestamp + veToken.MAX_LOCK_DURATION()));
    }

    function _singlePoolArrays(PoolKey memory poolKey, uint256 weight, uint64 swapFee)
        internal
        pure
        returns (PoolKey[] memory poolKeys, uint256[] memory weights, uint64[] memory swapFees)
    {
        poolKeys = new PoolKey[](1);
        weights = new uint256[](1);
        swapFees = new uint64[](1);
        poolKeys[0] = poolKey;
        weights[0] = weight;
        swapFees[0] = swapFee;
    }

    function _vote(uint256 veId, PoolKey memory poolKey, uint256 weight, uint64 swapFee) internal {
        (PoolKey[] memory poolKeys, uint256[] memory weights, uint64[] memory swapFees) =
            _singlePoolArrays(poolKey, weight, swapFee);
        ve.vote(veId, poolKeys, weights, swapFees);
    }

    function _poolVoteState(PoolId poolId)
        internal
        view
        returns (uint256 weight, uint256 feeWeightSum, uint64 swapFee, uint64 defaultSwapFee)
    {
        (weight,,,,, feeWeightSum, swapFee, defaultSwapFee) = ve.poolVoteStates(poolId);
    }

    function _fundAndVote(PoolKey memory poolKey, uint64 swapFee) internal returns (uint256 veId) {
        veId = _createLock();
        _vote(veId, poolKey, 1, swapFee);
    }

    function _nextValidRewardTime(uint256 afterTime) internal view returns (uint64) {
        return uint64(nextValidTime(block.timestamp, afterTime));
    }

    function _poolMappingSlot(PoolId poolId, uint256 slot) internal pure returns (bytes32) {
        return keccak256(abi.encode(PoolId.unwrap(poolId), slot));
    }

    function _poolTimeMappingSlot(PoolId poolId, uint256 slot, uint256 time) internal pure returns (bytes32) {
        return keccak256(abi.encode(time, _poolMappingSlot(poolId, slot)));
    }

    function _scheduledRewardAmount(uint64 startTime, uint64 endTime, uint224 rewardRate)
        internal
        view
        returns (uint224)
    {
        uint256 realStart = startTime > block.timestamp ? startTime : block.timestamp;
        return uint224((((uint256(endTime) - realStart) * rewardRate) + type(uint32).max) >> 32);
    }

    function test_gas_createLock() public {
        coolAllContracts();
        veToken.createLock(1e18, uint64(block.timestamp + veToken.MAX_LOCK_DURATION()));
        vm.snapshotGasLastCall("VeToken#createLock");
    }

    function test_gas_vote() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        uint256 veId = _createLock();

        coolAllContracts();
        _vote(veId, poolKey, 1, uint64(1 << 62));
        vm.snapshotGasLastCall("Ve33Rewards#vote one pool");
    }

    function test_gas_updatePosition() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();

        coolAllContracts();
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));
        vm.snapshotGasLastCall("Ve33Rewards#updatePosition");
    }

    function test_gas_forwardedSwap() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _fundAndVote(poolKey, uint64(1 << 62));

        coolAllContracts();
        forwarder.swap(poolKey, false, 100_000, address(this));
        vm.snapshotGasLastCall("Ve33Rewards#forwardedSwap");
    }

    function test_gas_claimPoolFees() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));
        uint256 veId = _fundAndVote(poolKey, uint64(1 << 62));
        forwarder.swap(poolKey, false, 100_000, address(this));

        coolAllContracts();
        ve.claimPoolFees(veId, poolKey);
        vm.snapshotGasLastCall("Ve33Rewards#claimPoolFees");
    }

    function test_gas_donateRewards() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));

        coolAllContracts();
        forwarder.donateRewards(poolKey, 1_000);
        vm.snapshotGasLastCall("Ve33Rewards#donateRewards");
    }

    function test_gas_addRewards() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));

        coolAllContracts();
        forwarder.addRewards(poolKey, 0, _nextValidRewardTime(block.timestamp + 1 days - 1), uint224(1 << 32));
        vm.snapshotGasLastCall("Ve33Rewards#addRewards");
    }

    function test_gas_claimRewards() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));
        forwarder.donateRewards(poolKey, 1_000);

        coolAllContracts();
        forwarder.claimRewards(poolKey, positionId, address(this));
        vm.snapshotGasLastCall("Ve33Rewards#claimRewards");
    }

    function test_gas_triggerPoolEmissions() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        _fundAndVote(poolKey, uint64(1 << 62));
        ve.fundEmissions(10_000);
        vm.warp(block.timestamp + 1 days);

        coolAllContracts();
        ve.triggerPoolEmissions(poolKey);
        vm.snapshotGasLastCall("Ve33Rewards#triggerPoolEmissions");
    }

    function test_gas_stableswapForwardedSwap() public {
        (PoolKey memory poolKey, PositionId positionId) = _createStableswapPool(20, 0);
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _fundAndVote(poolKey, uint64(1 << 62));

        coolAllContracts();
        forwarder.swap(poolKey, true, 100_000, address(this));
        vm.snapshotGasLastCall("Ve33Rewards#stableswapForwardedSwap");
    }

    function test_registrationAndCallPoints() public view {
        assertTrue(core.isExtensionRegistered(address(ve)));
        assertTrue(ve33RewardsCallPoints().beforeInitializePool);
        assertTrue(ve33RewardsCallPoints().beforeSwap);
        assertTrue(ve33RewardsCallPoints().beforeUpdatePosition);
        assertFalse(ve33RewardsCallPoints().afterInitializePool);
        assertFalse(ve33RewardsCallPoints().afterSwap);
        assertFalse(ve33RewardsCallPoints().afterUpdatePosition);
        assertFalse(ve33RewardsCallPoints().beforeCollectFees);
        assertFalse(ve33RewardsCallPoints().afterCollectFees);
        assertEq(ve.stakeToken(), address(stakeToken));
        assertEq(address(ve.veToken()), address(veToken));
        assertEq(veToken.stakeToken(), address(stakeToken));
        assertEq(veToken.lockObserver(), address(ve));
    }

    function test_poolInitialization_setsConcentratedDefaultsAndRejectsConfigFee() public {
        vm.expectRevert(Ve33Rewards.ZeroConfigFeeOnly.selector);
        createPool({tick: 0, fee: 1, tickSpacing: 100, extension: address(ve)});

        (PoolKey memory poolKey,) = _createConcentratedPool();
        PoolId poolId = poolKey.toPoolId();
        uint64 expectedFee = ve.defaultFeeForTickSpacing(100);
        (,,,,,, uint64 swapFee, uint64 defaultSwapFee) = ve.poolVoteStates(poolId);
        assertEq(swapFee, expectedFee);
        assertEq(defaultSwapFee, expectedFee);
    }

    function test_directHooksAndMalformedForwardRevert() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        SwapParameters params = createSwapParameters({
            _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: int128(1), _isToken1: false, _skipAhead: 0
        });

        vm.expectRevert(Ve33Rewards.SwapMustHappenThroughForward.selector);
        ve.beforeSwap(Locker.wrap(bytes32(0)), poolKey, params);

        vm.expectRevert();
        ve.beforeUpdatePosition(Locker.wrap(bytes32(0)), poolKey, positionId, 0);

        vm.expectRevert(Ve33Rewards.OnlyVeToken.selector);
        ve.beforeLockUpdate(1);

        vm.expectRevert();
        forwarder.rawForward(address(ve), abi.encode(uint256(999)));

        vm.prank(address(ve));
        (bool success,) = address(core).call(abi.encodeWithSelector(core.lock.selector, uint256(999)));
        assertFalse(success);
    }

    function test_lockLifecycleAndInvalidLockPaths() public {
        uint256 maxLockDuration = veToken.MAX_LOCK_DURATION();

        vm.expectRevert(VeToken.InvalidLock.selector);
        veToken.createLock(0, uint64(block.timestamp + 1));
        vm.expectRevert(VeToken.InvalidLock.selector);
        veToken.createLock(1, uint64(block.timestamp));
        vm.expectRevert(VeToken.InvalidLock.selector);
        veToken.createLock(1, uint64(block.timestamp + maxLockDuration + 1));

        uint256 veId = _createLock();
        assertEq(veToken.ownerOf(veId), address(this));
        (uint128 amount, uint64 end) = veToken.locks(veId);
        assertEq(amount, 1e18);
        assertEq(end, uint64(block.timestamp + veToken.MAX_LOCK_DURATION()));
        assertEq(veToken.votingPower(veId), 1e18);

        vm.expectRevert(VeToken.InvalidLock.selector);
        veToken.increaseLockAmount(veId, 0);
        veToken.increaseLockAmount(veId, 2e18);
        (amount,) = veToken.locks(veId);
        assertEq(amount, 3e18);

        vm.expectRevert(VeToken.InvalidLock.selector);
        veToken.extendLock(veId, end);
        vm.warp(10);
        veToken.extendLock(veId, uint64(block.timestamp + veToken.MAX_LOCK_DURATION()));
        (, end) = veToken.locks(veId);
        assertEq(end, uint64(block.timestamp + veToken.MAX_LOCK_DURATION()));

        vm.expectRevert(VeToken.InvalidLock.selector);
        veToken.withdrawLock(veId);
        vm.warp(end);
        assertEq(veToken.votingPower(veId), 0);
        uint256 balanceBefore = stakeToken.balanceOf(address(this));
        veToken.withdrawLock(veId);
        assertEq(stakeToken.balanceOf(address(this)), balanceBefore + 3e18);
    }

    function test_voteValidationAndVoteWithTickSpacing() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        uint256 veId = _createLock();

        PoolKey[] memory poolKeys = new PoolKey[](1);
        uint256[] memory weights = new uint256[](2);
        uint64[] memory swapFees = new uint64[](1);
        poolKeys[0] = poolKey;
        weights[0] = 1;
        weights[1] = 1;
        swapFees[0] = 1;
        vm.expectRevert(Ve33Rewards.InvalidVote.selector);
        ve.vote(veId, poolKeys, weights, swapFees);

        weights = new uint256[](1);
        weights[0] = 0;
        vm.expectRevert(Ve33Rewards.InvalidVote.selector);
        ve.vote(veId, poolKeys, weights, swapFees);

        PoolKey[] memory duplicatePools = new PoolKey[](2);
        uint256[] memory duplicateWeights = new uint256[](2);
        uint64[] memory duplicateFees = new uint64[](2);
        duplicatePools[0] = poolKey;
        duplicatePools[1] = poolKey;
        duplicateWeights[0] = 1;
        duplicateWeights[1] = 1;
        duplicateFees[0] = 1;
        duplicateFees[1] = 1;
        vm.expectRevert(Ve33Rewards.InvalidVote.selector);
        ve.vote(veId, duplicatePools, duplicateWeights, duplicateFees);

        PoolKey memory wrongExtensionPool = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(0)});
        poolKeys[0] = wrongExtensionPool;
        weights[0] = 1;
        vm.expectRevert(Ve33Rewards.InvalidVote.selector);
        ve.vote(veId, poolKeys, weights, swapFees);

        PoolConfig wrongFeeConfig = createConcentratedPoolConfig(1, 100, address(ve));
        PoolKey memory wrongFeePool =
            PoolKey({token0: address(token0), token1: address(token1), config: wrongFeeConfig});
        poolKeys[0] = wrongFeePool;
        vm.expectRevert(Ve33Rewards.InvalidVote.selector);
        ve.vote(veId, poolKeys, weights, swapFees);

        uint32[] memory tickSpacings = new uint32[](2);
        vm.expectRevert(Ve33Rewards.InvalidVote.selector);
        ve.voteWithTickSpacing(veId, poolKeys, weights, tickSpacings);

        poolKeys[0] = poolKey;
        tickSpacings = new uint32[](1);
        tickSpacings[0] = 200;
        ve.voteWithTickSpacing(veId, poolKeys, weights, tickSpacings);
        (uint256 weight, uint256 feeWeightSum, uint64 swapFee,) = _poolVoteState(poolKey.toPoolId());
        assertEq(weight, veToken.votingPower(veId));
        assertEq(swapFee, ve.defaultFeeForTickSpacing(200));
        assertEq(feeWeightSum, weight * swapFee);

        vm.warp(block.timestamp + veToken.MAX_LOCK_DURATION());
        uint256 expiredVeId = veToken.createLock(1, uint64(block.timestamp + 1));
        vm.warp(block.timestamp + 1);
        vm.expectRevert(Ve33Rewards.InvalidVote.selector);
        ve.vote(expiredVeId, poolKeys, weights, swapFees);

        uint256 veIdWithDustVote = _createLock();
        PoolKey[] memory twoPoolKeys = new PoolKey[](2);
        uint256[] memory dustWeights = new uint256[](2);
        uint64[] memory zeroSwapFees = new uint64[](2);
        (PoolKey memory dustPool,) = _createConcentratedPool(200, bytes24(uint192(2)));
        (PoolKey memory otherPool,) = _createConcentratedPool(400, bytes24(uint192(3)));
        twoPoolKeys[0] = dustPool;
        twoPoolKeys[1] = otherPool;
        dustWeights[0] = 1;
        dustWeights[1] = 2e18;
        ve.vote(veIdWithDustVote, twoPoolKeys, dustWeights, zeroSwapFees);
        (uint256 dustPoolWeight,,,) = _poolVoteState(dustPool.toPoolId());
        (uint256 otherPoolWeight,,,) = _poolVoteState(otherPool.toPoolId());
        assertEq(dustPoolWeight, 0);
        assertGt(otherPoolWeight, 0);
    }

    function test_forwardedSwapAccountsVoterFee() public {
        vm.warp(1);

        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint64 swapFee = uint64(1 << 62);
        uint256 veId = _fundAndVote(poolKey, swapFee);

        forwarder.swap(poolKey, false, 100_000, address(this));

        uint128 expectedFee = computeFee(100_000, swapFee);
        (uint128 saved0, uint128 saved1) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        assertEq(saved0, expectedFee);
        assertEq(saved1, 0);

        uint256 balanceBefore = token0.balanceOf(address(this));
        (uint128 claimed0, uint128 claimed1) = ve.claimPoolFees(veId, poolKey);
        assertApproxEqAbs(claimed0, expectedFee, 1);
        assertEq(claimed1, 0);
        assertEq(token0.balanceOf(address(this)), balanceBefore + claimed0);

        (saved0, saved1) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        assertEq(saved0, expectedFee - claimed0);
        assertEq(saved1, 0);
    }

    function test_forwardedSwapCoversToken1AndExactOutFeeBranches() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));
        _fundAndVote(poolKey, uint64(1 << 62));

        forwarder.swap(poolKey, true, 100_000, address(this));
        (, uint128 saved1AfterExactIn) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        assertGt(saved1AfterExactIn, 0);

        SwapParameters token1Out = createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: -int128(1_000), _isToken1: true, _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
        forwarder.swap(poolKey, token1Out, address(this));
        (uint128 saved0AfterExactOut,) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        assertGt(saved0AfterExactOut, 0);

        SwapParameters token0Out = createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: -int128(1_000), _isToken1: false, _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
        forwarder.swap(poolKey, token0Out, address(this));
        (, uint128 saved1AfterExactOut) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        assertGt(saved1AfterExactOut, saved1AfterExactIn);
    }

    function test_zeroFeeVoteAndUnweightedFees() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint256 veId = _fundAndVote(poolKey, 0);
        forwarder.swap(poolKey, false, 100_000, address(this));
        (uint128 saved0, uint128 saved1) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        assertEq(saved0, 0);
        assertEq(saved1, 0);
        (uint128 claimed0, uint128 claimed1) = ve.claimPoolFees(veId, poolKey);
        assertEq(claimed0, 0);
        assertEq(claimed1, 0);

        (PoolKey memory unvotedPool, PositionId unvotedPosition) = _createConcentratedPool(200, bytes24(uint192(2)));
        forwarder.updatePosition(unvotedPool, unvotedPosition, int128(uint128(1e18)));
        forwarder.swap(unvotedPool, false, 100_000, address(this));
        (saved0, saved1) = core.savedBalances(
            address(ve), unvotedPool.token0, unvotedPool.token1, PoolId.unwrap(unvotedPool.toPoolId())
        );
        assertGt(saved0, 0);
        assertEq(saved1, 0);
    }

    function test_clearVotesOnLockChangesRestoresDefaultFee() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        uint256 veId = _fundAndVote(poolKey, 0);
        (,, uint64 swapFee, uint64 defaultSwapFee) = _poolVoteState(poolKey.toPoolId());
        assertEq(swapFee, 0);
        assertGt(defaultSwapFee, 0);

        veToken.increaseLockAmount(veId, 1);
        (uint256 weight, uint256 feeWeightSum, uint64 swapFeeAfterIncrease,) = _poolVoteState(poolKey.toPoolId());
        assertEq(weight, 0);
        assertEq(feeWeightSum, 0);
        assertEq(swapFeeAfterIncrease, defaultSwapFee);

        _vote(veId, poolKey, 1, 0);
        vm.warp(block.timestamp + 1);
        veToken.extendLock(veId, uint64(block.timestamp + veToken.MAX_LOCK_DURATION()));
        (uint256 weightAfterExtend, uint256 feeWeightSumAfterExtend, uint64 swapFeeAfterExtend,) =
            _poolVoteState(poolKey.toPoolId());
        assertEq(weightAfterExtend, 0);
        assertEq(feeWeightSumAfterExtend, 0);
        assertEq(swapFeeAfterExtend, defaultSwapFee);

        _vote(veId, poolKey, 1, 0);
        vm.warp(block.timestamp + veToken.MAX_LOCK_DURATION());
        veToken.withdrawLock(veId);
        (uint256 weightAfterWithdraw, uint256 feeWeightSumAfterWithdraw, uint64 swapFeeAfterWithdraw,) =
            _poolVoteState(poolKey.toPoolId());
        assertEq(weightAfterWithdraw, 0);
        assertEq(feeWeightSumAfterWithdraw, 0);
        assertEq(swapFeeAfterWithdraw, defaultSwapFee);
    }

    function test_donateAndClaimRewards() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint128 donated = forwarder.donateRewards(poolKey, 1_000);
        assertEq(donated, 1_000);
        assertEq(ve.rewardsGlobalPerLiquidity(poolKey.toPoolId()), (uint256(1_000) << 128) / 1e18);

        uint256 balanceBefore = stakeToken.balanceOf(address(1234));
        uint256 claimed = forwarder.claimRewards(poolKey, positionId, address(1234));
        assertApproxEqAbs(claimed, 1_000, 1);
        assertEq(stakeToken.balanceOf(address(1234)), balanceBefore + claimed);

        assertEq(forwarder.claimRewards(poolKey, positionId, address(1234)), 0);
    }

    function test_donateRewardsWithZeroLiquidityDoesNotIncreaseGlobalRewards() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        assertEq(forwarder.donateRewards(poolKey, 777), 777);
        assertEq(ve.rewardsGlobalPerLiquidity(poolKey.toPoolId()), 0);

        (uint128 saved,) = core.savedBalances(address(ve), address(stakeToken), address(type(uint160).max), bytes32(0));
        assertEq(saved, 777);

        assertEq(forwarder.donateRewards(poolKey, 0), 0);
    }

    function test_addRewardsImmediateFutureInvalidAndOverflow() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));

        vm.expectRevert(Ve33Rewards.InvalidTimestamps.selector);
        forwarder.addRewards(poolKey, 0, uint64(block.timestamp), uint224(1 << 32));

        vm.expectRevert(Ve33Rewards.RewardAmountOverflow.selector);
        forwarder.addRewards(poolKey, 0, _nextValidRewardTime(block.timestamp), type(uint224).max);

        uint64 immediateEndTime = _nextValidRewardTime(block.timestamp + 2 days - 1);
        uint224 rewardRate = uint224(1 << 32);
        uint224 immediateAmount = forwarder.addRewards(poolKey, 0, immediateEndTime, rewardRate);
        assertEq(immediateAmount, _scheduledRewardAmount(0, immediateEndTime, rewardRate));

        vm.warp(block.timestamp + 1 days);
        ve.maybeAccumulateRewards(poolKey);
        assertApproxEqAbs(forwarder.claimRewards(poolKey, positionId, address(this)), 1 days, 1);
    }

    function test_addRewardsFutureSchedule() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint224 rewardRate = uint224(1 << 32);
        uint64 startTime = _nextValidRewardTime(block.timestamp + 1 days - 1);
        uint64 endTime = _nextValidRewardTime(uint256(startTime) + 2 days - 1);
        uint224 futureAmount = forwarder.addRewards(poolKey, startTime, endTime, rewardRate);
        assertEq(futureAmount, _scheduledRewardAmount(startTime, endTime, rewardRate));

        vm.warp(startTime - 1);
        ve.maybeAccumulateRewards(poolKey);
        assertEq(forwarder.claimRewards(poolKey, positionId, address(this)), 0);

        vm.warp(startTime + 1 days);
        ve.maybeAccumulateRewards(poolKey);
        assertApproxEqAbs(forwarder.claimRewards(poolKey, positionId, address(this)), 1 days, 1);
    }

    function test_maybeAccumulateRewardsPoolRecoveryAndOutOfRangeStableswap() public {
        PoolConfig wrongConfig = createConcentratedPoolConfig(0, 100, address(0));
        PoolKey memory wrongPool = PoolKey({token0: address(token0), token1: address(token1), config: wrongConfig});
        vm.expectRevert(Ve33Rewards.PoolNotInitialized.selector);
        ve.maybeAccumulateRewards(wrongPool);

        (PoolKey memory initializedPool,) = _createConcentratedPool(200, bytes24(uint192(2)));
        vm.store(address(ve), _poolMappingSlot(initializedPool.toPoolId(), 3), bytes32(0));
        ve.maybeAccumulateRewards(initializedPool);
        vm.warp(block.timestamp + uint256(type(uint32).max) + 1);
        ve.maybeAccumulateRewards(initializedPool);
        assertEq(ve.rewardsGlobalPerLiquidity(initializedPool.toPoolId()), 0);

        (PoolKey memory stablePool, PositionId stablePosition) = _createStableswapPool(20, 0);
        forwarder.updatePosition(stablePool, stablePosition, int128(uint128(1e18)));
        uint256 beforeGlobal = ve.rewardsGlobalPerLiquidity(stablePool.toPoolId());

        forwarder.addRewards(stablePool, 0, _nextValidRewardTime(block.timestamp + 1 days - 1), uint224(1 << 32));
        (, PoolState stateAfter) = forwarder.swap(stablePool, true, int128(1e30), address(this));
        (, int32 upper) = stablePool.config.stableswapActiveLiquidityTickRange();
        assertGe(stateAfter.tick(), upper);
        vm.warp(block.timestamp + 1 hours);
        ve.maybeAccumulateRewards(stablePool);
        assertEq(ve.rewardsGlobalPerLiquidity(stablePool.toPoolId()), beforeGlobal);
    }

    function test_triggerPoolEmissionsDistributesToVotedPool() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));

        assertEq(ve.triggerPoolEmissions(poolKey), 0);

        _fundAndVote(poolKey, uint64(1 << 62));
        ve.fundEmissions(1e18);
        vm.warp(block.timestamp + 1 days);
        uint224 amount = ve.triggerPoolEmissions(poolKey);
        assertGt(amount, 0);
        assertLt(amount, 1e18);

        vm.warp(block.timestamp + ve.EMISSION_DURATION());
        ve.maybeAccumulateRewards(poolKey);
        assertGt(forwarder.claimRewards(poolKey, positionId, address(this)), 0);

        PoolKey memory wrongPool = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(0)});
        vm.expectRevert(Ve33Rewards.PoolNotInitialized.selector);
        ve.triggerPoolEmissions(wrongPool);
    }

    function test_triggerPoolEmissionsRoundsTinyPoolShareToZero() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        (PoolKey memory otherPool,) = _createConcentratedPool(200, bytes24(uint192(2)));

        uint256 veId = _createLock();
        PoolKey[] memory poolKeys = new PoolKey[](2);
        uint256[] memory weights = new uint256[](2);
        uint64[] memory swapFees = new uint64[](2);
        poolKeys[0] = poolKey;
        poolKeys[1] = otherPool;
        weights[0] = 1;
        weights[1] = 1e18 - 1;
        ve.vote(veId, poolKeys, weights, swapFees);

        ve.fundEmissions(2);
        vm.warp(block.timestamp + ve.EMISSION_DURATION());

        assertEq(ve.triggerPoolEmissions(poolKey), 0);
        assertGt(ve.unallocatedEmissions(), 0);
    }

    function test_triggerPoolEmissionsCapsAmountToEmissionReserve() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        _fundAndVote(poolKey, uint64(1 << 62));
        ve.fundEmissions(1);
        vm.warp(block.timestamp + 1 days);

        vm.store(address(ve), bytes32(uint256(12)), bytes32(uint256(1)));
        vm.store(address(ve), bytes32(uint256(13)), bytes32(uint256(1_000)));

        assertEq(ve.triggerPoolEmissions(poolKey), 1);
        assertEq(ve.emissionReserve(), 0);
    }

    function test_fundEmissionsAccruesMultipleEventsAtSameTime() public {
        vm.expectRevert(Ve33Rewards.EmissionAmountTooSmall.selector);
        ve.fundEmissions(0);

        ve.fundEmissions(1_000);
        ve.fundEmissions(2_000);
        assertGt(ve.emissionRate(), 0);
        assertEq(ve.emissionEventTimes(0), uint64(block.timestamp + ve.EMISSION_DURATION()));
        assertEq(ve.emissionEventTimes(1), uint64(block.timestamp + ve.EMISSION_DURATION()));

        vm.warp(block.timestamp + ve.EMISSION_DURATION());
        (PoolKey memory poolKey,) = _createConcentratedPool();
        ve.triggerPoolEmissions(poolKey);
        assertEq(ve.nextEmissionEventIndex(), 2);
        assertEq(ve.emissionRate(), 0);
        assertGt(ve.unallocatedEmissions(), 0);
    }

    function test_fundEmissionsAccruesBeforeAddingNewRate() public {
        ve.fundEmissions(1_000);
        vm.warp(block.timestamp + ve.EMISSION_DURATION());

        ve.fundEmissions(1_000);

        assertEq(ve.nextEmissionEventIndex(), 1);
        assertGt(ve.unallocatedEmissions(), 0);
        assertGt(ve.emissionRate(), 0);
    }

    function test_rewardSnapshotsAcrossConcentratedAndStableswapBoundaries() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        PoolId poolId = poolKey.toPoolId();
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));
        forwarder.donateRewards(poolKey, 1_000);
        uint256 global = ve.rewardsGlobalPerLiquidity(poolId);

        SwapParameters upToUpper = createSwapParameters({
            _sqrtRatioLimit: tickToSqrtRatio(101), _amount: int128(1e30), _isToken1: true, _skipAhead: 0
        });
        (, PoolState stateAfterUpper) = forwarder.swap(poolKey, upToUpper, address(this));
        assertGe(stateAfterUpper.tick(), 100);
        assertEq(ve.tickRewardsOutsidePerLiquidity(poolId, 100), global);
        assertGt(forwarder.claimRewards(poolKey, positionId, address(this)), 0);

        SwapParameters downToLower = createSwapParameters({
            _sqrtRatioLimit: tickToSqrtRatio(-101), _amount: int128(1e30), _isToken1: false, _skipAhead: 0
        });
        (, PoolState stateAfterLower) = forwarder.swap(poolKey, downToLower, address(this));
        assertLt(stateAfterLower.tick(), -100);
        assertEq(ve.tickRewardsOutsidePerLiquidity(poolId, -100), global);

        forwarder.updatePosition(poolKey, positionId, -int128(uint128(1e18)));
        assertEq(ve.positionRewardsSnapshotPerLiquidity(poolId, address(forwarder), positionId), 0);
        assertEq(ve.tickRewardsOutsidePerLiquidity(poolId, -100), 0);
        assertEq(ve.tickRewardsOutsidePerLiquidity(poolId, 100), 0);

        (PoolKey memory stablePool, PositionId stablePosition) = _createStableswapPool(20, 0);
        PoolId stablePoolId = stablePool.toPoolId();
        (int32 lower, int32 upper) = stablePool.config.stableswapActiveLiquidityTickRange();
        forwarder.updatePosition(stablePool, stablePosition, int128(uint128(1e18)));
        forwarder.donateRewards(stablePool, 1_000);
        global = ve.rewardsGlobalPerLiquidity(stablePoolId);

        upToUpper = createSwapParameters({
            _sqrtRatioLimit: tickToSqrtRatio(upper + 1), _amount: int128(1e30), _isToken1: true, _skipAhead: 0
        });
        (, stateAfterUpper) = forwarder.swap(stablePool, upToUpper, address(this));
        assertGe(stateAfterUpper.tick(), upper);
        assertEq(ve.tickRewardsOutsidePerLiquidity(stablePoolId, upper), global);

        downToLower = createSwapParameters({
            _sqrtRatioLimit: tickToSqrtRatio(lower - 1), _amount: int128(1e30), _isToken1: false, _skipAhead: 0
        });
        (, stateAfterLower) = forwarder.swap(stablePool, downToLower, address(this));
        assertLt(stateAfterLower.tick(), lower);
        assertEq(ve.tickRewardsOutsidePerLiquidity(stablePoolId, lower), global);

        SwapParameters upToLower = createSwapParameters({
            _sqrtRatioLimit: tickToSqrtRatio(lower + 1), _amount: int128(1e30), _isToken1: true, _skipAhead: 0
        });
        (, PoolState stateAfterLowerUp) = forwarder.swap(stablePool, upToLower, address(this));
        assertGe(stateAfterLowerUp.tick(), lower);
        assertEq(ve.tickRewardsOutsidePerLiquidity(stablePoolId, lower), 0);

        forwarder.updatePosition(stablePool, stablePosition, -int128(uint128(1e18)));
        assertEq(ve.tickRewardsOutsidePerLiquidity(stablePoolId, lower), 0);
        assertEq(ve.tickRewardsOutsidePerLiquidity(stablePoolId, upper), 0);
    }

    function test_claimRewardsOverflowReverts() public {
        (PoolKey memory poolKey, PositionId positionId) = _createConcentratedPool();
        PoolId poolId = poolKey.toPoolId();
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));

        vm.store(address(ve), _poolMappingSlot(poolId, 4), bytes32(type(uint256).max));

        vm.expectRevert(Ve33Rewards.RewardAmountOverflow.selector);
        forwarder.claimRewards(poolKey, positionId, address(this));
    }

    function test_rewardRateDeltaOverflowReverts() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        PoolId poolId = poolKey.toPoolId();
        ve.maybeAccumulateRewards(poolKey);

        uint64 startTime = _nextValidRewardTime(block.timestamp + 1 days - 1);
        uint64 endTime = _nextValidRewardTime(uint256(startTime) + 1 days - 1);
        uint256 maxRateDelta = type(uint224).max / MAX_NUM_VALID_TIMES;
        vm.store(address(ve), _poolTimeMappingSlot(poolId, 8, startTime), bytes32(maxRateDelta));

        vm.expectRevert(Ve33Rewards.MaxRateDeltaPerTime.selector);
        forwarder.addRewards(poolKey, startTime, endTime, uint224(1 << 32));
    }

    function test_accumulatedRewardRateOverflowReverts() public {
        (PoolKey memory poolKey,) = _createConcentratedPool();
        PoolId poolId = poolKey.toPoolId();
        ve.maybeAccumulateRewards(poolKey);

        vm.store(
            address(ve),
            _poolMappingSlot(poolId, 3),
            bytes32((uint256(type(uint224).max) << 32) | uint32(block.timestamp))
        );

        uint64 startTime = _nextValidRewardTime(block.timestamp + 1 days - 1);
        uint64 endTime = _nextValidRewardTime(uint256(startTime) + 1 days - 1);
        forwarder.addRewards(poolKey, startTime, endTime, 1);

        vm.warp(startTime);
        vm.expectRevert(Ve33Rewards.MaxRateDeltaPerTime.selector);
        ve.maybeAccumulateRewards(poolKey);
    }

    function test_stableswapPoolUsesAmplificationDefaultFee() public {
        PoolConfig config = createStableswapPoolConfig(0, 20, 0, address(ve));
        PoolKey memory poolKey = createPool(address(token0), address(token1), 0, config);
        PoolId poolId = poolKey.toPoolId();

        uint64 expectedFee = ve.defaultFeeForStableswapAmplification(20);
        (,, uint64 swapFee, uint64 defaultSwapFee) = _poolVoteState(poolId);

        assertEq(ve.defaultFeeForPoolConfig(config), expectedFee);
        assertEq(swapFee, expectedFee);
        assertEq(defaultSwapFee, expectedFee);
    }
}
