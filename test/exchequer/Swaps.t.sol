// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ExchequerBase} from "./ExchequerBase.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {amountBeforeFee, computeFee} from "../../src/math/fee.sol";
import {Exchequer} from "../../src/exchequer/Exchequer.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, SqrtRatio} from "../../src/types/sqrtRatio.sol";

/// @notice Attempts a swap without going through `Core.forward`
contract DirectSwapper is BaseLocker {
    using CoreLib for ICore;

    ICore private immutable CORE_REF;

    constructor(ICore core) BaseLocker(core) {
        CORE_REF = core;
    }

    function swapDirectly(PoolKey memory key, SwapParameters params) external {
        lock(abi.encode(key, params));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory key, SwapParameters params) = abi.decode(data, (PoolKey, SwapParameters));
        CORE_REF.swap(0, key, params);
        return "";
    }
}

contract SwapsTest is ExchequerBase {
    using CoreLib for *;

    uint256 internal constant BRANCH = 1e18;

    function setUp() public override {
        super.setUp();
        giveShares(alice, BRANCH);
    }

    function test_swaps_must_arrive_through_forward() public {
        DirectSwapper swapper = new DirectSwapper(core);
        // Read the pool key first: `expectRevert` binds to the very next call
        PoolKey memory key = bank.poolKey();
        SwapParameters params = createSwapParameters(MIN_SQRT_RATIO, 1 ether, false, 0);

        vm.expectRevert(Exchequer.SwapMustHappenThroughForward.selector);
        swapper.swapDirectly(key, params);
    }

    function test_exact_input_eth_charges_the_fee_off_the_top() public {
        uint128 ethIn = 1 ether;
        uint256 balanceBefore = address(this).balance;

        (int128 delta0,) = buy(trader, ethIn);

        assertEq(uint256(int256(delta0)), ethIn, "the trader's specified amount stays exact");
        assertEq(balanceBefore - address(this).balance, ethIn, "and that is all the swapper parts with");
        assertEq(bank.savedEth(), computeFee(ethIn, TRADING_FEE), "the fee is taken in ETH");
    }

    function test_selling_pays_the_fee_out_of_the_eth_proceeds() public {
        buy(trader, 10 ether);
        uint128 held = uint128(issue.balanceOf(trader));

        uint128 feeBefore = bank.savedEth();
        uint256 ethBefore = trader.balance;

        (int128 delta0,) = sell(trader, held / 2);

        uint128 received = uint128(uint256(-int256(delta0)));
        assertEq(trader.balance - ethBefore, received, "the trader receives the post-fee amount");

        uint128 feeCharged = bank.savedEth() - feeBefore;
        assertGt(feeCharged, 0, "sells pay a fee too");
        // The fee is a cut of the gross amount the pool released, not of what survived it
        assertEq(feeCharged, amountBeforeFee(received, TRADING_FEE) - received, "charged on the gross ETH out");
    }

    function test_a_partly_filled_swap_pays_a_fee_only_on_what_traded() public {
        // A price limit just below spot stops the swap long before the offered ETH is consumed
        PoolState state = core.poolState(bank.poolKey().toPoolId());
        SqrtRatio limit = tickToSqrtRatio(state.tick() - 200);

        uint256 balanceBefore = address(this).balance;

        PoolBalanceUpdate update = router.swapAllowPartialFill{value: 100 ether}(
            bank.poolKey(), createSwapParameters(limit, int128(uint128(100 ether)), false, 0), trader
        );

        uint128 consumed = uint128(update.delta0());
        assertLt(consumed, 100 ether, "the limit stopped the swap short");

        uint256 spent = balanceBefore - address(this).balance;
        assertEq(spent, consumed, "the trader parts with exactly the filled amount");

        uint128 fee = bank.savedEth();
        assertGt(fee, 0, "a fee was still charged");
        assertLt(fee, computeFee(100 ether, TRADING_FEE), "but not on the unfilled remainder");
        // The fee is the trading rate applied to what actually traded, not to what was offered
        assertApproxEqRel(fee, computeFee(consumed, TRADING_FEE), 0.001e18, "priced on the fill");
    }

    function test_both_directions_feed_the_bank_eth() public {
        buy(trader, 5 ether);
        uint128 afterBuy = bank.savedEth();
        assertGt(afterBuy, 0, "buys pay");

        sell(trader, uint128(issue.balanceOf(trader)));
        assertGt(bank.savedEth(), afterBuy, "sells pay as well");
    }

    function test_net_flow_is_measured_in_real_capital() public {
        buy(trader, 3 ether);
        (int256 current,,) = bank.netFlows();
        assertEq(current, int256(3 ether), "gross ETH in from the buy");

        (int128 delta0,) = sell(trader, uint128(issue.balanceOf(trader)));
        (current,,) = bank.netFlows();
        assertEq(current, int256(3 ether) + int256(delta0), "less gross ETH out from the sell");
        assertLt(current, int256(3 ether), "a round trip leaves less than it brought");
    }

    function test_an_expansion_epoch_stacks_reserves() public {
        buy(trader, 10 ether);
        uint128 fees = bank.savedEth();

        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();

        assertEq(bank.pendingExpansionEth(), (uint256(fees) * 70) / 100, "70% to the expansion vault");
        assertEq(bank.pendingContractionEth(), 0, "nothing to defend against");
        assertEq(bank.pendingPolEth() > 0, true, "15% compounds into liquidity");
        assertEq(bank.pendingTeamEth(), fees - bank.pendingExpansionEth() - (uint256(fees) * 15) / 100, "15% to team");
    }

    function test_a_contraction_epoch_finances_buybacks() public {
        // Buy in one epoch, then sell more than was bought in the next
        buy(trader, 10 ether);
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();

        uint128 feesBefore = bank.savedEth();
        sell(trader, uint128(issue.balanceOf(trader)));
        uint128 epochFees = bank.savedEth() - feesBefore;

        (int256 current,,) = bank.netFlows();
        assertLt(current, 0, "capital left this epoch");

        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();

        assertEq(bank.pendingContractionEth(), (uint256(epochFees) * 70) / 100, "70% flips to buybacks");
    }

    function test_the_split_is_exhaustive() public {
        buy(trader, 7.77 ether);
        uint128 fees = bank.savedEth();

        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();

        uint256 routed =
            bank.pendingExpansionEth() + bank.pendingContractionEth() + bank.pendingPolEth() + bank.pendingTeamEth();
        // The genesis leftover also sits in the POL bucket, so compare against the epoch's fees
        assertEq(routed, uint256(fees) + bank.pendingPolEth() - ((uint256(fees) * 15) / 100), "no wei is lost");
    }

    function test_flush_delivers_eth_to_the_expansion_vault() public {
        buy(trader, 10 ether);
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();

        uint128 expected = bank.pendingExpansionEth();

        bank.flush();

        assertEq(address(expansionVault).balance, expected, "the expansion vault is funded");
        assertEq(bank.pendingExpansionEth(), 0, "the bucket is cleared");
        assertEq(bank.savedEth(), 0, "the fee balance was drawn out of Core");
    }

    function test_the_team_share_is_pulled_separately() public {
        buy(trader, 10 ether);
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();

        uint128 expectedTeam = bank.pendingTeamEth();
        assertGt(expectedTeam, 0, "the team earned something");

        vm.prank(bob);
        bank.collectTeamShare();

        assertEq(team.balance, expectedTeam, "anyone may deliver it");
        assertEq(bank.pendingTeamEth(), 0, "and it is cleared");
    }

    function test_a_team_recipient_that_rejects_eth_cannot_block_the_vault() public {
        // A recipient with no receive function
        vm.prank(owner);
        bank.setTeamRecipient(address(issue));

        buy(trader, 10 ether);
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();

        // The vault is still funded
        bank.flush();
        assertGt(address(expansionVault).balance, 0, "flush is unaffected");

        // Only the team's own delivery fails, and their share simply waits
        vm.expectRevert();
        bank.collectTeamShare();
        assertGt(bank.pendingTeamEth(), 0, "held for a recipient that can take it");
    }

    receive() external payable {}
}
