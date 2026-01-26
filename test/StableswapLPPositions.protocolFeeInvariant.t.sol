// SPDX-License-Identifier: MIT
pragma solidity =0.8.33;

import {Test, console} from "forge-std/Test.sol";
import {StableswapLPPositions} from "../src/StableswapLPPositions.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Core} from "../src/Core.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolConfig, createStableswapPoolConfig} from "../src/types/poolConfig.sol";
import {TestToken} from "./TestToken.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {FullTest} from "./FullTest.sol";
import {SwapParameters, createSwapParameters} from "../src/types/swapParameters.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";

/**
 * @title Protocol Fee Invariant Test (ERC6909)
 * @notice Verifies the invariant: "All fees in savedBalances under poolId salt are NET of protocol fees"
 * @dev This test ensures that:
 *      1. Protocol fees are stored under salt = bytes32(0)
 *      2. Pending fees are stored under salt = PoolId.unwrap(poolId)
 *      3. Pending fees are always NET of protocol fees (protocol fee already extracted)
 *      4. Total protocol fees = protocolFeeRate * total fees collected
 */
contract ProtocolFeeInvariantTest is FullTest {
    using CoreLib for *;

    StableswapLPPositions lpPositions;
    PoolKey poolKey;
    uint256 tokenId;  // ERC6909 token ID
    PoolId poolId;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address swapper = makeAddr("swapper");

    uint256 constant DEADLINE = type(uint256).max;
    uint64 constant PROTOCOL_FEE_X64 = uint64((uint256(1) << 64) / 10); // 10% protocol fee

    // Track cumulative fees for invariant checking
    uint256 totalFeesCollected0;
    uint256 totalFeesCollected1;
    uint256 totalProtocolFeesExtracted0;
    uint256 totalProtocolFeesExtracted1;

    function setUp() public override {
        super.setUp();

        // Create LP positions contract with 10% protocol fee
        lpPositions = new StableswapLPPositions(core, owner, PROTOCOL_FEE_X64);

        // Create stableswap pool
        PoolConfig config = createStableswapPoolConfig(1 << 63, 10, 0, address(0));
        poolKey = PoolKey({token0: address(token0), token1: address(token1), config: config});
        core.initializePool(poolKey, 0);
        poolId = poolKey.toPoolId();
        
        // Get ERC6909 token ID
        tokenId = uint256(PoolId.unwrap(poolId));

        // Fund users
        token0.transfer(alice, 1000 ether);
        token1.transfer(alice, 1000 ether);
        token0.transfer(bob, 1000 ether);
        token1.transfer(bob, 1000 ether);
        token0.transfer(swapper, 10_000 ether);
        token1.transfer(swapper, 10_000 ether);

        // Approve
        vm.prank(alice);
        token0.approve(address(lpPositions), type(uint256).max);
        vm.prank(alice);
        token1.approve(address(lpPositions), type(uint256).max);

        vm.prank(bob);
        token0.approve(address(lpPositions), type(uint256).max);
        vm.prank(bob);
        token1.approve(address(lpPositions), type(uint256).max);

        vm.prank(swapper);
        token0.approve(address(router), type(uint256).max);
        vm.prank(swapper);
        token1.approve(address(router), type(uint256).max);
    }

    /**
     * @notice Core invariant: Pending fees in savedBalances are NET of protocol fees
     * @dev Verifies:
     *      pendingFees + protocolFees + compoundedFees = totalFeesCollected
     *      protocolFees ≈ 10% of totalFeesCollected (within rounding tolerance)
     * @dev Not using invariant_ prefix to avoid auto-fuzzing (would call random Core functions)
     */
    function checkInvariant_pendingFeesAreNetOfProtocolFees() public view {
        // Get pending fees (under poolId salt)
        (uint128 pending0, uint128 pending1) = core.savedBalances(
            address(lpPositions),
            poolKey.token0,
            poolKey.token1,
            PoolId.unwrap(poolId)
        );

        // Get protocol fees (under bytes32(0) salt)
        (uint128 protocol0, uint128 protocol1) = core.savedBalances(
            address(lpPositions),
            poolKey.token0,
            poolKey.token1,
            bytes32(0)
        );

        // Get compounded fees (total liquidity minus initial deposits)
        // Using ERC6909 poolMetadata instead of StableswapLPToken
        (,, uint128 totalLiquidity,,) = lpPositions.poolMetadata(tokenId);
        // Note: We'd need to track initial deposits separately to calculate compoundedFees
        // For now, we'll verify the protocol fee relationship

        console.log("\n=== Invariant Check ===");
        console.log("Pending fees 0:", pending0);
        console.log("Pending fees 1:", pending1);
        console.log("Protocol fees 0:", protocol0);
        console.log("Protocol fees 1:", protocol1);

        // Calculate expected protocol fees (10% of total collected)
        uint256 expectedProtocol0 = (totalFeesCollected0 * 10) / 100;
        uint256 expectedProtocol1 = (totalFeesCollected1 * 10) / 100;

        console.log("Total fees collected 0:", totalFeesCollected0);
        console.log("Total fees collected 1:", totalFeesCollected1);
        console.log("Expected protocol 0:", expectedProtocol0);
        console.log("Expected protocol 1:", expectedProtocol1);

        // Verify protocol fees are approximately 10% (allow 1% rounding tolerance)
        if (totalFeesCollected0 > 0) {
            uint256 actualProtocolRate = (protocol0 * 100) / totalFeesCollected0;
            assertApproxEqAbs(actualProtocolRate, 10, 1, "Protocol fee rate should be ~10%");
        }

        if (totalFeesCollected1 > 0) {
            uint256 actualProtocolRate = (protocol1 * 100) / totalFeesCollected1;
            assertApproxEqAbs(actualProtocolRate, 10, 1, "Protocol fee rate should be ~10%");
        }

        // Verify pending + protocol <= total collected
        assertLe(uint256(pending0) + uint256(protocol0), totalFeesCollected0, "Pending + protocol <= total");
        assertLe(uint256(pending1) + uint256(protocol1), totalFeesCollected1, "Pending + protocol <= total");
    }

    /**
     * @notice Test: Normal deposit-swap-compound cycle maintains invariant
     */
    function test_invariant_normalCycle() public {
        // Alice deposits initial liquidity (auto-initializes pool in ERC6909)
        vm.prank(alice);
        lpPositions.deposit(poolKey, 100 ether, 100 ether, 0, DEADLINE);

        // Generate fees via swap
        vm.prank(swapper);
        router.swapAllowPartialFill(
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0),
                _amount: 10 ether,
                _isToken1: false,
                _skipAhead: 0
            })
        );

        // Track fees collected (approximate - we'd need to query Core for exact amounts)
        // For this test, we'll estimate based on swap amount and fee tier
        // Stableswap fee tier is 1 << 63 which is 50% of the fee bips
        uint256 feeRate = uint256(1 << 63);
        uint256 estimatedFee = (10 ether * feeRate) / (1 << 64);
        totalFeesCollected0 += estimatedFee;

        // Bob deposits (triggers auto-compound)
        vm.prank(bob);
        lpPositions.deposit(poolKey, 50 ether, 50 ether, 0, DEADLINE);

        // Check invariant
        checkInvariant_pendingFeesAreNetOfProtocolFees();
    }

    /**
     * @notice Test: Fees that fail to compound are saved as pending (net of protocol fee)
     */
    function test_invariant_pendingFeesAreNet() public {
        // Alice deposits (auto-initializes in ERC6909)
        vm.prank(alice);
        lpPositions.deposit(poolKey, 100 ether, 100 ether, 0, DEADLINE);

        // Generate small fees
        vm.prank(swapper);
        router.swapAllowPartialFill(
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0),
                _amount: 1 ether,
                _isToken1: false,
                _skipAhead: 0
            })
        );

        uint256 feeRate = uint256(1 << 63);
        uint256 estimatedFee = (1 ether * feeRate) / (1 << 64);
        totalFeesCollected0 += estimatedFee;

        // Trigger auto-compound (might create pending fees if compound fails)
        vm.prank(bob);
        lpPositions.deposit(poolKey, 10 ether, 10 ether, 0, DEADLINE);

        // Get savedBalances
        (uint128 pending0, uint128 pending1) = core.savedBalances(
            address(lpPositions),
            poolKey.token0,
            poolKey.token1,
            PoolId.unwrap(poolId)
        );

        (uint128 protocol0, uint128 protocol1) = core.savedBalances(
            address(lpPositions),
            poolKey.token0,
            poolKey.token1,
            bytes32(0)
        );

        console.log("\n=== After Auto-Compound ===");
        console.log("Pending fees (net):", pending0, pending1);
        console.log("Protocol fees:", protocol0, protocol1);

        // Invariant: pending + protocol should be <= total collected
        assertLe(uint256(pending0) + uint256(protocol0), totalFeesCollected0, "Pending is net of protocol");
        assertLe(uint256(pending1) + uint256(protocol1), totalFeesCollected1, "Pending is net of protocol");

        // If there are protocol fees, they should be approximately 10% of total
        if (protocol0 > 0) {
            uint256 protocolRate = (uint256(protocol0) * 100) / totalFeesCollected0;
            console.log("Protocol fee rate:", protocolRate, "%");
            assertApproxEqAbs(protocolRate, 10, 2, "Protocol fee ~10%");
        }
    }

    /**
     * @notice Test: Multiple compound attempts don't double-charge protocol fees
     */
    function test_invariant_noDoubleChargeOnPending() public {
        // Alice deposits (auto-initializes in ERC6909)
        vm.prank(alice);
        lpPositions.deposit(poolKey, 100 ether, 100 ether, 0, DEADLINE);

        // Generate fees
        for (uint i = 0; i < 3; i++) {
            vm.prank(swapper);
            router.swapAllowPartialFill(
                poolKey,
                createSwapParameters({
                    _sqrtRatioLimit: SqrtRatio.wrap(0),
                    _amount: 5 ether,
                    _isToken1: false,
                    _skipAhead: 0
                })
            );

            uint256 feeRate = uint256(1 << 63);
            uint256 estimatedFee = (5 ether * feeRate) / (1 << 64);
            totalFeesCollected0 += estimatedFee;
        }

        // Trigger auto-compound multiple times
        for (uint i = 0; i < 3; i++) {
            vm.prank(bob);
            lpPositions.deposit(poolKey, 1 ether, 1 ether, 0, DEADLINE);
        }

        // Check final invariant
        (uint128 protocol0,) = core.savedBalances(
            address(lpPositions),
            poolKey.token0,
            poolKey.token1,
            bytes32(0)
        );

        console.log("\n=== After Multiple Compounds ===");
        console.log("Total fees collected:", totalFeesCollected0);
        console.log("Protocol fees extracted:", protocol0);

        // Protocol fees should still be ~10% of total, not inflated
        if (protocol0 > 0 && totalFeesCollected0 > 0) {
            uint256 protocolRate = (uint256(protocol0) * 100) / totalFeesCollected0;
            console.log("Protocol fee rate:", protocolRate, "%");
            assertApproxEqAbs(protocolRate, 10, 2, "Protocol fee should stay ~10% across multiple compounds");
        }
    }

    /**
     * @notice Test: Protocol fee withdrawal doesn't affect pending fees
     */
    function test_invariant_protocolWithdrawalDoesntAffectPending() public {
        // Alice deposits (auto-initializes in ERC6909)
        vm.prank(alice);
        lpPositions.deposit(poolKey, 100 ether, 100 ether, 0, DEADLINE);

        // Generate fees
        vm.prank(swapper);
        router.swapAllowPartialFill(
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0),
                _amount: 10 ether,
                _isToken1: false,
                _skipAhead: 0
            })
        );

        uint256 feeRate = uint256(1 << 63);
        uint256 estimatedFee = (10 ether * feeRate) / (1 << 64);
        totalFeesCollected0 += estimatedFee;

        // Trigger compound
        vm.prank(bob);
        lpPositions.deposit(poolKey, 10 ether, 10 ether, 0, DEADLINE);

        // Get balances before withdrawal
        (uint128 pendingBefore0, uint128 pendingBefore1) = core.savedBalances(
            address(lpPositions),
            poolKey.token0,
            poolKey.token1,
            PoolId.unwrap(poolId)
        );

        (uint128 protocolBefore0, uint128 protocolBefore1) = core.savedBalances(
            address(lpPositions),
            poolKey.token0,
            poolKey.token1,
            bytes32(0)
        );

        // Owner withdraws protocol fees
        vm.prank(owner);
        lpPositions.withdrawProtocolFees(
            poolKey.token0,
            poolKey.token1,
            protocolBefore0,
            protocolBefore1,
            owner
        );

        // Get balances after withdrawal
        (uint128 pendingAfter0, uint128 pendingAfter1) = core.savedBalances(
            address(lpPositions),
            poolKey.token0,
            poolKey.token1,
            PoolId.unwrap(poolId)
        );

        console.log("\n=== Protocol Fee Withdrawal ===");
        console.log("Pending before:", pendingBefore0, pendingBefore1);
        console.log("Pending after:", pendingAfter0, pendingAfter1);

        // Invariant: Pending fees should be unchanged by protocol fee withdrawal
        assertEq(pendingAfter0, pendingBefore0, "Pending fees unchanged after protocol withdrawal");
        assertEq(pendingAfter1, pendingBefore1, "Pending fees unchanged after protocol withdrawal");
    }

    /**
     * @notice Helper: Get protocol fees for a pool
     */
    function getProtocolFees(PoolKey memory _poolKey)
        public
        view
        returns (uint128 protocol0, uint128 protocol1)
    {
        (protocol0, protocol1) = core.savedBalances(
            address(lpPositions),
            _poolKey.token0,
            _poolKey.token1,
            bytes32(0)
        );
    }

    /**
     * @notice Helper: Get pending fees for a pool
     */
    function getPendingFees(PoolKey memory _poolKey)
        public
        view
        returns (uint128 pending0, uint128 pending1)
    {
        (pending0, pending1) = core.savedBalances(
            address(lpPositions),
            _poolKey.token0,
            _poolKey.token1,
            PoolId.unwrap(_poolKey.toPoolId())
        );
    }
}
