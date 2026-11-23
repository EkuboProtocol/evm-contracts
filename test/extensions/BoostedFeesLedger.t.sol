// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {BoostedFees, boostedFeesCallPoints} from "../../src/extensions/BoostedFees.sol";
import {ManualPoolBooster} from "../../src/ManualPoolBooster.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {CallPoints} from "../../src/types/callPoints.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {createSwapParameters} from "../../src/types/swapParameters.sol";
import {BoostedFeesLib} from "../../src/libraries/BoostedFeesLib.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {MAX_ABS_VALUE_SALE_RATE_DELTA, nextValidTime} from "../../src/math/time.sol";

/// @notice Runs random sequences of boosts, time jumps and accruals over two pools of one token pair and compares
///   the extension with a ledger that keeps every boost as a plain record
/// @dev The ledger has no bitmap and no rate deltas. It recomputes what each accrual donates from the list of boosts,
///   so it shares only the rules with the extension: a boost is paid for rounded up, and each stretch of time over
///   which a pool's total rates do not change donates its amount rounded down.
contract BoostedFeesLedgerTest is FullTest {
    using BoostedFeesLib for *;
    using CoreLib for *;

    /// @dev `from` is the later of the requested start and the time the boost was made
    struct Boost {
        uint256 pool;
        uint256 from;
        uint256 to;
        uint256 rate0;
        uint256 rate1;
    }

    uint256 internal constant POOLS = 2;
    uint256 internal constant STEPS = 24;

    BoostedFees internal boostedFees;
    ManualPoolBooster internal periphery;

    PoolKey[POOLS] internal poolKeys;
    uint256[POOLS] internal positionIds;
    int32[POOLS] internal tickRadius;

    Boost[] internal boosts;
    /// @dev the time through which each pool's boosts have been donated
    uint256[POOLS] internal accruedThrough;
    /// @dev what the boosters paid in, by token
    uint256[2] internal funded;
    /// @dev what the pools were donated, by token, and by pool and token
    uint256[2] internal donated;
    uint256[2][POOLS] internal donatedTo;
    /// @dev what the one position of each pool collected, by pool and token
    uint256[2][POOLS] internal collected;
    /// @dev each donation and each collection can round one unit of each token away from the position
    uint256[POOLS] internal roundings;
    /// @dev the number of stretches of time that the ledger donated separately
    uint256 internal segments;

    function setUp() public override {
        super.setUp();

        CallPoints memory callPoints = boostedFeesCallPoints(true);
        address target = address(uint160(callPoints.toUint8()) << 152);
        deployCodeTo("BoostedFees.sol", abi.encode(core, true), target);
        boostedFees = BoostedFees(target);
        periphery = new ManualPoolBooster(core);

        token0.approve(address(periphery), type(uint256).max);
        token1.approve(address(periphery), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
    }

    function test_fuzz_boosts_and_accruals_match_ledger(uint256 seed) public {
        _start(seed);

        for (uint256 i = 0; i < STEPS; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 pool = (r >> 8) % POOLS;

            if (r % 4 != 0) _jump(r >> 16);

            uint256 action = (r >> 12) % 8;
            if (action < 4) {
                _boost(pool, r >> 80);
            } else if (action < 6) {
                boostedFees.maybeAccumulateFees(poolKeys[pool]);
                _accrue(pool);
            } else if (action == 6) {
                _collect(pool);
            } else {
                // the pools charge no swap fee and the input is enough to move the price, so the swap adds nothing
                // to what the position collects. An input too small to move the price is all credited as a fee.
                router.swapAllowPartialFill({
                    poolKey: poolKeys[pool],
                    params: createSwapParameters({
                        _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: 1e12, _isToken1: (r >> 80) % 2 == 0, _skipAhead: 0
                    })
                });
                _accrue(pool);
            }

            _assertMatchesLedger(pool);
        }

        // every boost ends
        uint256 last = vm.getBlockTimestamp();
        for (uint256 i = 0; i < boosts.length; i++) {
            if (boosts[i].to > last) last = boosts[i].to;
        }
        vm.warp(last + 1 + (seed % 512));

        for (uint256 pool = 0; pool < POOLS; pool++) {
            _collect(pool);
            _assertMatchesLedger(pool);

            (, uint112 rate0, uint112 rate1) = boostedFees.poolState(poolKeys[pool].toPoolId()).parse();
            assertEq(rate0, 0, "rate0 returns to zero");
            assertEq(rate1, 0, "rate1 returns to zero");

            for (uint256 token = 0; token < 2; token++) {
                assertLe(collected[pool][token], donatedTo[pool][token], "position collects no more than donated");
                assertLe(
                    donatedTo[pool][token] - collected[pool][token], roundings[pool], "position collects the donations"
                );
            }

            // the position, which is all of the pool's liquidity, can still leave
            uint128 liquidity = core.poolState(poolKeys[pool].toPoolId()).liquidity();
            positions.withdraw(positionIds[pool], poolKeys[pool], -tickRadius[pool], tickRadius[pool], liquidity);
        }

        // rounding up once per boost and down once per stretch is all that stays behind
        (uint128 saved0, uint128 saved1) = _saved();
        assertLe(saved0, boosts.length + segments, "token0 left behind is dust");
        assertLe(saved1, boosts.length + segments, "token1 left behind is dust");
    }

    /// @dev Starts below, across or far above the 32-bit boundary of the stored accrual time
    function _start(uint256 seed) internal {
        uint256 r = uint256(keccak256(abi.encode(seed, "start")));
        uint256 time;
        if (r % 3 == 0) {
            time = _bound(r >> 8, 1, 1 << 20);
        } else if (r % 3 == 1) {
            time = _bound(r >> 8, (1 << 32) - (1 << 21), (1 << 32) + (1 << 10));
        } else {
            time = _bound(r >> 8, 1 << 33, 1 << 60);
        }
        vm.warp(time);

        for (uint256 pool = 0; pool < POOLS; pool++) {
            tickRadius[pool] = int32(uint32(100 * (pool + 1)));
            poolKeys[pool] =
                createPool({tick: 0, fee: 0, tickSpacing: uint32(tickRadius[pool]), extension: address(boostedFees)});
            (positionIds[pool],) = createPosition(poolKeys[pool], -tickRadius[pool], tickRadius[pool], 1e18, 1e18);
            accruedThrough[pool] = time;
        }
    }

    function _jump(uint256 r) internal {
        uint256 time = vm.getBlockTimestamp();
        uint256 kind = r % 6;
        uint256 size = r >> 8;

        if (kind == 0) {
            // the next time a boost can start or end at
            time = (time | 255) + 1;
        } else if (kind == 1) {
            // exactly the next time at which some boost starts or ends
            uint256 next = type(uint256).max;
            for (uint256 pool = 0; pool < POOLS; pool++) {
                next = _nextBoundary(pool, time, next);
            }
            time = next == type(uint256).max ? time + 256 : next;
        } else if (kind == 2) {
            time += _bound(size, 256, (1 << 16) - 1);
        } else if (kind == 3) {
            time += _bound(size, 1 << 16, 1 << 22);
        } else {
            time += _bound(size, 1, 255);
        }

        vm.warp(time);
    }

    function _boost(uint256 pool, uint256 r) internal {
        uint256 time = vm.getBlockTimestamp();

        uint112 rate0 = _rate(r >> 88);
        uint112 rate1 = _rate(r >> 152);

        uint256 start;
        uint256 startKind = r % 6;
        if (startKind == 1) {
            // some earlier time
            start = (time - _bound(r >> 8, 0, time)) & ~uint256(255);
        } else if (startKind == 2) {
            // this very second, when a boost can start at it
            start = time % 256 == 0 ? time : 0;
        } else if (startKind == 3) {
            // where the pool's latest boost ends, at the same rates, so that the pool's total rates do not change
            // there. Not if that is so far ahead that the new boost could not end at a valid time.
            for (uint256 i = boosts.length; i != 0; i--) {
                Boost storage b = boosts[i - 1];
                if (b.pool != pool) continue;
                if (b.to > time && b.to - time <= 1 << 30) {
                    (start, rate0, rate1) = (b.to, uint112(b.rate0), uint112(b.rate1));
                }
                break;
            }
        } else if (startKind > 3) {
            start = nextValidTime(time, time + _delay(r >> 8));
        }

        uint256 from = start > time ? start : time;
        uint256 end = nextValidTime(time, from + _delay(r >> 48));

        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));

        (uint112 amount0, uint112 amount1) = periphery.boost(poolKeys[pool], uint64(start), uint64(end), rate0, rate1);

        // the pool is brought up to date before the boost is added to it
        _accrue(pool);
        boosts.push(Boost({pool: pool, from: from, to: end, rate0: rate0, rate1: rate1}));

        uint256 cost0 = (uint256(rate0) * (end - from) + (1 << 32) - 1) / (1 << 32);
        uint256 cost1 = (uint256(rate1) * (end - from) + (1 << 32) - 1) / (1 << 32);
        funded[0] += cost0;
        funded[1] += cost1;

        assertEq(amount0, cost0, "token0 cost of the boost");
        assertEq(amount1, cost1, "token1 cost of the boost");
        assertEq(balance0 - token0.balanceOf(address(this)), cost0, "token0 paid by the booster");
        assertEq(balance1 - token1.balanceOf(address(this)), cost1, "token1 paid by the booster");
    }

    function _collect(uint256 pool) internal {
        (uint128 amount0, uint128 amount1) =
            positions.collectFees(positionIds[pool], poolKeys[pool], -tickRadius[pool], tickRadius[pool]);
        _accrue(pool);

        collected[pool][0] += amount0;
        collected[pool][1] += amount1;
        roundings[pool]++;
    }

    /// @dev Short, medium and long delays, so that boosts start and end on every spacing of valid times
    function _delay(uint256 r) internal pure returns (uint256) {
        uint256 kind = r % 4;
        uint256 size = (r >> 8) & type(uint32).max;
        if (kind == 0) return size % 4096;
        if (kind == 1) return 4096 + size % (1 << 16);
        if (kind == 2) return (1 << 16) + size % (1 << 20);
        return (1 << 20) + size % (1 << 29);
    }

    /// @dev None, less than one unit per second, ordinary and large. Small enough that no sum of them is refused.
    function _rate(uint256 r) internal pure returns (uint112) {
        uint256 kind = r % 4;
        uint256 size = (r >> 8) & type(uint56).max;
        if (kind == 0) return 0;
        if (kind == 1) return uint112(1 + size % ((1 << 32) - 1));
        if (kind == 2) return uint112((1 << 32) + size);
        return uint112(MAX_ABS_VALUE_SALE_RATE_DELTA / 64 - size);
    }

    /// @dev Donates, in the ledger, what the pool's boosts streamed since the pool was last accrued
    function _accrue(uint256 pool) internal {
        uint256 end = vm.getBlockTimestamp();
        uint256 time = accruedThrough[pool];
        if (time == end) return;

        uint256 total0;
        uint256 total1;
        while (time < end) {
            (uint256 rate0, uint256 rate1) = _rates(pool, time);

            // a stretch ends where the pool's total rate of either token changes. A boost that ends where an equal
            // one starts changes neither, and the stretch runs on through that time.
            uint256 next = time;
            do {
                next = _nextBoundary(pool, next, end);
            } while (next < end && !_ratesChangeAt(pool, next));

            total0 += (rate0 * (next - time)) / (1 << 32);
            total1 += (rate1 * (next - time)) / (1 << 32);
            segments++;
            time = next;
        }

        accruedThrough[pool] = end;
        donated[0] += total0;
        donated[1] += total1;
        donatedTo[pool][0] += total0;
        donatedTo[pool][1] += total1;
        roundings[pool]++;
    }

    /// @dev The pool's total rates at `time`: every boost that has started and not ended
    function _rates(uint256 pool, uint256 time) internal view returns (uint256 rate0, uint256 rate1) {
        for (uint256 i = 0; i < boosts.length; i++) {
            Boost storage b = boosts[i];
            if (b.pool == pool && b.from <= time && time < b.to) {
                rate0 += b.rate0;
                rate1 += b.rate1;
            }
        }
    }

    /// @dev The earliest start or end of one of the pool's boosts after `time`, or `limit` if none is before it
    function _nextBoundary(uint256 pool, uint256 time, uint256 limit) internal view returns (uint256 next) {
        next = limit;
        for (uint256 i = 0; i < boosts.length; i++) {
            Boost storage b = boosts[i];
            if (b.pool != pool) continue;
            if (b.from > time && b.from < next) next = b.from;
            if (b.to > time && b.to < next) next = b.to;
        }
    }

    /// @dev Whether the boosts of the pool that start at `time` and those that end at it differ in either token
    function _ratesChangeAt(uint256 pool, uint256 time) internal view returns (bool) {
        int256 change0;
        int256 change1;
        for (uint256 i = 0; i < boosts.length; i++) {
            Boost storage b = boosts[i];
            if (b.pool != pool) continue;
            if (b.from == time) {
                change0 += int256(b.rate0);
                change1 += int256(b.rate1);
            }
            if (b.to == time) {
                change0 -= int256(b.rate0);
                change1 -= int256(b.rate1);
            }
        }
        return change0 != 0 || change1 != 0;
    }

    function _saved() internal view returns (uint128 saved0, uint128 saved1) {
        (saved0, saved1) = core.savedBalances(address(boostedFees), address(token0), address(token1), bytes32(0));
    }

    /// @dev The extension holds exactly what was paid in and not yet donated, and the pool that was just touched is
    ///   accrued to this second at the total rates of its running boosts
    function _assertMatchesLedger(uint256 pool) internal view {
        (uint128 saved0, uint128 saved1) = _saved();
        assertEq(saved0, funded[0] - donated[0], "token0 held for the boosts");
        assertEq(saved1, funded[1] - donated[1], "token1 held for the boosts");

        uint256 time = vm.getBlockTimestamp();
        (uint256 expected0, uint256 expected1) = _rates(pool, time);
        (uint32 lastAccrued, uint112 rate0, uint112 rate1) = boostedFees.poolState(poolKeys[pool].toPoolId()).parse();
        assertEq(lastAccrued, uint32(time), "accrued to this second");
        assertEq(rate0, expected0, "rate0 of the running boosts");
        assertEq(rate1, expected1, "rate1 of the running boosts");
    }
}
