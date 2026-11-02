// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolState} from "../src/types/poolState.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {FeesPerLiquidity} from "../src/types/feesPerLiquidity.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {SwapParameters, createSwapParameters} from "../src/types/swapParameters.sol";

/// @notice Minimal locker that swaps with a minimum fee and settles both sides.
contract MinimumFeeSwapper is BaseLocker {
    using CoreLib for *;
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function swap(PoolKey memory poolKey, SwapParameters params, uint16 minimumFee, address payer)
        external
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        (balanceUpdate, stateAfter) =
            abi.decode(lock(abi.encode(poolKey, params, minimumFee, payer)), (PoolBalanceUpdate, PoolState));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        (PoolKey memory poolKey, SwapParameters params, uint16 minimumFee, address payer) =
            abi.decode(data, (PoolKey, SwapParameters, uint16, address));

        (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) =
            ICore(payable(address(ACCOUNTANT))).swap(0, poolKey, params.withMinFee(minimumFee));

        if (balanceUpdate.delta0() > 0) {
            ACCOUNTANT.payFrom(payer, poolKey.token0, uint128(balanceUpdate.delta0()));
        } else if (balanceUpdate.delta0() < 0) {
            ACCOUNTANT.withdraw(poolKey.token0, payer, uint128(-balanceUpdate.delta0()));
        }

        if (balanceUpdate.delta1() > 0) {
            ACCOUNTANT.payFrom(payer, poolKey.token1, uint128(balanceUpdate.delta1()));
        } else if (balanceUpdate.delta1() < 0) {
            ACCOUNTANT.withdraw(poolKey.token1, payer, uint128(-balanceUpdate.delta1()));
        }

        result = abi.encode(balanceUpdate, stateAfter);
    }
}

