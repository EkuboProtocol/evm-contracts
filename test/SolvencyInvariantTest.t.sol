// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints, byteToCallPoints} from "../src/types/callPoints.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {Bounds} from "../src/types/positionKey.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {FullTest, MockExtension} from "./FullTest.sol";
import {Router, Delta, RouteNode, TokenAmount, Swap} from "../src/Router.sol";
import {isPriceIncreasing} from "../src/math/swap.sol";
import {Amount0DeltaOverflow, Amount1DeltaOverflow} from "../src/math/delta.sol";
import {MAX_TICK, MIN_TICK, MAX_TICK_SPACING, FULL_RANGE_ONLY_TICK_SPACING} from "../src/math/constants.sol";
import {AmountBeforeFeeOverflow} from "../src/math/fee.sol";
import {SwapParameters} from "../src/interfaces/ICore.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {Positions} from "../src/Positions.sol";
import {TestToken} from "./TestToken.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {LiquidityDeltaOverflow} from "../src/math/liquidity.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";

contract FeeAccumulatingExtension is MockExtension, BaseLocker {
    constructor(ICore core) BaseLocker(core) {}

    function accumulateFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1) external {
        lock(abi.encode(msg.sender, poolKey, amount0, amount1));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (address sender, PoolKey memory poolKey, uint128 amount0, uint128 amount1) =
            abi.decode(data, (address, PoolKey, uint128, uint128));

        ICore(payable(accountant)).accumulateAsFees(poolKey, amount0, amount1);
        pay(sender, poolKey.token0, amount0);
        pay(sender, poolKey.token1, amount1);
    }
}

function maxBounds(uint32 tickSpacing) pure returns (Bounds memory) {
    if (tickSpacing == FULL_RANGE_ONLY_TICK_SPACING) {
        return Bounds(MIN_TICK, MAX_TICK);
    }
    int32 spacing = int32(tickSpacing);

    return Bounds({lower: (MIN_TICK / spacing) * spacing, upper: (MAX_TICK / spacing) * spacing});
}

