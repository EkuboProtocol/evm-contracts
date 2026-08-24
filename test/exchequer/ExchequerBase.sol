// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";

import {Core} from "../../src/Core.sol";
import {Orders} from "../../src/Orders.sol";
import {Positions} from "../../src/Positions.sol";
import {Router} from "../../src/Router.sol";
import {TWAMM, twammCallPoints} from "../../src/extensions/TWAMM.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {NATIVE_TOKEN_ADDRESS} from "../../src/math/constants.sol";
import {BankToken} from "../../src/exchequer/BankToken.sol";
import {Exchequer, ExchequerParameters, exchequerCallPoints} from "../../src/exchequer/Exchequer.sol";
import {ExchequerAuctions} from "../../src/exchequer/ExchequerAuctions.sol";
import {IssueToken} from "../../src/exchequer/IssueToken.sol";
import {ExchequerVault} from "../../src/exchequer/ExchequerVault.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {TestToken} from "../TestToken.sol";

/// @notice Shared fixture for the Exchequer economy: one market, one bank, two vaults, two auctions
abstract contract ExchequerBase is Test {
    /// @dev 0.30% expressed as the 0.64 fixed point fraction Core uses
    uint64 internal constant TRADING_FEE = uint64((uint256(3) << 64) / 1000);

    /// @dev Tick at which one ETH buys roughly one million $ISSUE, aligned to the tick spacing
    int32 internal constant GENESIS_TICK = 13815000;

    uint32 internal constant TICK_SPACING = 1000;

    /// @dev Permissive slippage bound; the sentinel `type(int256).min` is reserved by the router
    int256 internal constant NO_SLIPPAGE_LIMIT = type(int256).min + 1;

    /// @dev Seeded generously, so the genesis position is limited by the currency rather than by ETH
    uint256 internal constant GENESIS_ETH = 200 ether;

    address internal immutable owner = makeAddr("owner");
    address internal immutable team = makeAddr("team");
    address internal immutable alice = makeAddr("alice");
    address internal immutable bob = makeAddr("bob");
    address internal immutable trader = makeAddr("trader");

    Core internal core;
    TWAMM internal twamm;
    Orders internal orders;
    Positions internal positions;
    Router internal router;

    Exchequer internal bank;
    IssueToken internal issue;
    BankToken internal bankToken;
    ExchequerAuctions internal auctions;
    ExchequerVault internal expansionVault;
    TestToken internal gold;

    function setUp() public virtual {
        vm.warp(1_700_000_000);

        core = new Core();
        positions = new Positions(core, owner, 0, 1);

        address twammAddress = address((uint160(twammCallPoints().toUint8()) << 152) + 0x7a33);
        deployCodeTo("TWAMM.sol:TWAMM", abi.encode(core), twammAddress);
        twamm = TWAMM(twammAddress);
        orders = new Orders(core, twamm, owner);

        gold = new TestToken(address(this));

        address bankAddress = address((uint160(exchequerCallPoints().toUint8()) << 152) + 0xba4e);
        deployCodeTo(
            "Exchequer.sol:Exchequer", abi.encode(core, owner, address(gold), defaultParameters()), bankAddress
        );
        bank = Exchequer(payable(bankAddress));
        issue = bank.ISSUE_TOKEN();
        bankToken = bank.BANK_TOKEN();

        // The stock router drives this pool unmodified when the bank occupies the ve33 slot
        router = new Router(core, address(0), address(bank));

        expansionVault = new ExchequerVault(address(bank), orders, address(gold));

        auctions = new ExchequerAuctions({
            owner: owner, bank: bank, licensesPerDay: 100, licenseFloorYieldDays: 2, licenseFloorMinimum: 1e18
        });

        vm.startPrank(owner);
        bank.setExpansionVault(address(expansionVault));
        bank.setAuctions(address(auctions));
        bank.setTeamRecipient(team);
        vm.stopPrank();

        vm.deal(owner, GENESIS_ETH);
        vm.prank(owner);
        bank.initialize{value: GENESIS_ETH}(GENESIS_TICK);

        vm.deal(address(this), 100_000 ether);
        vm.deal(trader, 10_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
    }

    function defaultParameters() internal pure returns (ExchequerParameters memory) {
        return ExchequerParameters({
            baseIssuancePerDay: 1_000_000e18,
            multiplierMin: 0.25e18,
            multiplierMax: 4e18,
            multiplierLaunch: 1e18,
            multiplierCutStep: 0.25e18,
            multiplierRaiseStep: 0.0625e18,
            epochLength: 1 days,
            tradingFee: TRADING_FEE,
            tickSpacing: TICK_SPACING,
            resolutionFeeFloor: 0.01e18,
            resolutionFeeCeiling: 0.3e18,
            exitPressureSaturation: 0.25e18,
            exitPressureDenominatorFloor: 1_000_000e18,
            polReferenceWindow: 1 hours,
            redistributionStreamLength: 7 days
        });
    }

    /// @notice Grants `to` `amount` of $BANK through the founding distribution
    function giveShares(address to, uint256 amount) internal {
        vm.prank(owner);
        bank.mintFoundingBank(to, amount);
    }

    /// @notice Buys $ISSUE with an exact amount of ETH, delivered to `who`
    /// @dev Exact-in token0 pushes the price down, so the bound is the minimum sqrt ratio. The test
    ///      contract is the swapper, because a pranked sender does not fund `msg.value`.
    function buy(address who, uint128 ethIn) internal returns (int128 delta0, int128 delta1) {
        PoolBalanceUpdate update = router.swap{value: ethIn}(
            bank.poolKey(), createSwapParameters(MIN_SQRT_RATIO, int128(ethIn), false, 0), NO_SLIPPAGE_LIMIT, who
        );
        (delta0, delta1) = (update.delta0(), update.delta1());
    }

    /// @notice Sells an exact amount of $ISSUE for ETH
    function sell(address who, uint128 issueIn) internal returns (int128 delta0, int128 delta1) {
        vm.startPrank(who);
        issue.approve(address(router), issueIn);
        PoolBalanceUpdate update = router.swap(
            bank.poolKey(), createSwapParameters(MAX_SQRT_RATIO, int128(issueIn), true, 0), NO_SLIPPAGE_LIMIT, who
        );
        vm.stopPrank();
        (delta0, delta1) = (update.delta0(), update.delta1());
    }

    function advanceDays(uint256 count) internal {
        vm.warp(vm.getBlockTimestamp() + count * 1 days);
    }
}