contract MinimumFeeTest is FullTest {
    using CoreLib for *;

    // 0.3% as a 0.16 number
    uint16 internal constant THREE_BIPS = uint16((uint256(3) << 16) / 1000);

    /// @dev `initializePool` seeds both fees-per-liquidity slots with 1
    uint256 internal constant INITIAL_FEES_PER_LIQUIDITY = 1;

    MinimumFeeSwapper internal swapper;

    function setUp() public override {
        FullTest.setUp();
        swapper = new MinimumFeeSwapper(core);
        token0.approve(address(swapper), type(uint256).max);
        token1.approve(address(swapper), type(uint256).max);
    }

    struct SwapOutcome {
        PoolBalanceUpdate balanceUpdate;
        SqrtRatio sqrtRatioAfter;
        FeesPerLiquidity feesPerLiquidity;
    }

    /// @dev Runs against a freshly created pool and rolls the chain back afterwards, so callers can
    /// compare independent fee configurations without the pools colliding on their pool id.
    function swapOnce(uint16 poolFee, uint16 minimumFee, int128 amount, bool isToken1)
        internal
        returns (SwapOutcome memory outcome)
    {
        uint256 snapshot = vm.snapshotState();

        PoolKey memory poolKey = createPool(0, poolFee, 5);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        (outcome.balanceUpdate,) = swapper.swap(
            poolKey,
            createSwapParameters({
                _isToken1: isToken1, _amount: amount, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0, _minFee: 0
            }).withDefaultSqrtRatioLimit(),
            minimumFee,
            address(this)
        );

        PoolId poolId = poolKey.toPoolId();
        outcome.sqrtRatioAfter = core.poolState(poolId).sqrtRatio();
        outcome.feesPerLiquidity = core.getPoolFeesPerLiquidity(poolId);

        vm.revertToState(snapshot);
    }

    function assertSameOutcome(SwapOutcome memory a, SwapOutcome memory b) internal pure {
        assertEq(a.balanceUpdate.delta0(), b.balanceUpdate.delta0(), "delta0");
        assertEq(a.balanceUpdate.delta1(), b.balanceUpdate.delta1(), "delta1");
        assertEq(SqrtRatio.unwrap(a.sqrtRatioAfter), SqrtRatio.unwrap(b.sqrtRatioAfter), "sqrtRatio");
        assertEq(a.feesPerLiquidity.value0, b.feesPerLiquidity.value0, "feesPerLiquidity0");
        assertEq(a.feesPerLiquidity.value1, b.feesPerLiquidity.value1, "feesPerLiquidity1");
    }

    /// @dev Paying a minimum fee of `f` has to be indistinguishable from swapping a pool whose own
    /// fee is `f`, however the two are arranged.
    function test_minimum_fee_is_equivalent_to_pool_fee(uint16 fee, int128 amount, bool isToken1) public {
        amount = int128(bound(amount, -100_000, 100_000));
        vm.assume(amount != 0);

        SwapOutcome memory poolFeeOnly = swapOnce({poolFee: fee, minimumFee: 0, amount: amount, isToken1: isToken1});

        assertSameOutcome(poolFeeOnly, swapOnce({poolFee: 0, minimumFee: fee, amount: amount, isToken1: isToken1}));

        // the larger of the two wins, from either side
        assertSameOutcome(
            poolFeeOnly, swapOnce({poolFee: fee / 2, minimumFee: fee, amount: amount, isToken1: isToken1})
        );
        assertSameOutcome(
            poolFeeOnly, swapOnce({poolFee: fee, minimumFee: fee / 2, amount: amount, isToken1: isToken1})
        );
    }

    /// @dev The caller's number is a floor, not an increment, so a minimum under the pool's own fee
    /// changes nothing and can never be stacked into a larger charge.
    function test_minimum_fee_below_pool_fee_is_a_noop(uint16 minimumFee, int128 amount, bool isToken1) public {
        minimumFee = uint16(bound(minimumFee, 0, THREE_BIPS));
        amount = int128(bound(amount, -100_000, 100_000));
        vm.assume(amount != 0);

        assertSameOutcome(
            swapOnce({poolFee: THREE_BIPS, minimumFee: 0, amount: amount, isToken1: isToken1}),
            swapOnce({poolFee: THREE_BIPS, minimumFee: minimumFee, amount: amount, isToken1: isToken1})
        );
    }

    function test_minimum_fee_accrues_to_liquidity_providers() public {
        SwapOutcome memory withoutFee = swapOnce({poolFee: 0, minimumFee: 0, amount: 10_000, isToken1: false});
        SwapOutcome memory withFee = swapOnce({poolFee: 0, minimumFee: THREE_BIPS, amount: 10_000, isToken1: false});

        // exact input, so the swapper pays the same amount in and receives strictly less out
        assertEq(withFee.balanceUpdate.delta0(), 10_000);
        assertGt(withFee.balanceUpdate.delta1(), withoutFee.balanceUpdate.delta1());

        // the difference is credited to the LPs in the input token
        assertEq(withoutFee.feesPerLiquidity.value0, INITIAL_FEES_PER_LIQUIDITY);
        assertGt(withFee.feesPerLiquidity.value0, INITIAL_FEES_PER_LIQUIDITY);
        assertEq(withFee.feesPerLiquidity.value1, INITIAL_FEES_PER_LIQUIDITY);
    }

    function test_minimum_fee_on_exact_output_increases_the_input() public {
        SwapOutcome memory withoutFee = swapOnce({poolFee: 0, minimumFee: 0, amount: -10_000, isToken1: false});
        SwapOutcome memory withFee = swapOnce({poolFee: 0, minimumFee: THREE_BIPS, amount: -10_000, isToken1: false});

        // exact output, so the swapper receives the same amount out and pays strictly more in
        assertEq(withFee.balanceUpdate.delta0(), -10_000);
        assertGt(withFee.balanceUpdate.delta1(), withoutFee.balanceUpdate.delta1());

        assertEq(withoutFee.feesPerLiquidity.value1, INITIAL_FEES_PER_LIQUIDITY);
        assertGt(withFee.feesPerLiquidity.value1, INITIAL_FEES_PER_LIQUIDITY);
    }

    /// @dev The minimum fee is a 16-bit field, so any representable value is a valid fee and no
    /// range check is needed. This pins that `withMinFee` round-trips through the parameters.
    function test_min_fee_round_trips_through_params(uint16 minimumFee, int128 amount, bool isToken1) public {
        amount = int128(bound(amount, -100_000, 100_000));
        vm.assume(amount != 0);

        SwapParameters params = createSwapParameters({
            _isToken1: isToken1, _amount: amount, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0, _minFee: 0
        }).withMinFee(minimumFee);
        assertEq(params.minFee(), minimumFee);
    }
}
