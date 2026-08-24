// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ExchequerBase} from "./ExchequerBase.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {Exchequer} from "../../src/exchequer/Exchequer.sol";
import {Position} from "../../src/types/position.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {createFullRangePoolConfig} from "../../src/types/poolConfig.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract ReservesAndLiquidityTest is ExchequerBase {
    using CoreLib for *;

    uint256 internal constant BRANCH = 1e18;

    /// @dev 1%, the fee of the TWAMM sidecar pool the vaults execute against
    uint64 internal constant VAULT_POOL_FEE = uint64((uint256(1) << 64) / 100);

    function _polLiquidity() internal view returns (uint128) {
        Position memory position = core.poolPositions(bank.poolKey().toPoolId(), address(bank), bank.polPositionId());
        return position.liquidity;
    }

    /// @dev Liquidity of the protocol position immediately after genesis
    uint128 private _genesisLiquidity;

    function setUp() public override {
        super.setUp();
        giveShares(alice, 1_000 * BRANCH);
        _genesisLiquidity = _polLiquidity();
    }

    /// PROTOCOL-OWNED LIQUIDITY

    function test_compounding_grows_the_protocol_position() public {
        uint128 before = _polLiquidity();
        assertGt(before, 0, "genesis seeded it");

        bank.compound();

        assertGt(_polLiquidity(), before, "and compounding adds to it");
    }

    function test_protocol_owned_liquidity_only_ever_grows() public {
        uint128 running = _polLiquidity();

        for (uint256 i; i < 5; ++i) {
            buy(trader, 20 ether);
            sell(trader, uint128(issue.balanceOf(trader)));

            vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
            bank.accrue();
            bank.flush();

            if (bank.pendingPolEth() > 1) bank.compound();

            uint128 next = _polLiquidity();
            assertGe(next, running, "liquidity never falls");
            running = next;
        }

        assertGt(running, _genesisLiquidity, "and ends higher than it began");
    }

    function test_compounding_drains_the_bucket_as_fast_as_the_bound_allows() public {
        uint128 pending = bank.pendingPolEth();
        assertGt(pending, 90 ether, "genesis left a great deal of ETH to place");

        // Half of it would move a pool this deep by far more than the premium, so each call places
        // what fits under the bound and the rest waits for the reference to catch up
        bank.compound();
        uint128 afterFirst = bank.pendingPolEth();
        assertLt(afterFirst, pending, "some was placed");
        assertGt(afterFirst, 0, "the rest waits");

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        bank.compound();
        assertLt(bank.pendingPolEth(), afterFirst, "and the next hour places more");
    }

    function test_compounding_reverts_when_there_is_nothing_to_place() public {
        bank.compound();
        if (bank.pendingPolEth() < 2) {
            vm.expectRevert(Exchequer.NothingToCompound.selector);
            bank.compound();
        }
    }

    /// THE VAULTS

    /// @notice Stands up the TWAMM sidecar pool the vaults sell ETH into
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

    function test_the_contraction_vault_buys_currency_the_bank_then_burns() public {
        // Acquire currency to seed the sidecar pool with
        buy(address(this), 50 ether);
        _seedVaultPool(address(issue));

        // A contraction epoch routes the vault share into buybacks
        buy(trader, 10 ether);
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();
        sell(trader, uint128(issue.balanceOf(trader)));
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();

        assertGt(bank.pendingContractionEth(), 0, "defense is funded");
        bank.flush();
        assertGt(address(contractionVault).balance, 0, "the vault holds ETH");

        // Ten days of order duration is the rate limiter that replaces the hourly tick
        vm.prank(owner);
        bank.configureVault(address(contractionVault), 10 days, 1 days, VAULT_POOL_FEE);

        (uint64 endTime, uint112 saleRate) = contractionVault.roll(address(0));
        assertGt(saleRate, 0, "an order is selling ETH into the market");

        vm.warp(vm.getBlockTimestamp() + 2 days);

        // Anyone may collect, and the only place proceeds can go is the bank
        vm.prank(bob);
        uint256 bought = contractionVault.collect(address(0), VAULT_POOL_FEE, endTime);
        assertGt(bought, 0, "currency was repurchased");
        assertEq(issue.balanceOf(address(bank)), bought, "and delivered to the bank");

        uint256 burnedBefore = issue.totalBurned();
        uint256 burned = bank.burnReserves();

        assertEq(burned, bought, "everything it bought is burned");
        assertEq(issue.totalBurned() - burnedBefore, bought, "permanently");
        assertEq(issue.balanceOf(address(bank)), 0, "the bank holds no currency");
    }

    function test_the_expansion_vault_stacks_hard_reserves_at_the_bank() public {
        _seedVaultPool(address(gold));

        buy(trader, 10 ether);
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();

        assertGt(bank.pendingExpansionEth(), 0, "expansion routes to reserves");
        bank.flush();

        vm.prank(owner);
        bank.configureVault(address(expansionVault), 10 days, 1 days, VAULT_POOL_FEE);

        (uint64 endTime,) = expansionVault.roll(address(0));
        vm.warp(vm.getBlockTimestamp() + 2 days);

        uint256 acquired = expansionVault.collect(address(0), VAULT_POOL_FEE, endTime);

        assertGt(acquired, 0, "the vault bought the reserve asset");
        assertEq(gold.balanceOf(address(bank)), acquired, "reserves are held by the bank");
    }

    function test_the_reserve_asset_is_fixed_at_construction() public view {
        assertEq(bank.RESERVE_ASSET(), address(gold), "immutable");
        assertEq(expansionVault.BUY_TOKEN(), address(gold), "the expansion vault buys it");
        assertEq(contractionVault.BUY_TOKEN(), address(issue), "the contraction vault buys currency");
    }

    function test_vault_proceeds_can_only_go_to_the_bank() public view {
        // `RevenueBuybacks.collect` pays the owner, so the bank owning the vault is the guarantee
        assertEq(expansionVault.owner(), address(bank), "expansion");
        assertEq(contractionVault.owner(), address(bank), "contraction");
    }

    function test_nobody_can_reach_the_vaults_arbitrary_call() public {
        // Not the bank's owner, who has no passthrough for it
        vm.prank(owner);
        vm.expectRevert(Ownable.Unauthorized.selector);
        expansionVault.call(address(gold), 0, "");

        // And not the bank itself, which exposes no way to make the call
        vm.prank(address(bank));
        expansionVault.call(address(gold), 0, abi.encodeWithSignature("totalSupply()"));
    }

    function test_only_the_banks_owner_configures_the_vaults() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        bank.configureVault(address(expansionVault), 10 days, 1 days, VAULT_POOL_FEE);

        vm.prank(owner);
        vm.expectRevert(Exchequer.UnknownVault.selector);
        bank.configureVault(address(gold), 10 days, 1 days, VAULT_POOL_FEE);
    }

    /// THE REFERENCE PRICE AND THE BOUND ON COMPOUNDING

    function _spotTick() internal view returns (int32) {
        return core.poolState(bank.poolKey().toPoolId()).tick();
    }

    function test_the_reference_starts_at_the_genesis_tick() public view {
        assertEq(bank.referenceTick(), GENESIS_TICK, "seeded at genesis");
    }

    function test_a_price_that_exists_only_inside_a_block_does_not_move_the_reference() public {
        int32 before = bank.referenceTick();

        // A large buy moves spot a long way, then is unwound in the same block
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
        int32 halfway = bank.referenceTick();
        assertApproxEqAbs(int256(halfway), (int256(before) + int256(spot)) / 2, 2, "halfway through the window");

        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        assertApproxEqAbs(int256(bank.referenceTick()), int256(spot), 1, "fully replaced after the window");
    }

    function test_compound_refuses_to_buy_into_a_pump() public {
        // Make $ISSUE dear: a large buy pushes the tick well below reference minus the premium
        buy(trader, 300 ether);
        assertLt(_spotTick(), bank.referenceTick() - int32(POL_MAX_PREMIUM_TICKS), "dearer than the bound");

        uint128 pending = bank.pendingPolEth();
        vm.expectRevert(Exchequer.IssuePricedAboveReference.selector);
        bank.compound();

        assertEq(bank.pendingPolEth(), pending, "the ETH simply waits");
    }

    function test_compound_buys_the_dip() public {
        // Make $ISSUE cheap: the trader dumps a large position
        buy(trader, 300 ether);
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        sell(trader, uint128(issue.balanceOf(trader)));
        assertGt(_spotTick(), bank.referenceTick(), "cheaper than the reference");

        uint128 before = _polLiquidity();
        bank.compound();
        assertGt(_polLiquidity(), before, "the bank buys");
    }

    function test_compound_never_pushes_the_price_past_the_bound() public {
        // Route a great deal of ETH into the POL bucket, far more than the bound will absorb
        for (uint256 i; i < 6; ++i) {
            buy(trader, 100 ether);
            vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
            bank.accrue();
        }
        vm.warp(vm.getBlockTimestamp() + 2 hours);

        uint128 pendingBefore = bank.pendingPolEth();
        int32 bound = bank.referenceTick() - int32(POL_MAX_PREMIUM_TICKS);

        bank.compound();

        assertGe(_spotTick(), bound, "the swap stopped at the bound");
        assertGt(bank.pendingPolEth(), 0, "what did not fit waits");
        assertLt(bank.pendingPolEth(), pendingBefore, "but some was placed");

        // A second call in the same block finds spot already at the bound and does nothing
        vm.expectRevert(Exchequer.IssuePricedAboveReference.selector);
        bank.compound();
    }

    function test_a_sandwich_around_compound_loses_money() public {
        // Route fee ETH into the POL bucket so there is something worth sandwiching
        buy(trader, 50 ether);
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        assertGt(bank.pendingPolEth(), 1 ether, "a real tranche");

        // The attacker fronts a pump, triggers compound, and sells back into the bank's bids
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1_000 ether);
        vm.deal(address(this), 1_000 ether);
        uint256 ethBefore = address(this).balance;

        buy(attacker, 200 ether);

        vm.expectRevert(Exchequer.IssuePricedAboveReference.selector);
        bank.compound();

        sell(attacker, uint128(issue.balanceOf(attacker)));

        // With nothing to sell into, the round trip paid two fees and price impact for nothing
        assertLt(address(this).balance, ethBefore, "the sandwich lost money");
    }

    receive() external payable {}
}
