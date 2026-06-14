// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {SingleTokenRewards, singleTokenRewardsCallPoints} from "../../src/extensions/SingleTokenRewards.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {ISingleTokenRewards} from "../../src/interfaces/extensions/ISingleTokenRewards.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {
    SINGLE_TOKEN_REWARDS_ADD_REWARDS,
    SINGLE_TOKEN_REWARDS_CLAIM_TO_RECIPIENT,
    SINGLE_TOKEN_REWARDS_DONATE_REWARDS,
    SingleTokenRewardsLib
} from "../../src/libraries/SingleTokenRewardsLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {PositionId, createPositionId} from "../../src/types/positionId.sol";
import {SingleTokenRewardsPoolState} from "../../src/types/singleTokenRewardsPoolState.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {CallPoints} from "../../src/types/callPoints.sol";
import {Locker} from "../../src/types/locker.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";

contract SingleTokenRewardsForwarder is BaseLocker {
    using SingleTokenRewardsLib for ICore;
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_UPDATE_POSITION = 100;

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

    function donateRewards(PoolKey memory poolKey, uint128 amount) external returns (uint128 donatedAmount) {
        donatedAmount =
            abi.decode(lock(abi.encode(SINGLE_TOKEN_REWARDS_DONATE_REWARDS, msg.sender, poolKey, amount)), (uint128));
    }

    function claimRewards(PoolKey memory poolKey, PositionId positionId, address recipient)
        external
        returns (uint256 amount)
    {
        amount = abi.decode(
            lock(abi.encode(SINGLE_TOKEN_REWARDS_CLAIM_TO_RECIPIENT, poolKey, positionId, recipient)), (uint256)
        );
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

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == SINGLE_TOKEN_REWARDS_ADD_REWARDS) {
            (, address payer, PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate) =
                abi.decode(data, (uint256, address, PoolKey, uint64, uint64, uint224));
            uint224 amount = CORE_REF.addRewards(poolKey, startTime, endTime, rewardRate);
            if (amount != 0) {
                ACCOUNTANT.payFrom(payer, ISingleTokenRewards(poolKey.config.extension()).rewardToken(), amount);
            }
            result = abi.encode(amount);
        } else if (callType == SINGLE_TOKEN_REWARDS_DONATE_REWARDS) {
            (, address payer, PoolKey memory poolKey, uint128 amount) =
                abi.decode(data, (uint256, address, PoolKey, uint128));
            uint128 donatedAmount = CORE_REF.donateRewards(poolKey, amount);
            if (donatedAmount != 0) {
                ACCOUNTANT.payFrom(payer, ISingleTokenRewards(poolKey.config.extension()).rewardToken(), donatedAmount);
            }
            result = abi.encode(donatedAmount);
        } else if (callType == SINGLE_TOKEN_REWARDS_CLAIM_TO_RECIPIENT) {
            (, PoolKey memory poolKey, PositionId positionId, address recipient) =
                abi.decode(data, (uint256, PoolKey, PositionId, address));
            result = abi.encode(CORE_REF.claimRewards(poolKey, positionId, recipient));
        } else {
            (, address payer, PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta) =
                abi.decode(data, (uint256, address, PoolKey, PositionId, int128));
            PoolBalanceUpdate balanceUpdate = CORE_REF.updatePosition(poolKey, positionId, liquidityDelta);
            int128 delta0 = balanceUpdate.delta0();
            int128 delta1 = balanceUpdate.delta1();

            if (delta0 > 0) {
                ACCOUNTANT.payFrom(payer, poolKey.token0, uint128(delta0));
            } else if (delta0 < 0) {
                ACCOUNTANT.withdraw(poolKey.token0, payer, uint128(-delta0));
            }

            if (delta1 > 0) {
                ACCOUNTANT.payFrom(payer, poolKey.token1, uint128(delta1));
            } else if (delta1 < 0) {
                ACCOUNTANT.withdraw(poolKey.token1, payer, uint128(-delta1));
            }

            result = abi.encode(balanceUpdate);
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
        incentiveToken.approve(address(core), type(uint256).max);
        incentiveToken.approve(address(forwarder), type(uint256).max);
        token0.approve(address(core), type(uint256).max);
        token0.approve(address(forwarder), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(core), type(uint256).max);
        token1.approve(address(forwarder), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
    }

    function _positionId(uint256 id, int32 tickLower, int32 tickUpper) internal pure returns (PositionId) {
        return createPositionId({_salt: bytes24(uint192(id)), _tickLower: tickLower, _tickUpper: tickUpper});
    }

    function _createForwarderPosition(PoolKey memory poolKey, uint256 id, int32 tickLower, int32 tickUpper)
        internal
        returns (PositionId positionId, uint128 liquidity)
    {
        liquidity = 1e18;
        positionId = _positionId(id, tickLower, tickUpper);
        forwarder.updatePosition(poolKey, positionId, int128(liquidity));
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
        (PositionId positionId,) = _createForwarderPosition(poolKey, 1, -100, 100);

        uint224 amount = forwarder.addRewards({poolKey: poolKey, startTime: 0, endTime: 256, rewardRate: 1 << 32});
        assertEq(amount, 255);

        vm.warp(101);

        uint256 balanceBefore = incentiveToken.balanceOf(address(this));
        uint256 claimed = forwarder.claimRewards(poolKey, positionId, address(this));

        assertApproxEqAbs(claimed, 100, 1);
        assertEq(incentiveToken.balanceOf(address(this)), balanceBefore + claimed);
    }

    function test_latePositionDoesNotReceivePriorRewards() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(rewards)});
        (PositionId firstPositionId,) = _createForwarderPosition(poolKey, 1, -100, 100);

        forwarder.addRewards({poolKey: poolKey, startTime: 0, endTime: 256, rewardRate: 1 << 32});

        vm.warp(101);

        (PositionId secondPositionId,) = _createForwarderPosition(poolKey, 2, -100, 100);

        vm.warp(201);

        uint256 firstClaimed = forwarder.claimRewards(poolKey, firstPositionId, address(this));
        uint256 secondClaimed = forwarder.claimRewards(poolKey, secondPositionId, address(this));

        assertApproxEqAbs(firstClaimed, 150, 1);
        assertApproxEqAbs(secondClaimed, 50, 1);
        assertApproxEqAbs(firstClaimed + secondClaimed, 200, 2);
    }

    function test_updatePosition_initializesTickRewardsOutsideLikeCore() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(rewards)});
        PoolId poolId = poolKey.toPoolId();
        _createForwarderPosition(poolKey, 1, -200, 200);

        forwarder.addRewards({poolKey: poolKey, startTime: 0, endTime: 256, rewardRate: 1 << 32});

        vm.warp(101);
        (PositionId positionId, uint128 liquidity) = _createForwarderPosition(poolKey, 2, -100, 100);

        assertEq(rewards.tickRewardsOutsidePerLiquidity(poolId, -100), 1);
        assertEq(rewards.tickRewardsOutsidePerLiquidity(poolId, 100), 1);

        forwarder.updatePosition(poolKey, positionId, -int128(liquidity));

        assertEq(rewards.tickRewardsOutsidePerLiquidity(poolId, -100), 0);
        assertEq(rewards.tickRewardsOutsidePerLiquidity(poolId, 100), 0);
    }

    function test_beforeUpdatePositionSettlesSnapshotBeforeLiquidityChange() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(rewards)});
        (PositionId positionId, uint128 liquidity) = _createForwarderPosition(poolKey, 1, -100, 100);

        forwarder.addRewards({poolKey: poolKey, startTime: 0, endTime: 256, rewardRate: 1 << 32});

        vm.warp(101);
        forwarder.updatePosition(poolKey, positionId, -int128(liquidity / 2));

        vm.warp(151);
        uint256 claimed = forwarder.claimRewards(poolKey, positionId, address(this));

        assertApproxEqAbs(claimed, 150, 2);
    }

    function test_beforeUpdatePosition_discardsRewardsWhenPositionFullyWithdrawn() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(rewards)});
        (PositionId positionId, uint128 liquidity) = _createForwarderPosition(poolKey, 1, -100, 100);

        forwarder.addRewards({poolKey: poolKey, startTime: 0, endTime: 256, rewardRate: 1 << 32});

        vm.warp(101);
        forwarder.updatePosition(poolKey, positionId, -int128(liquidity));

        uint256 claimed = forwarder.claimRewards(poolKey, positionId, address(this));

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
        _createForwarderPosition(poolKey, 1, -100, 100);

        SingleTokenRewardsPoolState state = rewards.poolRewardState(poolId);

        assertEq(state.lastAccumulated(), 1);
        assertEq(state.rewardRate(), 0);
        assertEq(rewards.rewardsGlobalPerLiquidity(poolId), 0);
    }

    function test_donateRewards_immediatelyAccruesForExistingLiquidity() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(rewards)});
        (PositionId positionId,) = _createForwarderPosition(poolKey, 1, -100, 100);

        uint128 donated = forwarder.donateRewards(poolKey, 100);
        assertEq(donated, 100);

        uint256 claimed = forwarder.claimRewards(poolKey, positionId, address(this));

        assertApproxEqAbs(claimed, 100, 1);
    }

    function test_donateRewards_onlyAccruesToInRangeLiquidityAfterSwap() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(rewards)});
        (PositionId lowPositionId,) = _createForwarderPosition(poolKey, 1, -100, 100);
        (PositionId highPositionId,) = _createForwarderPosition(poolKey, 2, 100, 300);

        forwarder.donateRewards(poolKey, 100);

        router.swapAllowPartialFill({
            poolKey: poolKey,
            isToken1: false,
            amount: type(int128).min,
            sqrtRatioLimit: tickToSqrtRatio(200),
            skipAhead: 0,
            recipient: address(this)
        });

        forwarder.donateRewards(poolKey, 100);

        uint256 lowClaimed = forwarder.claimRewards(poolKey, lowPositionId, address(this));
        uint256 highClaimed = forwarder.claimRewards(poolKey, highPositionId, address(this));

        assertApproxEqAbs(lowClaimed, 100, 1);
        assertApproxEqAbs(highClaimed, 100, 1);
    }

    function test_donateRewards_burnsWhenNoLiquidity() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(rewards)});
        PoolId poolId = poolKey.toPoolId();

        uint128 donated = forwarder.donateRewards(poolKey, 100);

        assertEq(donated, 100);
        assertEq(rewards.rewardsGlobalPerLiquidity(poolId), 0);
    }
}
