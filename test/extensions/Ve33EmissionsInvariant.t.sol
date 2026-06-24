// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {StdAssertions} from "forge-std/StdAssertions.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {BaseRouter} from "../../src/base/BaseRouter.sol";
import {Router} from "../../src/Router.sol";
import {Ve33Periphery} from "../../src/Ve33Periphery.sol";
import {Ve33Positions} from "../../src/Ve33Positions.sol";
import {VeToken} from "../../src/VeToken.sol";
import {Ve33, ve33CallPoints} from "../../src/extensions/Ve33.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {Ve33Lib} from "../../src/libraries/Ve33Lib.sol";
import {AmountBeforeFeeOverflow} from "../../src/math/fee.sol";
import {Amount0DeltaOverflow, Amount1DeltaOverflow} from "../../src/math/delta.sol";
import {nextValidTime} from "../../src/math/time.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PositionId} from "../../src/types/positionId.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";

contract Ve33EmissionsInvariantHandler is StdUtils, StdAssertions {
    using CoreLib for *;
    using Ve33Lib for Ve33;

    uint224 private constant EMISSION_RATE_Q32 = uint224(uint256(1e12) << 32);
    uint256 private constant POSITION_AMOUNT = 1e21;
    uint256 private constant REWARD_TOLERANCE = 32;

    struct TrackedPool {
        PoolKey poolKey;
        PoolId poolId;
    }

    struct TrackedPosition {
        uint256 poolIndex;
        uint256 nftId;
        PositionId positionId;
        uint128 liquidity;
        uint256 claimed;
        uint256 maxEarned;
    }

    ICore private immutable core;
    Ve33 private immutable ve33;
    Ve33Positions private immutable ve33Positions;
    Router private immutable router;
    TestToken private immutable token0;
    TestToken private immutable token1;
    Vm private immutable vm;
    uint256 private immutable emissionEnd;

    TrackedPool[] private pools;
    TrackedPosition[] private positions;
    uint256 private lastSynced;
    bool private initialized;

    error UnexpectedError(bytes data);

    constructor(
        ICore _core,
        Ve33 _ve33,
        Ve33Positions _ve33Positions,
        Router _router,
        TestToken _token0,
        TestToken _token1,
        Vm _vm,
        PoolKey memory pool0,
        PoolKey memory pool1,
        uint256 _emissionEnd
    ) {
        core = _core;
        ve33 = _ve33;
        ve33Positions = _ve33Positions;
        router = _router;
        token0 = _token0;
        token1 = _token1;
        vm = _vm;
        emissionEnd = _emissionEnd;

        token0.approve(address(ve33Positions), type(uint256).max);
        token1.approve(address(ve33Positions), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        pools.push(TrackedPool({poolKey: pool0, poolId: pool0.toPoolId()}));
        pools.push(TrackedPool({poolKey: pool1, poolId: pool1.toPoolId()}));
        lastSynced = vm.getBlockTimestamp();
    }

    function initializePositions() external {
        if (initialized) return;
        initialized = true;

        _mintPosition(0, -64, 64);
        _mintPosition(0, 64, 128);
        _mintPosition(0, -128, 128);
        _mintPosition(1, -256, 256);
        _mintPosition(1, 256, 512);
        _mintPosition(1, -512, 512);
    }

    function advanceTime(uint32 by) external {
        if (vm.getBlockTimestamp() >= emissionEnd) return;

        by = uint32(bound(by, 0, 1 days));
        uint256 nextTime = FixedPointMathLib.min(vm.getBlockTimestamp() + by, emissionEnd);
        vm.warp(nextTime);
    }

    function touchPool(uint256 poolIndex) external {
        _syncModel();
        ve33.maybeAccumulateRewards(_pool(poolIndex).poolKey);
    }

    function claimRewards(uint256 positionIndex) external {
        if (positions.length == 0) return;

        _syncModel();
        TrackedPosition storage position = positions[bound(positionIndex, 0, positions.length - 1)];
        TrackedPool memory trackedPool = pools[position.poolIndex];
        uint256 amount = ve33Positions.claimRewards(
            position.nftId,
            trackedPool.poolKey,
            position.positionId.tickLower(),
            position.positionId.tickUpper(),
            address(this)
        );
        position.claimed += amount;
        _assertPositionClaimWithinBound(position);
    }

    function swap(uint256 poolIndex, bool isToken1, int128 amount) external {
        _syncModel();

        PoolKey memory poolKey = _pool(poolIndex).poolKey;
        amount = int128(bound(amount, -int256(1e18), int256(1e18)));
        if (amount == 0) return;

        SwapParameters params = createSwapParameters({
            _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: amount, _isToken1: isToken1, _skipAhead: 0
        });

        try router.swapAllowPartialFill{gas: 15_000_000}(poolKey, params, address(this)) returns (PoolBalanceUpdate) {}
        catch (bytes memory err) {
            bytes4 sig;
            assembly ("memory-safe") {
                sig := mload(add(err, 32))
            }
            if (
                sig != BaseRouter.PartialSwapsDisallowed.selector && sig != Amount0DeltaOverflow.selector
                    && sig != Amount1DeltaOverflow.selector && sig != AmountBeforeFeeOverflow.selector
                    && sig != SafeCastLib.Overflow.selector && sig != SafeTransferLib.TransferFromFailed.selector
                    && sig != 0xffffffff && sig != 0x00000000 && sig != 0x4e487b71
            ) {
                revert UnexpectedError(err);
            }
        }
    }

    function checkNoPositionOverclaimed() external view {
        for (uint256 i = 0; i < positions.length; i++) {
            _assertPositionClaimWithinBound(positions[i]);
        }
    }

    function _mintPosition(uint256 poolIndex, int32 tickLower, int32 tickUpper) private {
        TrackedPool memory trackedPool = pools[poolIndex];
        (uint256 nftId, uint128 liquidity,,) = ve33Positions.mintAndDeposit(
            trackedPool.poolKey, tickLower, tickUpper, uint128(POSITION_AMOUNT), uint128(POSITION_AMOUNT), 1
        );
        positions.push(
            TrackedPosition({
                poolIndex: poolIndex,
                nftId: nftId,
                positionId: ve33Positions.positionId(nftId, tickLower, tickUpper),
                liquidity: liquidity,
                claimed: 0,
                maxEarned: 0
            })
        );
    }

    function _syncModel() private {
        uint256 timestamp = vm.getBlockTimestamp();
        uint256 elapsed = timestamp - lastSynced;
        if (elapsed == 0) return;

        uint256 totalVoteWeight = ve33.totalVoteWeight();
        uint256 emissionRate = ve33.emissionRate();
        if (totalVoteWeight != 0 && emissionRate != 0) {
            uint256 totalEmitted = _mulDivUp(emissionRate, elapsed, 1 << 32);

            for (uint256 poolIndex = 0; poolIndex < pools.length; poolIndex++) {
                PoolId poolId = pools[poolIndex].poolId;
                uint256 poolWeight = ve33.poolTotalWeight(poolId);
                if (poolWeight == 0) continue;

                uint256 activeLiquidity = core.poolState(poolId).liquidity();
                if (activeLiquidity == 0) continue;

                uint256 poolEmitted = _mulDivUp(totalEmitted, poolWeight, totalVoteWeight);
                int32 tick = core.poolState(poolId).tick();

                for (uint256 positionIndex = 0; positionIndex < positions.length; positionIndex++) {
                    TrackedPosition storage position = positions[positionIndex];
                    if (position.poolIndex != poolIndex || !_isActive(position.positionId, tick)) continue;

                    position.maxEarned += _mulDivUp(poolEmitted, position.liquidity, activeLiquidity) + REWARD_TOLERANCE;
                }
            }
        }

        lastSynced = timestamp;
    }

    function _assertPositionClaimWithinBound(TrackedPosition storage position) private view {
        assertLe(position.claimed, position.maxEarned + REWARD_TOLERANCE);
    }

    function _isActive(PositionId positionId, int32 tick) private pure returns (bool) {
        return tick >= positionId.tickLower() && tick < positionId.tickUpper();
    }

    function _pool(uint256 poolIndex) private view returns (TrackedPool storage) {
        return pools[bound(poolIndex, 0, pools.length - 1)];
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 denominator) private pure returns (uint256 result) {
        result = FixedPointMathLib.fullMulDiv(x, y, denominator);
        if (mulmod(x, y, denominator) != 0) result++;
    }
}

contract Ve33EmissionsInvariantTest is FullTest {
    Ve33 internal ve33;
    VeToken internal veToken;
    Ve33Positions internal ve33Positions;
    Ve33Periphery internal periphery;
    TestToken internal stakeToken;
    Ve33EmissionsInvariantHandler internal handler;

    function setUp() public override {
        super.setUp();

        stakeToken = new TestToken(address(this));
        address deployAddress = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("Ve33.sol", abi.encode(core, address(stakeToken)), deployAddress);
        ve33 = Ve33(payable(deployAddress));
        router = new Router(core, address(0), address(ve33));
        veToken = new VeToken(core, ve33);
        ve33Positions = new Ve33Positions(core, ve33, owner);
        periphery = new Ve33Periphery(core, ve33);

        stakeToken.approve(address(veToken), type(uint256).max);
        stakeToken.approve(address(periphery), type(uint256).max);

        PoolKey memory pool0 = createPool({tick: 0, fee: 0, tickSpacing: 64, extension: address(ve33)});
        PoolKey memory pool1 = createPool({tick: 0, fee: 0, tickSpacing: 256, extension: address(ve33)});

        uint64 stakeEnd = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        uint256 veId0 = veToken.createStake(1e18, stakeEnd);
        uint256 veId1 = veToken.createStake(1e18, stakeEnd);
        veToken.vote(veId0, pool0, 0);
        veToken.vote(veId1, pool1, 0);

        uint256 emissionEnd = nextValidTime(vm.getBlockTimestamp(), vm.getBlockTimestamp() + 365 days);
        periphery.scheduleEmissions(0, uint64(emissionEnd), uint224(uint256(1e12) << 32));

        handler = new Ve33EmissionsInvariantHandler(
            core, ve33, ve33Positions, router, token0, token1, vm, pool0, pool1, emissionEnd
        );
        token0.transfer(address(handler), type(uint128).max);
        token1.transfer(address(handler), type(uint128).max);
        handler.initializePositions();

        targetContract(address(handler));

        bytes4[] memory excluded = new bytes4[](2);
        excluded[0] = Ve33EmissionsInvariantHandler.initializePositions.selector;
        excluded[1] = Ve33EmissionsInvariantHandler.checkNoPositionOverclaimed.selector;
        excludeSelector(FuzzSelector(address(handler), excluded));
    }

    function invariant_positionsNeverClaimMoreThanActiveLiquidityShare() public view {
        handler.checkNoPositionOverclaimed();
    }
}
