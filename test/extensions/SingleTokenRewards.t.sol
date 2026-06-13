// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {SingleTokenRewards, singleTokenRewardsCallPoints} from "../../src/extensions/SingleTokenRewards.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {ISingleTokenRewards} from "../../src/interfaces/extensions/ISingleTokenRewards.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {
    SINGLE_TOKEN_REWARDS_ADD_REWARDS,
    SINGLE_TOKEN_REWARDS_CLAIM_TO_OWNER,
    SingleTokenRewardsLib
} from "../../src/libraries/SingleTokenRewardsLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {PositionId, createPositionId} from "../../src/types/positionId.sol";
import {SingleTokenRewardsPoolState} from "../../src/types/singleTokenRewardsPoolState.sol";
import {CallPoints} from "../../src/types/callPoints.sol";
import {Locker} from "../../src/types/locker.sol";
import {createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";

contract SingleTokenRewardsForwarder is BaseLocker {
    using SingleTokenRewardsLib for ICore;

    ICore private immutable CORE_REF;

    constructor(ICore core) BaseLocker(core) {
        CORE_REF = core;
    }

    function addRewards(PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate)
        external
        returns (uint224 amount)
    {
        amount = abi.decode(
            lock(abi.encode(SINGLE_TOKEN_REWARDS_ADD_REWARDS, msg.sender, poolKey, startTime, endTime, rewardRate)),
            (uint224)
        );
    }

    function claimRewards(PoolKey memory poolKey, address owner, PositionId positionId)
        external
        returns (uint256 amount)
    {
        amount = abi.decode(
            lock(abi.encode(SINGLE_TOKEN_REWARDS_CLAIM_TO_OWNER, poolKey, owner, positionId)), (uint256)
        );
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == SINGLE_TOKEN_REWARDS_ADD_REWARDS) {
            (, address payer, PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate) =
                abi.decode(data, (uint256, address, PoolKey, uint64, uint64, uint224));
            result = abi.encode(CORE_REF.addRewards(poolKey, payer, startTime, endTime, rewardRate));
        } else {
            (, PoolKey memory poolKey, address owner, PositionId positionId) =
                abi.decode(data, (uint256, PoolKey, address, PositionId));
            result = abi.encode(CORE_REF.claimRewards(poolKey, owner, positionId));
        }
    }
}

