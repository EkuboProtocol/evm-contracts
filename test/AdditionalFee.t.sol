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

/// @notice Minimal locker that swaps with an additional fee and settles both sides.
contract AdditionalFeeSwapper is BaseLocker {
    using CoreLib for *;
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function swap(PoolKey memory poolKey, SwapParameters params, uint64 additionalFee, address payer)
        external
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        (balanceUpdate, stateAfter) = swap(poolKey, params, additionalFee, payer, false);
    }

    /// @param alwaysSendFeeWord Sends the trailing additional-fee word even when it is zero, which
    /// `CoreLib` otherwise omits
    function swap(
        PoolKey memory poolKey,
        SwapParameters params,
        uint64 additionalFee,
        address payer,
        bool alwaysSendFeeWord
    ) public returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) {
        (balanceUpdate, stateAfter) = abi.decode(
            lock(abi.encode(poolKey, params, additionalFee, payer, alwaysSendFeeWord)), (PoolBalanceUpdate, PoolState)
        );
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        (PoolKey memory poolKey, SwapParameters params, uint64 additionalFee, address payer, bool alwaysSendFeeWord) =
            abi.decode(data, (PoolKey, SwapParameters, uint64, address, bool));

        PoolBalanceUpdate balanceUpdate;
        PoolState stateAfter;
        if (alwaysSendFeeWord) {
            (balanceUpdate, stateAfter) = _swapWithFeeWord(address(ACCOUNTANT), poolKey, params, additionalFee);
        } else {
            (balanceUpdate, stateAfter) = ICore(payable(address(ACCOUNTANT))).swap(0, poolKey, params, additionalFee);
        }

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

    function _swapWithFeeWord(address core, PoolKey memory poolKey, SwapParameters params, uint64 additionalFee)
        private
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        assembly ("memory-safe") {
            let free := mload(0x40)
            mstore(free, 0)
            mcopy(add(free, 4), poolKey, 96)
            mstore(add(free, 100), params)
            mstore(add(free, 132), additionalFee)

            if iszero(call(gas(), core, 0, free, 164, free, 64)) {
                returndatacopy(free, 0, returndatasize())
                revert(free, returndatasize())
            }

            balanceUpdate := mload(free)
            stateAfter := mload(add(free, 32))
        }
    }
}

