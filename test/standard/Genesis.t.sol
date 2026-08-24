// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {StandardBase} from "./StandardBase.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {CentralBank} from "../../src/standard/CentralBank.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract GenesisTest is StandardBase {
    using CoreLib for *;

    function test_genesis_initializes_the_one_market() public view {
        PoolKey memory key = bank.poolKey();
        assertEq(key.token0, address(0), "eth is token0");
        assertEq(key.token1, address(issue), "standard is token1");

        PoolState state = core.poolState(key.toPoolId());
        assertTrue(state.isInitialized(), "pool initialized");
        assertGt(state.liquidity(), 0, "genesis liquidity present");
    }

    function test_genesis_is_the_only_premint() public view {
        // The whole 100M was minted, and whatever the chosen tick could not absorb was burned
        assertEq(issue.totalMinted(), bank.GENESIS_LIQUIDITY(), "only the genesis mint happened");
        assertEq(issue.totalSupply() + issue.totalBurned(), bank.GENESIS_LIQUIDITY(), "supply identity");
    }

    function test_genesis_currency_side_binds_so_only_dust_is_burned() public view {
        // The fixture seeds enough ETH that $ISSUE is the binding side of the position, so all
        // that is destroyed is the rounding dust the liquidity math could not place
        assertLt(issue.totalBurned(), 1e6, "only dust burned");
        assertGt(bank.pendingPolEth(), 90 ether, "the unabsorbed ETH is held for compounding");
    }

    function test_supply_ceiling_only_ever_falls() public view {
        assertEq(issue.maxSupply(), issue.HARD_CAP() - issue.totalBurned(), "eq 3.2");
        assertLe(issue.maxSupply(), issue.HARD_CAP(), "ceiling never rises");
    }

    function test_genesis_cannot_run_twice() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        vm.expectRevert(CentralBank.GenesisAlreadyRan.selector);
        bank.initialize{value: 1 ether}(GENESIS_TICK);
    }

    function test_only_owner_initializes() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        bank.initialize(GENESIS_TICK);
    }

    function test_no_second_pool_may_adopt_the_extension() public {
        PoolKey memory key = bank.poolKey();
        key.config = bank.POOL_CONFIG();
        key.token1 = address(gold);

        vm.expectRevert(CentralBank.IncorrectPoolKey.selector);
        core.initializePool(key, 0);
    }

    function test_owner_can_renounce_irreversibly() public {
        vm.prank(owner);
        bank.renounceOwnership();
        assertEq(bank.owner(), address(0), "no board");

        vm.prank(owner);
        vm.expectRevert(Ownable.Unauthorized.selector);
        bank.setTeamRecipient(alice);
    }
}
