// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ExchequerBase} from "./ExchequerBase.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {Exchequer} from "../../src/exchequer/Exchequer.sol";
import {Position} from "../../src/types/position.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PositionId} from "../../src/types/positionId.sol";
import {createFullRangePoolConfig} from "../../src/types/poolConfig.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract ReservesAndLiquidityTest is ExchequerBase {
    using CoreLib for *;

    uint256 internal constant BRANCH = 1e18;

    /// @dev 1%, the fee of the TWAMM sidecar pool the expansion vault executes against
    uint64 internal constant VAULT_POOL_FEE = uint64((uint256(1) << 64) / 100);

    function _liquidityOf(PositionId positionId) internal view returns (uint128) {
        Position memory position = core.poolPositions(bank.poolKey().toPoolId(), address(bank), positionId);
        return position.liquidity;
    }

    function _genesisLiquidity() internal view returns (uint128) {
        return _liquidityOf(bank.polPositionId());
    }

    function _spotTick() internal view returns (int32) {
        return core.poolState(bank.poolKey().toPoolId()).tick();
    }

    /// @dev Routes fee ETH into the POL and contraction buckets: a buy in one epoch, a larger sell
    ///      in the next, so the second epoch closes as a contraction
    function _earnRevenue() internal {
        buy(trader, 50 ether);
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();
        sell(trader, uint128(issue.balanceOf(trader)));
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
    }

    function setUp() public override {
        super.setUp();
        giveShares(alice, 1_000 * BRANCH);
    }

    /// PROTOCOL-OWNED LIQUIDITY

    function test_genesis_seeds_the_full_range_position() public view {
        assertGt(_genesisLiquidity(), 0, "genesis seeded it");
    }

    function test_compounding_places_a_bid_bucket_above_the_market() public {
        uint128 pending = bank.pendingPolEth();
        assertGt(pending, 90 ether, "genesis left a great deal of ETH to place");

        (uint128 liquidity, int32 lower) = bank.compound();

        assertGt(liquidity, 0, "a bucket was placed");
        assertGt(lower, _spotTick(), "strictly above the market, so it holds only ETH");
        assertEq(lower % bank.POL_BID_GRID(), 0, "on the grid");
        assertEq(_liquidityOf(bank.polBidPositionId(lower)), liquidity, "recorded under the POL salt");
        assertLt(bank.pendingPolEth(), 1e9, "all but rounding dust was placed");
    }

    function test_compounding_never_swaps() public {
        int32 before = _spotTick();
        (int256 flowBefore,,) = bank.netFlows();
        uint128 savedBefore = bank.savedEth();

        bank.compound();

        assertEq(_spotTick(), before, "the price did not move");
        (int256 flowAfter,,) = bank.netFlows();
        assertEq(flowAfter, flowBefore, "no flow was registered");
        assertEq(bank.savedEth(), savedBefore, "and no fee was charged");
    }

    function test_compounding_with_nothing_pending_reverts() public {
        bank.compound();
        vm.expectRevert(Exchequer.NothingToCompound.selector);
        bank.compound();
    }

    function test_bids_are_filled_by_sellers_and_become_two_sided_liquidity() public {
        // A trader holds a large position from before the bids were placed
        buy(trader, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 2 hours);

        (, int32 lower) = bank.compound();

        // Then sells it all, pushing $ISSUE down through the bucket
        sell(trader, uint128(issue.balanceOf(trader)));

        assertGt(_spotTick(), lower, "the market fell into the bucket");
        assertGt(_liquidityOf(bank.polBidPositionId(lower)), 0, "which still stands");

        // The bank now holds $ISSUE it bought below the market: protocol-owned liquidity
        assertGt(_genesisLiquidity(), 0, "alongside the genesis range");
    }

    function test_protocol_owned_liquidity_only_ever_grows() public {
        uint128 genesis = _genesisLiquidity();
        uint128 bidLiquidity;

        for (uint256 i; i < 4; ++i) {
            _earnRevenue();
            (uint128 added,) = bank.compound();
            bidLiquidity += added;
        }

        assertEq(_genesisLiquidity(), genesis, "the genesis range never changes");
        assertGt(bidLiquidity, 0, "and bids only accumulate");
    }

    /// THE REFERENCE PRICE AND WHERE BIDS MAY SIT

    function test_the_reference_starts_at_the_genesis_tick() public view {
        assertEq(bank.referenceTick(), GENESIS_TICK, "seeded at genesis");
    }

    function test_a_price_that_exists_only_inside_a_block_does_not_move_the_reference() public {
        int32 before = bank.referenceTick();

        buy(trader, 300 ether);
        assertLt(_spotTick(), before - 10_000, "spot moved");
        assertEq(bank.referenceTick(), before, "the reference did not");

        sell(trader, uint128(issue.balanceOf(trader)));
        assertEq(bank.referenceTick(), before, "and still has not");
    }

    function test_a_price_that_prevails_for_the_window_replaces_the_reference() public {
        int32 before = bank.referenceTick();
        buy(trader, 300 ether);
        int32 spot = _spotTick();

        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        assertApproxEqAbs(int256(bank.referenceTick()), (int256(before) + int256(spot)) / 2, 2, "halfway");

        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        assertApproxEqAbs(int256(bank.referenceTick()), int256(spot), 1, "fully replaced");
    }

    function test_a_pump_in_front_of_compound_finds_no_bids_to_sell_into() public {
        // The attacker makes $ISSUE dear inside one block
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1_000 ether);
        buy(attacker, 300 ether);
        int32 pumped = _spotTick();
        assertLt(pumped, bank.referenceTick() - 10_000, "well above the reference price");

        (, int32 lower) = bank.compound();

        // The bucket is placed above the reference, not just above the pumped spot
        assertGt(lower, bank.referenceTick(), "bids never sit above the reference");

        // Selling back into the pool finds only the genesis range, and the round trip lost money:
        // the buy cost 300 ETH, and the sell's proceeds land with the attacker
        uint256 attackerBefore = attacker.balance;
        sell(attacker, uint128(issue.balanceOf(attacker)));
        assertLt(attacker.balance - attackerBefore, 300 ether, "the attacker got back less than they put in");
        assertEq(_liquidityOf(bank.polBidPositionId(lower)) > 0, true, "the bucket stands, untouched");
    }

    function test_a_dump_in_front_of_compound_only_places_the_bids_lower() public {
        buy(trader, 300 ether);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        sell(trader, uint128(issue.balanceOf(trader)));
        assertGt(_spotTick(), bank.referenceTick(), "$ISSUE is cheap");

        (uint128 liquidity, int32 lower) = bank.compound();
        assertGt(liquidity, 0, "the bank bids anyway");
        assertGt(lower, _spotTick(), "just below the dumped market");
    }

    /// BUYBACKS AS STANDING BIDS

    function test_defend_places_contraction_eth_as_a_bid_bucket() public {
        _earnRevenue();
        uint128 pending = bank.pendingContractionEth();
        assertGt(pending, 0, "a contraction epoch funded defense");

        (uint128 liquidity, int32 lower,) = bank.defend();

        assertGt(liquidity, 0, "bids placed");
        assertTrue(bank.buybackBidActive(), "one active bucket");
        assertEq(bank.buybackBidLowerTick(), lower, "at the recorded tick");
        assertGt(lower, _spotTick(), "below the market");
        assertEq(bank.pendingContractionEth() < 1e9, true, "all but dust placed");
    }

    function test_defend_burns_what_the_bids_bought_and_re_bids_the_rest() public {
        _earnRevenue();

        // A trader holds a large position from before the bids were placed
        buy(trader, 100 ether);
        vm.warp(vm.getBlockTimestamp() + 2 hours);

        (, int32 lower,) = bank.defend();

        // Then a wave of selling pushes $ISSUE down through the bucket
        sell(trader, uint128(issue.balanceOf(trader)));
        assertGt(_spotTick(), lower, "the market fell into the bucket");

        uint256 burnedBefore = issue.totalBurned();
        uint256 ceilingBefore = issue.maxSupply();
        PositionId oldBucket = bank.buybackPositionId();
        assertGt(_liquidityOf(oldBucket), 0, "the bucket stood");

        (uint128 liquidity, int32 newLower, uint256 issueBurned) = bank.defend();

        assertGt(issueBurned, 0, "the bucket had bought currency");
        assertEq(issue.totalBurned() - burnedBefore, issueBurned, "all of it was destroyed");
        assertLt(issue.maxSupply(), ceilingBefore, "permanently");
        assertEq(_liquidityOf(oldBucket), 0, "the old bucket is gone entirely");
        assertGt(newLower, _spotTick(), "and the remaining ETH bids again below the new market");
        if (liquidity != 0) assertEq(bank.buybackBidLowerTick(), newLower, "recorded");
        assertEq(issue.balanceOf(address(bank)), 0, "the bank holds no currency");
    }

    function test_defend_with_nothing_filled_and_nothing_new_reverts() public {
        _earnRevenue();
        bank.defend();

        vm.expectRevert(Exchequer.NothingToDefend.selector);
        bank.defend();
    }

    function test_defend_with_nothing_at_all_reverts() public {
        vm.expectRevert(Exchequer.NothingToDefend.selector);
        bank.defend();
    }

    function test_defense_cannot_be_baited() public {
        _earnRevenue();
        (, int32 lower,) = bank.defend();

        // An attacker pumps in front of a defend call, hoping the bank buys high
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1_000 ether);
        buy(attacker, 200 ether);

        // Nothing filled, nothing new: the bank does nothing at all
        vm.expectRevert(Exchequer.NothingToDefend.selector);
        bank.defend();

        assertEq(_liquidityOf(bank.buybackPositionId()) > 0, true, "the bucket stands where it was");
        assertEq(bank.buybackBidLowerTick(), lower, "unchanged");
    }

    /// THE EXPANSION VAULT

    /// @notice Stands up the TWAMM sidecar pool the vault sells ETH into
    function _seedVaultPool(address buyToken) internal {
        PoolKey memory sidecar = PoolKey({
            token0: address(0),
            token1: buyToken,
            config: createFullRangePoolConfig({_fee: VAULT_POOL_FEE, _extension: address(twamm)})
        });

        positions.maybeInitializePool(sidecar, 0);
        vm.deal(address(this), 1_000 ether);
        (bool ok,) =
            buyToken.call(abi.encodeWithSignature("approve(address,uint256)", address(positions), type(uint256).max));
        require(ok, "approve failed");
        positions.mintAndDeposit{value: 100 ether}(sidecar, MIN_TICK, MAX_TICK, 100 ether, 100 ether, 0);
    }

    function test_the_expansion_vault_stacks_hard_reserves_at_the_bank() public {
        _seedVaultPool(address(gold));

        buy(trader, 10 ether);
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();

        assertGt(bank.pendingExpansionEth(), 0, "expansion routes to reserves");
        bank.flush();

        vm.prank(owner);
        bank.configureExpansionVault(10 days, 1 days, VAULT_POOL_FEE);

        (uint64 endTime,) = expansionVault.roll(address(0));
        vm.warp(vm.getBlockTimestamp() + 2 days);

        // Anyone may collect, and the only place proceeds can go is the bank
        vm.prank(bob);
        uint256 acquired = expansionVault.collect(address(0), VAULT_POOL_FEE, endTime);

        assertGt(acquired, 0, "the vault bought the reserve asset");
        assertEq(gold.balanceOf(address(bank)), acquired, "reserves are held by the bank");
    }

    function test_the_reserve_asset_is_fixed_at_construction() public view {
        assertEq(bank.RESERVE_ASSET(), address(gold), "immutable");
        assertEq(expansionVault.BUY_TOKEN(), address(gold), "the expansion vault buys it");
    }

    function test_vault_proceeds_can_only_go_to_the_bank() public view {
        assertEq(expansionVault.owner(), address(bank), "the bank owns the vault");
    }

    function test_nobody_can_reach_the_vaults_arbitrary_call() public {
        vm.prank(owner);
        vm.expectRevert(Ownable.Unauthorized.selector);
        expansionVault.call(address(gold), 0, "");
    }

    function test_only_the_banks_owner_configures_the_vault() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        bank.configureExpansionVault(10 days, 1 days, VAULT_POOL_FEE);
    }

    receive() external payable {}
}