contract AdditionalFeeTest is FullTest {
    using CoreLib for *;

    // 0.3% as a 0.64 number
    uint64 internal constant THREE_BIPS = uint64((uint256(3) << 64) / 1000);

    /// @dev `initializePool` seeds both fees-per-liquidity slots with 1
    uint256 internal constant INITIAL_FEES_PER_LIQUIDITY = 1;

    AdditionalFeeSwapper internal swapper;

    function setUp() public override {
        FullTest.setUp();
        swapper = new AdditionalFeeSwapper(core);
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
    function swapOnce(uint64 poolFee, uint64 additionalFee, int128 amount, bool isToken1)
        internal
        returns (SwapOutcome memory outcome)
    {
        uint256 snapshot = vm.snapshotState();

        PoolKey memory poolKey = createPool(0, poolFee, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        (outcome.balanceUpdate,) = swapper.swap(
            poolKey,
            createSwapParameters({
                _isToken1: isToken1, _amount: amount, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit(),
            additionalFee,
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

    function test_additional_fee_is_equivalent_to_pool_fee(uint64 fee, int128 amount, bool isToken1) public {
        // the fee is halved below, so cap it well under 100%
        fee = uint64(bound(fee, 0, type(uint64).max / 4));
        amount = int128(bound(amount, -100_000, 100_000));
        vm.assume(amount != 0);

        assertSameOutcome(
            swapOnce({poolFee: fee, additionalFee: 0, amount: amount, isToken1: isToken1}),
            swapOnce({poolFee: 0, additionalFee: fee, amount: amount, isToken1: isToken1})
        );

        // and the two compose additively
        assertSameOutcome(
            swapOnce({poolFee: fee, additionalFee: 0, amount: amount, isToken1: isToken1}),
            swapOnce({poolFee: fee / 2, additionalFee: fee - fee / 2, amount: amount, isToken1: isToken1})
        );
    }

    function test_additional_fee_accrues_to_liquidity_providers() public {
        SwapOutcome memory withoutFee = swapOnce({poolFee: 0, additionalFee: 0, amount: 10_000, isToken1: false});
        SwapOutcome memory withFee = swapOnce({poolFee: 0, additionalFee: THREE_BIPS, amount: 10_000, isToken1: false});

        // exact input, so the swapper pays the same amount in and receives strictly less out
        assertEq(withFee.balanceUpdate.delta0(), 10_000);
        assertGt(withFee.balanceUpdate.delta1(), withoutFee.balanceUpdate.delta1());

        // the difference is credited to the LPs in the input token
        assertEq(withoutFee.feesPerLiquidity.value0, INITIAL_FEES_PER_LIQUIDITY);
        assertGt(withFee.feesPerLiquidity.value0, INITIAL_FEES_PER_LIQUIDITY);
        assertEq(withFee.feesPerLiquidity.value1, INITIAL_FEES_PER_LIQUIDITY);
    }

    function test_additional_fee_on_exact_output_increases_the_input() public {
        SwapOutcome memory withoutFee = swapOnce({poolFee: 0, additionalFee: 0, amount: -10_000, isToken1: false});
        SwapOutcome memory withFee = swapOnce({poolFee: 0, additionalFee: THREE_BIPS, amount: -10_000, isToken1: false});

        // exact output, so the swapper receives the same amount out and pays strictly more in
        assertEq(withFee.balanceUpdate.delta0(), -10_000);
        assertGt(withFee.balanceUpdate.delta1(), withoutFee.balanceUpdate.delta1());

        assertEq(withoutFee.feesPerLiquidity.value1, INITIAL_FEES_PER_LIQUIDITY);
        assertGt(withFee.feesPerLiquidity.value1, INITIAL_FEES_PER_LIQUIDITY);
    }

    function test_revert_additional_fee_overflows_pool_fee(uint64 poolFee, uint64 additionalFee) public {
        poolFee = uint64(bound(poolFee, 1, type(uint64).max));
        unchecked {
            additionalFee = uint64(bound(additionalFee, type(uint64).max - poolFee + 1, type(uint64).max));
        }

        PoolKey memory poolKey = createPool(0, poolFee, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        vm.expectRevert(ICore.FeeTooLarge.selector);
        swapper.swap(
            poolKey,
            createSwapParameters({
                _isToken1: false, _amount: 1_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit(),
            additionalFee,
            address(this)
        );
    }

    /// @dev The additional fee is a trailing calldata word, so a caller that omits it entirely must
    /// be treated as having passed zero. This is what keeps every pre-existing caller working.
    function test_omitted_additional_fee_word_is_zero(int128 amount, bool isToken1) public {
        amount = int128(bound(amount, -100_000, 100_000));
        vm.assume(amount != 0);

        SwapParameters params = createSwapParameters({
            _isToken1: isToken1, _amount: amount, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
        }).withDefaultSqrtRatioLimit();

        uint256 snapshot = vm.snapshotState();

        PoolKey memory poolKey = createPool(0, THREE_BIPS, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);
        (PoolBalanceUpdate omitted,) = swapper.swap(poolKey, params, 0, address(this), false);

        vm.revertToState(snapshot);

        poolKey = createPool(0, THREE_BIPS, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);
        (PoolBalanceUpdate explicitZero,) = swapper.swap(poolKey, params, 0, address(this), true);

        assertEq(omitted.delta0(), explicitZero.delta0(), "delta0");
        assertEq(omitted.delta1(), explicitZero.delta1(), "delta1");
    }
}
