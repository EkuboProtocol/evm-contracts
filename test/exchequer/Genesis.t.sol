// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ExchequerBase} from "./ExchequerBase.sol";
import {ExchequerAuctions} from "../../src/exchequer/ExchequerAuctions.sol";
import {GENESIS_LIQUIDITY, ISSUANCE_BUDGET} from "../../src/libraries/ExchequerMath.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {Exchequer, exchequerCallPoints} from "../../src/exchequer/Exchequer.sol";
import {ExchequerVault} from "../../src/exchequer/ExchequerVault.sol";
import {IssueToken} from "../../src/exchequer/IssueToken.sol";
import {BankToken} from "../../src/exchequer/BankToken.sol";
import {GENESIS_LIQUIDITY} from "../../src/libraries/ExchequerMath.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract GenesisTest is ExchequerBase {
    using CoreLib for *;

    function test_genesis_initializes_the_one_market() public view {
        PoolKey memory key = lens.poolKey(bank);
        assertEq(key.token0, address(0), "eth is token0");
        assertEq(key.token1, address(issue), "issue is token1");

        PoolState state = core.poolState(key.toPoolId());
        assertTrue(state.isInitialized(), "pool initialized");
        assertGt(state.liquidity(), 0, "genesis liquidity present");
    }

    function test_genesis_is_the_only_premint() public view {
        // The whole 100M was minted, and whatever the chosen tick could not absorb was burned
        assertEq(issue.totalMinted(), GENESIS_LIQUIDITY, "only the genesis mint happened");
        assertEq(issue.totalSupply() + issue.totalBurned(), GENESIS_LIQUIDITY, "supply identity");
    }

    function test_genesis_currency_side_binds_so_only_dust_is_burned() public view {
        // The fixture seeds enough ETH that $ISSUE is the binding side of the position, so all
        // that is destroyed is the rounding dust the liquidity math could not place
        assertLt(issue.totalBurned(), 1e6, "only dust burned");
        assertGt(lens.pendingPolEth(bank), 90 ether, "the unabsorbed ETH is held for compounding");
    }

    function test_genesis_wired_the_vault_and_the_auctions() public view {
        assertEq(lens.expansionVault(bank), address(expansionVault), "vault");
        assertEq(lens.auctions(bank), address(auctions), "auctions");
        assertTrue(lens.initialized(bank), "and ran");
    }

    function test_the_parameters_are_readable_from_storage() public view {
        assertEq(lens.parameters(bank).epochLength, 1 days, "epoch length");
        assertEq(lens.parameters(bank).tradingFee, TRADING_FEE, "trading fee");
        assertEq(lens.parameters(bank).multiplierMax, 4e18, "multiplier ceiling");
        assertEq(lens.issueToken(bank), address(issue), "currency");
        assertEq(lens.bankToken(bank), address(bankToken), "share");
        assertEq(lens.reserveAsset(bank), address(gold), "reserve asset");
        assertEq(lens.owner(bank), owner, "owner");
        assertEq(lens.teamRecipient(bank), team, "team");
    }

    function test_supply_ceiling_only_ever_falls() public view {
        assertEq(issue.maxSupply(), issue.HARD_CAP() - issue.totalBurned(), "eq 3.2");
        assertLe(issue.maxSupply(), issue.HARD_CAP(), "ceiling never rises");
    }

    function test_genesis_cannot_run_twice() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert(Exchequer.GenesisAlreadyRan.selector);
        bank.initialize{value: 1 ether}(GENESIS_TICK, address(expansionVault), address(auctions));
    }

    function test_only_owner_initializes() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        bank.initialize(GENESIS_TICK, address(expansionVault), address(auctions));
    }

    function test_no_second_pool_may_adopt_the_extension() public {
        PoolKey memory key = lens.poolKey(bank);
        key.token1 = address(gold);

        vm.expectRevert(Exchequer.OnlyGenesisMayInitializeThePool.selector);
        core.initializePool(key, 0);
    }

    /// @dev A second bank whose genesis has not run yet, with its own bound tokens, vault and auctions
    function _freshBank(uint160 tag)
        internal
        returns (Exchequer fresh, ExchequerVault vault, ExchequerAuctions freshAuctions)
    {
        IssueToken freshIssue = new IssueToken(address(this));
        BankToken freshBank = new BankToken(address(this));
        address at = address((uint160(exchequerCallPoints().toUint8()) << 152) + tag);
        deployCodeTo(
            "Exchequer.sol:Exchequer",
            abi.encode(core, owner, address(gold), freshIssue, freshBank, defaultParameters()),
            at
        );
        fresh = Exchequer(payable(at));
        freshIssue.bind(at);
        freshBank.bind(at);
        vault = new ExchequerVault(at, orders, address(gold));
        freshAuctions = newAuctions(fresh);
    }

    function test_genesis_refuses_to_run_on_tokens_bound_elsewhere() public {
        // A bank constructed over the main fixture's tokens, which answer to the main bank
        address at = address((uint160(exchequerCallPoints().toUint8()) << 152) + 0xf011);
        deployCodeTo(
            "Exchequer.sol:Exchequer", abi.encode(core, owner, address(gold), issue, bankToken, defaultParameters()), at
        );
        Exchequer impostor = Exchequer(payable(at));
        ExchequerVault vault = new ExchequerVault(at, orders, address(gold));
        ExchequerAuctions impostorAuctions = newAuctions(impostor);

        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert(Exchequer.TokensNotBoundToBank.selector);
        impostor.initialize{value: 1 ether}(GENESIS_TICK, address(vault), address(impostorAuctions));
    }

    function test_tokens_bind_once_and_only_by_their_binder() public {
        IssueToken token = new IssueToken(address(this));

        vm.prank(alice);
        vm.expectRevert(IssueToken.CannotBind.selector);
        token.bind(alice);

        token.bind(address(bank));
        vm.expectRevert(IssueToken.CannotBind.selector);
        token.bind(alice);
        assertEq(token.minter(), address(bank), "bound once");
    }

    function test_nobody_can_open_the_canonical_pool_ahead_of_genesis() public {
        (Exchequer fresh,,) = _freshBank(0xf00d);
        PoolKey memory key = lens.poolKey(fresh);

        vm.expectRevert(Exchequer.OnlyGenesisMayInitializeThePool.selector);
        core.initializePool(key, GENESIS_TICK);
    }

    function test_genesis_refuses_a_seed_the_tick_cannot_pair() public {
        (Exchequer fresh, ExchequerVault vault, ExchequerAuctions freshAuctions) = _freshBank(0xf00e);

        // One wei of ETH cannot pair with 100,000,000 $ISSUE at any sensible tick, and a one-shot
        // genesis that silently burned the supply would be unrecoverable
        vm.deal(owner, 1);
        vm.prank(owner);
        vm.expectRevert(Exchequer.GenesisDidNotAbsorbSupply.selector);
        fresh.initialize{value: 1}(GENESIS_TICK, address(vault), address(freshAuctions));

        assertFalse(lens.initialized(fresh), "genesis can still be run properly");
        assertEq(IssueToken(lens.issueToken(fresh)).totalMinted(), 0, "and nothing was minted");
    }

    function test_the_vault_must_be_the_banks_own_and_buy_the_reserve_asset() public {
        (Exchequer fresh,, ExchequerAuctions freshAuctions) = _freshBank(0xf00f);
        vm.deal(owner, 2 * GENESIS_ETH);

        // Owned by someone else: its owner could collect the gold
        ExchequerVault foreign = new ExchequerVault(alice, orders, address(gold));
        vm.prank(owner);
        vm.expectRevert(Exchequer.VaultNotOwnedByBank.selector);
        fresh.initialize{value: GENESIS_ETH}(GENESIS_TICK, address(foreign), address(freshAuctions));

        // Buying the wrong asset: every flush would strand
        ExchequerVault wrongAsset = new ExchequerVault(address(fresh), orders, address(issue));
        vm.prank(owner);
        vm.expectRevert(Exchequer.VaultBuysWrongAsset.selector);
        fresh.initialize{value: GENESIS_ETH}(GENESIS_TICK, address(wrongAsset), address(freshAuctions));
    }

    function test_the_auctions_must_be_for_this_bank() public {
        (Exchequer fresh, ExchequerVault vault,) = _freshBank(0xf010);
        vm.deal(owner, GENESIS_ETH);

        // The main fixture's auctions open branches for the main bank, not this one
        vm.prank(owner);
        vm.expectRevert(Exchequer.AuctionsNotForThisBank.selector);
        fresh.initialize{value: GENESIS_ETH}(GENESIS_TICK, address(vault), address(auctions));
    }

    function test_owner_can_renounce_irreversibly() public {
        vm.prank(owner);
        bank.renounceOwnership();
        assertEq(lens.owner(bank), address(0), "no board");

        vm.prank(owner);
        vm.expectRevert(Ownable.Unauthorized.selector);
        bank.setTeamRecipient(alice);
    }
}
