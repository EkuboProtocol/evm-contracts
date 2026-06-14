// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {TestToken} from "./TestToken.sol";
import {VeGauge} from "../src/VeGauge.sol";
import {VePositions} from "../src/VePositions.sol";
import {SingleTokenRewards, singleTokenRewardsCallPoints} from "../src/extensions/SingleTokenRewards.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolId} from "../src/types/poolId.sol";
import {CallPoints} from "../src/types/callPoints.sol";
import {createSwapParameters} from "../src/types/swapParameters.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";

contract VePositionsTest is FullTest {
    using CoreLib for *;

    VePositions internal vePositions;
    VeGauge internal veGauge;
    TestToken internal stakeToken;
    SingleTokenRewards internal rewards;

    function setUp() public override {
        super.setUp();

        vm.warp(1);
        stakeToken = new TestToken(address(this));
        vePositions = new VePositions(core, address(this), address(0), 0, 0);
        veGauge = new VeGauge(core, address(this), address(vePositions), address(stakeToken));
        vePositions.setFeeReceiver(address(veGauge));

        token0.approve(address(vePositions), type(uint256).max);
        token1.approve(address(vePositions), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        stakeToken.approve(address(veGauge), type(uint256).max);
    }

    function _deploySingleTokenRewards() internal returns (SingleTokenRewards deployed) {
        CallPoints memory cp = singleTokenRewardsCallPoints();
        address target = address(uint160(cp.toUint8()) << 152);
        deployCodeTo("SingleTokenRewards.sol", abi.encode(core, address(stakeToken), address(vePositions)), target);
        deployed = SingleTokenRewards(target);
    }

    function _createLockAndVote(PoolId poolId) internal returns (uint256 veId) {
        veId = veGauge.createLock(1e18, uint64(block.timestamp + veGauge.MAX_LOCK_DURATION()));

        PoolId[] memory poolIds = new PoolId[](1);
        poolIds[0] = poolId;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        veGauge.vote(veId, poolIds, weights);
    }

    function _createFullRangeVePosition(PoolKey memory poolKey) internal returns (uint256 id, uint128 liquidity) {
        (id, liquidity,,) = vePositions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);
    }

    function test_permissionlessCollectFees_routesFeesToGaugeVoters() public {
        PoolKey memory poolKey = createFullRangePool(0, 1 << 63);
        (uint256 id,) = _createFullRangeVePosition(poolKey);
        uint256 veId = _createLockAndVote(poolKey.toPoolId());

        router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: 1000, _isToken1: false, _skipAhead: 0
            })
        });

        uint256 balanceBefore = token0.balanceOf(address(this));
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vePositions.collectFees(id, poolKey, MIN_TICK, MAX_TICK);

        (uint128 claimed0, uint128 claimed1) = veGauge.claimPoolFees(veId, poolKey);

        assertGt(claimed0 + claimed1, 0);
        assertEq(token0.balanceOf(address(this)), balanceBefore + claimed0);
    }

    function test_depositCollectsExistingFeesBeforeUpdatingPosition() public {
        PoolKey memory poolKey = createFullRangePool(0, 1 << 63);
        (uint256 id,) = _createFullRangeVePosition(poolKey);
        uint256 veId = _createLockAndVote(poolKey.toPoolId());

        router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: 1000, _isToken1: false, _skipAhead: 0
            })
        });

        vePositions.deposit(id, poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);

        (uint128 claimed0, uint128 claimed1) = veGauge.claimPoolFees(veId, poolKey);

        assertGt(claimed0 + claimed1, 0);
    }

    function test_permissionlessEmissionsFundSingleVotedPool() public {
        rewards = _deploySingleTokenRewards();

        PoolKey memory poolKey = createFullRangePool(0, 0, address(rewards));
        _createFullRangeVePosition(poolKey);
        _createLockAndVote(poolKey.toPoolId());

        veGauge.fundEmissions(1e18);
        vm.warp(block.timestamp + 1 days);

        uint224 amount = veGauge.triggerPoolEmissions(poolKey);

        assertGt(amount, 0);
        assertGt(rewards.poolRewardState(poolKey.toPoolId()).rewardRate(), 0);
    }
}
