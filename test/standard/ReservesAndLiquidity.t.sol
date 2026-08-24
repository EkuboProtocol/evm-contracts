// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {StandardBase} from "./StandardBase.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {CentralBank} from "../../src/standard/CentralBank.sol";
import {Position} from "../../src/types/position.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {createFullRangePoolConfig} from "../../src/types/poolConfig.sol";

contract ReservesAndLiquidityTest is StandardBase {
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
            sell(trader, uint128(standard.balanceOf(trader)));

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

    function test_compounding_consumes_the_pending_bucket() public {
        assertGt(bank.pendingPolEth(), 0, "genesis left ETH to place");
        bank.compound();
        // Only the dust the position could not absorb is carried forward
        assertLt(bank.pendingPolEth(), 1 ether, "the bucket was spent");
    }

    function test_compounding_reverts_when_there_is_nothing_to_place() public {
        bank.compound();
        if (bank.pendingPolEth() < 2) {
            vm.expectRevert(CentralBank.NothingToCompound.selector);
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
        _seedVaultPool(address(standard));

        // A contraction epoch routes the vault share into buybacks
        buy(trader, 10 ether);
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();
        sell(trader, uint128(standard.balanceOf(trader)));
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();

        assertGt(bank.pendingContractionEth(), 0, "defense is funded");
        bank.flush();
        assertGt(address(contractionVault).balance, 0, "the vault holds ETH");

        // Ten days of order duration is the rate limiter that replaces the hourly tick
        vm.prank(owner);
        contractionVault.configure(address(0), 10 days, 1 days, VAULT_POOL_FEE);

        (uint64 endTime, uint112 saleRate) = contractionVault.roll(address(0));
        assertGt(saleRate, 0, "an order is selling ETH into the market");

        vm.warp(vm.getBlockTimestamp() + 2 days);

        uint256 bought = contractionVault.collectToRecipient(address(0), VAULT_POOL_FEE, endTime);
        assertGt(bought, 0, "currency was repurchased");
        assertEq(standard.balanceOf(address(bank)), bought, "and delivered to the bank");

        uint256 burnedBefore = standard.totalBurned();
        uint256 burned = bank.burnReserves();

        assertEq(burned, bought, "everything it bought is burned");
        assertEq(standard.totalBurned() - burnedBefore, bought, "permanently");
        assertEq(standard.balanceOf(address(bank)), 0, "the bank holds no currency");
    }

    function test_the_expansion_vault_stacks_hard_reserves_at_the_bank() public {
        _seedVaultPool(address(gold));

        buy(trader, 10 ether);
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();

        assertGt(bank.pendingExpansionEth(), 0, "expansion routes to reserves");
        bank.flush();

        vm.prank(owner);
        expansionVault.configure(address(0), 10 days, 1 days, VAULT_POOL_FEE);

        (uint64 endTime,) = expansionVault.roll(address(0));
        vm.warp(vm.getBlockTimestamp() + 2 days);

        uint256 acquired = expansionVault.collectToRecipient(address(0), VAULT_POOL_FEE, endTime);

        assertGt(acquired, 0, "the vault bought the reserve asset");
        assertEq(gold.balanceOf(address(bank)), acquired, "reserves are held by the bank");
    }

    function test_the_reserve_asset_is_fixed_at_construction() public view {
        assertEq(bank.RESERVE_ASSET(), address(gold), "immutable");
        assertEq(expansionVault.BUY_TOKEN(), address(gold), "the expansion vault buys it");
        assertEq(contractionVault.BUY_TOKEN(), address(standard), "the contraction vault buys currency");
    }

    function test_vault_proceeds_can_only_go_to_the_bank() public view {
        assertEq(expansionVault.RECIPIENT(), address(bank), "expansion");
        assertEq(contractionVault.RECIPIENT(), address(bank), "contraction");
    }

    receive() external payable {}
}