contract Handler is StdUtils, StdAssertions {
    using CoreLib for *;

    uint256 immutable positionId;

    struct ActivePosition {
        PoolKey poolKey;
        Bounds bounds;
        uint128 liquidity;
    }

    struct Balances {
        int256 amount0;
        int256 amount1;
    }

    ICore immutable core;
    Positions immutable positions;
    Router immutable router;
    TestToken immutable token0;
    TestToken immutable token1;
    FeeAccumulatingExtension immutable fae;
    ActivePosition[] activePositions;
    PoolKey[] allPoolKeys;

    mapping(bytes32 poolId => Balances balances) poolBalances;

    constructor(
        ICore _core,
        FeeAccumulatingExtension _fae,
        Positions _positions,
        Router _router,
        TestToken _token0,
        TestToken _token1
    ) {
        core = _core;
        fae = _fae;
        positions = _positions;
        router = _router;
        token0 = _token0;
        token1 = _token1;
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(fae), type(uint256).max);
        token1.approve(address(fae), type(uint256).max);
        positionId = positions.mint();
    }

    function createNewPool(uint128 fee, uint32 tickSpacing, int32 tick, bool withExtension) public {
        tickSpacing = uint32(bound(tickSpacing, 0, MAX_TICK_SPACING));
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        PoolKey memory poolKey =
            PoolKey(address(token0), address(token1), fee, tickSpacing, withExtension ? address(fae) : address(0));
        (bool initialized, SqrtRatio sqrtRatio) = positions.maybeInitializePool(poolKey, tick);
        assertNotEq(SqrtRatio.unwrap(sqrtRatio), 0);
        if (initialized) allPoolKeys.push(poolKey);
    }

    function withdrawProtocolFees(bool isToken1, uint256 amount) external {
        address token = isToken1 ? address(token1) : address(token0);

        amount = bound(amount, 0, core.protocolFeesCollected(token));
        core.withdrawProtocolFees(address(this), token, amount);
    }

    modifier ifPoolExists() {
        if (allPoolKeys.length == 0) return;
        _;
    }

    error UnexpectedError(bytes4 sig, bytes data);

    function deposit(uint256 poolKeyIndex, uint128 amount0, uint128 amount1, Bounds memory bounds)
        public
        ifPoolExists
    {
        PoolKey memory poolKey = allPoolKeys[bound(poolKeyIndex, 0, allPoolKeys.length - 1)];

        if (poolKey.tickSpacing == FULL_RANGE_ONLY_TICK_SPACING) {
            bounds = Bounds(MIN_TICK, MAX_TICK);
        } else {
            Bounds memory max = maxBounds(poolKey.tickSpacing);
            bounds.lower = int32(bound(bounds.lower, max.lower, max.upper - int32(poolKey.tickSpacing)));
            // snap to nearest valid tick
            bounds.lower = (bounds.lower / int32(poolKey.tickSpacing)) * int32(poolKey.tickSpacing);
            bounds.upper = int32(bound(bounds.upper, bounds.lower + int32(poolKey.tickSpacing), max.upper));
            bounds.upper = (bounds.upper / int32(poolKey.tickSpacing)) * int32(poolKey.tickSpacing);
        }

        try positions.deposit(positionId, poolKey, bounds, amount0, amount1, 0) returns (
            uint128 liquidity, uint128 result0, uint128 result1
        ) {
            if (liquidity > 0) {
                activePositions.push(ActivePosition(poolKey, bounds, liquidity));
            }

            bytes32 poolId = poolKey.toPoolId();
            poolBalances[poolId].amount0 += int256(uint256(result0));
            poolBalances[poolId].amount1 += int256(uint256(result1));
        } catch (bytes memory err) {
            bytes4 sig;
            assembly ("memory-safe") {
                sig := mload(add(err, 32))
            }

            // 0x4e487b71 is arithmetic overflow/underflow
            if (
                sig != Positions.DepositOverflow.selector && sig != SafeCastLib.Overflow.selector && sig != 0x4e487b71
                    && sig != FixedPointMathLib.FullMulDivFailed.selector && sig != LiquidityDeltaOverflow.selector
            ) {
                revert UnexpectedError(sig, err);
            }
        }
    }

    function accumulateFees(uint256 poolKeyIndex, uint128 amount0, uint128 amount1) public ifPoolExists {
        PoolKey memory poolKey = allPoolKeys[bound(poolKeyIndex, 0, allPoolKeys.length - 1)];
        try fae.accumulateFees(poolKey, amount0, amount1) {
            bytes32 poolId = poolKey.toPoolId();
            poolBalances[poolId].amount0 += int256(uint256(amount0));
            poolBalances[poolId].amount1 += int256(uint256(amount1));
        } catch (bytes memory err) {
            if (poolKey.extension != address(fae)) {
                assert(err.length == 0);
            } else {
                bytes4 sig;
                assembly ("memory-safe") {
                    sig := mload(add(err, 32))
                }
                revert UnexpectedError(sig, err);
            }
        }
    }

    function withdraw(uint256 index, uint128 liquidity, bool collectFees) public {
        if (activePositions.length == 0) return;

        ActivePosition storage p = activePositions[bound(index, 0, activePositions.length - 1)];

        liquidity = uint128(bound(liquidity, 0, p.liquidity));

        try positions.withdraw(positionId, p.poolKey, p.bounds, liquidity, address(this), collectFees) returns (
            uint128 amount0, uint128 amount1
        ) {
            bytes32 poolId = p.poolKey.toPoolId();
            poolBalances[poolId].amount0 -= int256(uint256(amount0));
            poolBalances[poolId].amount1 -= int256(uint256(amount1));
            p.liquidity -= liquidity;
        } catch (bytes memory err) {
            bytes4 sig;
            assembly ("memory-safe") {
                sig := mload(add(err, 32))
            }

            if (
                // arithmetic overflow can definitely happen in positions contract if liquidity + fees > uint128
                sig != ICore.MustCollectFeesBeforeWithdrawingAllLiquidity.selector
                    && sig != SafeCastLib.Overflow.selector && sig != Amount1DeltaOverflow.selector
                    && sig != Amount0DeltaOverflow.selector && sig != 0x4e487b71
            ) {
                revert UnexpectedError(sig, err);
            }
        }
    }

    function swap(uint256 poolKeyIndex, SwapParameters memory params) public ifPoolExists {
        PoolKey memory poolKey = allPoolKeys[bound(poolKeyIndex, 0, allPoolKeys.length - 1)];

        // (SqrtRatio price,) = core.poolPrice(poolKey.toPoolId());

        // // params.sqrtRatioLimit = bound(params.sqrtRatioLimit, MIN_SQRT_RATIO, MAX_SQRT_RATIO);

        // if (isPriceIncreasing(params.amount, params.isToken1)) {
        //     // params.sqrtRatioLimit = bound(params.sqrtRatioLimit, price, MAX_SQRT_RATIO);
        // } else {
        //     // params.sqrtRatioLimit = bound(params.sqrtRatioLimit, MIN_SQRT_RATIO, price);
        // }

        params.skipAhead = bound(params.skipAhead, 0, type(uint8).max);

        try router.swap{gas: 15000000}({
            poolKey: poolKey,
            sqrtRatioLimit: params.sqrtRatioLimit,
            skipAhead: params.skipAhead,
            isToken1: params.isToken1,
            amount: params.amount
        }) returns (int128 delta0, int128 delta1) {
            bytes32 poolId = poolKey.toPoolId();
            poolBalances[poolId].amount0 += delta0;
            poolBalances[poolId].amount1 += delta1;
        } catch (bytes memory err) {
            bytes4 sig;
            assembly ("memory-safe") {
                sig := mload(add(err, 32))
            }
            // 0xffffffff and 0x00000000 are evm errors for out of gas
            // 0x4e487b71 is arithmetic overflow/underflow
            if (
                sig != Router.PartialSwapsDisallowed.selector && sig != 0xffffffff && sig != 0x00000000
                    && sig != Amount1DeltaOverflow.selector && sig != Amount0DeltaOverflow.selector
                    && sig != AmountBeforeFeeOverflow.selector && sig != 0x4e487b71 && sig != SafeCastLib.Overflow.selector
            ) {
                revert UnexpectedError(sig, err);
            }
        }
    }

    function checkAllPoolsHavePositiveBalance() public view {
        for (uint256 i = 0; i < allPoolKeys.length; i++) {
            bytes32 poolId = allPoolKeys[i].toPoolId();
            assertGe(poolBalances[poolId].amount0, 0);
            assertGe(poolBalances[poolId].amount1, 0);
        }
    }

    function checkAllPoolsHaveValidPriceAndTick() public view {
        for (uint256 i = 0; i < allPoolKeys.length; i++) {
            PoolKey memory poolKey = allPoolKeys[i];

            (SqrtRatio sqrtRatio, int32 tick) = core.poolPrice(poolKey.toPoolId());

            // assertGe(sqrtRatio, MIN_SQRT_RATIO);
            // assertLe(sqrtRatio, MAX_SQRT_RATIO);
            assertGe(tick, MIN_TICK - 1);
            assertLe(tick, MAX_TICK + 1);
        }
    }
}

contract SolvencyInvariantTest is FullTest {
    Handler handler;

    function setUp() public override {
        FullTest.setUp();

        address impl = address(new FeeAccumulatingExtension(core));
        address actual = address((uint160(0xff) << 152) + 0xdeadbeef);
        vm.etch(actual, impl.code);
        MockExtension(actual).register(core, byteToCallPoints(0xff));
        FeeAccumulatingExtension fae = FeeAccumulatingExtension(actual);

        handler = new Handler(core, fae, positions, router, token0, token1);
        vm.prank(owner);
        core.transferOwnership(address(handler));
        vm.stopPrank();

        // funding core makes it easier for pools to become insolvent randomly if there is a bug
        token0.transfer(address(core), type(uint128).max);
        token1.transfer(address(core), type(uint128).max);
        token0.transfer(address(handler), type(uint256).max - type(uint128).max);
        token1.transfer(address(handler), type(uint256).max - type(uint128).max);

        targetContract(address(handler));
    }

    function invariant_allPoolsHaveValidStates() public view {
        handler.checkAllPoolsHavePositiveBalance();
        handler.checkAllPoolsHaveValidPriceAndTick();
    }
}
