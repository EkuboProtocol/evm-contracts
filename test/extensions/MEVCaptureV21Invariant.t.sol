// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MEVCaptureV21Base} from "./MEVCaptureV21Base.sol";
import {V21Ref} from "./MEVCaptureV21Helpers.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {ExposedStorageLib} from "../../src/libraries/ExposedStorageLib.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";

/// @notice Stateful handler: random swaps (both directions, exact in/out, limits, minFee), position adds/removes and
///   time steps on a v2.1 pool. Every swap is checked against the reference model on the twin pool (deltas, state,
///   Core call sequence, gate event, extension state); the handler also tracks ghost invariants across calls.
contract V21Handler is MEVCaptureV21Base {
    using CoreLib for *;
    using ExposedStorageLib for *;

    int32 internal constant S = 4096;

    struct Pos {
        bytes24 salt;
        int32 lo;
        int32 hi;
        int128 liquidity;
    }

    Pos[] internal positionsList;
    uint256 public swaps;
    uint256 public gateFailures;
    uint256 public anchorMovesSameTimestamp;
    uint256 public fastRaises;

    function init() external {
        setUp();
        createPools(196, 12, 0);
        _addPosition(-40 * S, 40 * S, int128(1) << 66);
    }

    function _addPosition(int32 lo, int32 hi, int128 liquidity) internal {
        bytes24 salt = bytes24(uint192(positionsList.length + 1));
        _lp(salt, lo, hi, liquidity);
        positionsList.push(Pos(salt, lo, hi, liquidity));
    }

    function swap(uint256 r) external {
        bool isToken1 = r & 1 == 1;
        bool exactOut = (r >> 1) & 1 == 1;
        bool increasing = isToken1 != exactOut;
        int128 amount = int128(uint128(1 + (r >> 8) % 1e21));
        if (exactOut) amount = -amount;
        int256 dist = int256(1 + (r >> 80) % (60 * uint256(int256(S))));
        int256 cur = _poolState().tick();
        int256 lt = cur + (increasing ? dist : -dist);
        if (lt <= -500 * S || lt >= 500 * S) return;
        uint16 minFee = (r >> 120) % 5 == 0 ? uint16((r >> 130) % 800) : 0;

        V21Ref.State memory before = _state(pool);
        _swapChecked(isToken1, amount, tickToSqrtRatio(int32(lt)), minFee);
        V21Ref.State memory afterS = _state(pool);
        swaps++;
        if (lastGateFailed) gateFailures++;
        if (!lastWasFirst && afterS.anchorX16 != before.anchorX16) anchorMovesSameTimestamp++;
        if (afterS.lRefBits > before.lRefBits) {
            unchecked {
                if (uint32(afterS.raiseTime - before.raiseTime) < cfg.tau) fastRaises++;
            }
            if (afterS.lRefBits > before.lRefBits + 1) fastRaises++;
        }
    }

    function addLiquidity(uint256 r) external {
        if (positionsList.length >= 12) return;
        int32 lo = int32(int256(r % 80) - 40) * S;
        int32 hi = lo + int32(int256(1 + (r >> 8) % 20)) * S;
        int128 liq = int128(uint128(1e9 + (r >> 16) % (uint256(1) << 72)));
        _addPosition(lo, hi, liq);
    }

    function removeLiquidity(uint256 r) external {
        if (positionsList.length == 0) return;
        uint256 i = r % positionsList.length;
        Pos memory p = positionsList[i];
        if (p.liquidity == 0) return;
        int128 delta = int128(uint128(1 + (r >> 16) % uint128(p.liquidity)));
        _lp(p.salt, p.lo, p.hi, -delta);
        positionsList[i].liquidity -= delta;
    }

    function warp(uint256 r) external {
        uint256 sel = r % 4;
        if (sel == 0) advanceTime(1 + (r >> 8) % 12);
        else if (sel == 1) advanceTime(12);
        else if (sel == 2) advanceTime(60 + (r >> 8) % 120);
        else advanceTime((r >> 8) % 7200);
    }

    function stateWord() external view returns (bytes32) {
        return v21.sload(PoolId.unwrap(pool.toPoolId()));
    }
}

contract MEVCaptureV21InvariantTest is Test {
    V21Handler internal h;

    function setUp() public {
        h = new V21Handler();
        h.init();
        targetContract(address(h));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = V21Handler.swap.selector;
        selectors[1] = V21Handler.addLiquidity.selector;
        selectors[2] = V21Handler.removeLiquidity.selector;
        selectors[3] = V21Handler.warp.selector;
        targetSelector(StdInvariant.FuzzSelector({addr: address(h), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 24
    /// @notice Invariant 1: the anchor never moves except on the first swap of a timestamp
    function invariant_anchor_only_on_first_swap() public view {
        assertEq(h.anchorMovesSameTimestamp(), 0);
    }

    /// forge-config: default.invariant.runs = 24
    /// @notice H1: the reference rises by at most one bit per tau
    function invariant_reference_rises_at_most_one_bit_per_tau() public view {
        assertEq(h.fastRaises(), 0);
    }

    /// forge-config: default.invariant.runs = 24
    /// @notice Layout: reserved bits stay zero
    function invariant_reserved_bits_zero() public view {
        assertEq(uint256(h.stateWord()) & (((uint256(1) << 48) - 1) << 64), 0);
    }

    function afterInvariant() public view {
        // the run must have exercised checked swaps
        assertGt(h.swaps(), 0);
    }
}