contract SingleTokenRewardsTest is FullTest {
    using CoreLib for *;

    SingleTokenRewards internal rewards;
    SingleTokenRewardsForwarder internal forwarder;
    TestToken internal incentiveToken;

    function _deploySingleTokenRewards() internal returns (SingleTokenRewards deployed) {
        CallPoints memory cp = singleTokenRewardsCallPoints();
        address target = address(uint160(cp.toUint8()) << 152);
        deployCodeTo("SingleTokenRewards.sol", abi.encode(core, address(incentiveToken)), target);
        deployed = SingleTokenRewards(target);
    }

    function setUp() public override {
        super.setUp();

        incentiveToken = new TestToken(address(this));
        rewards = _deploySingleTokenRewards();
        forwarder = new SingleTokenRewardsForwarder(core);
        incentiveToken.approve(address(rewards), type(uint256).max);
    }

    function _positionId(uint256 id, int32 tickLower, int32 tickUpper) internal pure returns (PositionId) {
        return createPositionId({_salt: bytes24(uint192(id)), _tickLower: tickLower, _tickUpper: tickUpper});
    }

    function test_registersCallPoints() public view {
        assertTrue(core.isExtensionRegistered(address(rewards)));
        assertEq(rewards.rewardToken(), address(incentiveToken));
    }

    function test_hook_revertsWhenCalledDirectly() public {
        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(rewards)});

        vm.expectRevert(UsesCore.CoreOnly.selector);
        rewards.beforeSwap(
            Locker.wrap(bytes32(0)),
            poolKey,
            createSwapParameters({
                _amount: int128(1), _isToken1: false, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            })
        );
    }

    function test_claimRewards_accumulatesForSinglePosition() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(rewards)});
        (uint256 id,) = createPosition(poolKey, -100, 100, 1e18, 1e18);
        PositionId positionId = _positionId(id, -100, 100);

        uint224 amount = forwarder.addRewards({poolKey: poolKey, startTime: 0, endTime: 256, rewardRate: 1 << 32});
        assertEq(amount, 255);

        vm.warp(101);

        uint256 claimed = forwarder.claimRewards(poolKey, address(positions), positionId);

        assertApproxEqAbs(claimed, 100, 1);
        assertEq(incentiveToken.balanceOf(address(positions)), claimed);
    }

    function test_latePositionDoesNotReceivePriorRewards() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(rewards)});
        (uint256 firstId,) = createPosition(poolKey, -100, 100, 1e18, 1e18);
        PositionId firstPositionId = _positionId(firstId, -100, 100);

        forwarder.addRewards({poolKey: poolKey, startTime: 0, endTime: 256, rewardRate: 1 << 32});

        vm.warp(101);

        (uint256 secondId,) = createPosition(poolKey, -100, 100, 1e18, 1e18);
        PositionId secondPositionId = _positionId(secondId, -100, 100);

        vm.warp(201);

        uint256 firstClaimed = forwarder.claimRewards(poolKey, address(positions), firstPositionId);
        uint256 secondClaimed = forwarder.claimRewards(poolKey, address(positions), secondPositionId);

        assertApproxEqAbs(firstClaimed, 150, 1);
        assertApproxEqAbs(secondClaimed, 50, 1);
        assertApproxEqAbs(firstClaimed + secondClaimed, 200, 2);
    }

    function test_beforeUpdatePositionSettlesSnapshotBeforeLiquidityChange() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(rewards)});
        (uint256 id, uint128 liquidity) = createPosition(poolKey, -100, 100, 1e18, 1e18);
        PositionId positionId = _positionId(id, -100, 100);

        forwarder.addRewards({poolKey: poolKey, startTime: 0, endTime: 256, rewardRate: 1 << 32});

        vm.warp(101);
        positions.withdraw(id, poolKey, -100, 100, liquidity / 2);

        vm.warp(151);
        uint256 claimed = forwarder.claimRewards(poolKey, address(positions), positionId);

        assertApproxEqAbs(claimed, 150, 2);
    }

    function test_beforeUpdatePosition_discardsRewardsWhenPositionFullyWithdrawn() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(rewards)});
        (uint256 id, uint128 liquidity) = createPosition(poolKey, -100, 100, 1e18, 1e18);
        PositionId positionId = _positionId(id, -100, 100);

        forwarder.addRewards({poolKey: poolKey, startTime: 0, endTime: 256, rewardRate: 1 << 32});

        vm.warp(101);
        positions.withdraw(id, poolKey, -100, 100, liquidity);

        uint256 claimed = forwarder.claimRewards(poolKey, address(positions), positionId);

        assertEq(claimed, 0);
    }

    function test_addRewards_revertsForWrongPool() public {
        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createConcentratedPoolConfig(0, 100, address(rewards))
        });

        vm.expectRevert(ISingleTokenRewards.PoolNotInitialized.selector);
        forwarder.addRewards({poolKey: poolKey, startTime: 0, endTime: 256, rewardRate: 1 << 32});
    }

    function test_poolRewardState_setsLastAccumulatedFromHook() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(rewards)});
        PoolId poolId = poolKey.toPoolId();
        createPosition(poolKey, -100, 100, 1e18, 1e18);

        SingleTokenRewardsPoolState state = rewards.poolRewardState(poolId);

        assertEq(state.lastAccumulated(), 1);
        assertEq(state.rewardRate(), 0);
        assertEq(rewards.rewardsPerLiquidityGlobal(poolId), 0);
    }
}
