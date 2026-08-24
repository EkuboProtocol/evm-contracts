// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ICore} from "../src/interfaces/ICore.sol";
import {IOrders} from "../src/interfaces/IOrders.sol";
import {Exchequer, ExchequerParameters, exchequerCallPoints} from "../src/exchequer/Exchequer.sol";
import {ExchequerAuctions} from "../src/exchequer/ExchequerAuctions.sol";
import {ExchequerVault} from "../src/exchequer/ExchequerVault.sol";
import {deployExtension, deployIfNeeded} from "./DeployAll.s.sol";

/// @title DeployExchequer
/// @notice Deploys the Exchequer economy: the central bank extension, both vaults, and both auctions
/// @dev The whitepaper redacts every monetary parameter and says final values arrive closer to
///      launch, so the values below are documented defaults rather than authoritative ones. See
///      docs/exchequer.md for the reasoning behind each.
///
///      After this script runs, genesis still requires four owner actions:
///        1. `bank.initialize{value: seedEth}(tick)`, which mints the 100,000,000 genesis supply and
///           locks it into the full-range protocol-owned position;
///        2. `bank.configureVault(vault, targetOrderDuration, minOrderDuration, fee)` for each vault,
///           once the ETH/$ISSUE and ETH/reserve-asset TWAMM pools at that fee tier exist;
///        3. `bank.mintFoundingBank(...)` for the free founding distribution, up to 1,000 $BANK,
///           normally pointed at `Incentives` for a one-per-wallet merkle claim;
///        4. `bank.renounceOwnership()`.
contract DeployExchequer is Script {
    address internal constant DEFAULT_CORE_ADDRESS = 0x00000000000014aA86C5d3c41765bb24e11bd701;
    bytes32 internal constant DEFAULT_DEPLOYMENT_SALT =
        0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;

    /// @notice The launch parameters documented in docs/exchequer.md
    function launchParameters() public pure returns (ExchequerParameters memory) {
        return ExchequerParameters({
            // 1,000,000 $ISSUE a day at a neutral multiplier
            baseIssuancePerDay: 1_000_000e18,
            multiplierMin: 0.25e18,
            multiplierMax: 4e18,
            multiplierLaunch: 1e18,
            // Cuts are four times the size of raises: the bank turns defensive faster than generous
            multiplierCutStep: 0.25e18,
            multiplierRaiseStep: 0.0625e18,
            epochLength: 1 days,
            // 0.30%, as a 0.64 fixed point fraction, always charged in ETH
            tradingFee: uint64((uint256(3) << 64) / 1000),
            tickSpacing: 1000,
            resolutionFeeFloor: 0.01e18,
            resolutionFeeCeiling: 0.3e18,
            // The fee saturates once a quarter of the bank tries to leave inside a week
            exitPressureSaturation: 0.25e18,
            exitPressureDenominatorFloor: 1_000_000e18,
            // A price must prevail for an hour to fully replace the bank's reference price
            polReferenceWindow: 1 hours,
            // and the bank never compounds more than about half a percent above that reference
            polMaxPremiumTicks: 5000
        });
    }

    function run()
        public
        returns (Exchequer bank, ExchequerVault expansion, ExchequerVault contraction, ExchequerAuctions auctions)
    {
        bytes32 salt = vm.envOr("SALT", DEFAULT_DEPLOYMENT_SALT);
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(DEFAULT_CORE_ADDRESS))));
        IOrders orders = IOrders(vm.envAddress("ORDERS_ADDRESS"));
        address owner = vm.envOr("OWNER_ADDRESS", vm.getWallets()[0]);
        // The hard reserve asset, fixed for the life of the contract
        address reserveAsset = vm.envAddress("RESERVE_ASSET");

        vm.startBroadcast();

        // The extension address must encode its call points, so the salt is mined
        (address bankAddress,) = deployExtension(
            abi.encodePacked(type(Exchequer).creationCode, abi.encode(core, owner, reserveAsset, launchParameters())),
            salt,
            exchequerCallPoints(),
            address(0),
            "Exchequer"
        );
        bank = Exchequer(payable(bankAddress));

        // The bank owns both vaults, so nothing they buy can land anywhere else
        expansion = new ExchequerVault(bankAddress, orders, reserveAsset);
        contraction = new ExchequerVault(bankAddress, orders, address(bank.ISSUE_TOKEN()));

        auctions = new ExchequerAuctions({
            owner: owner,
            bank: bank,
            // 100 expansion licenses a day
            licensesPerDay: 100,
            // The floor is worth about two days of one branch's yield
            licenseFloorYieldDays: 2,
            // and never falls below one whole token, so a day cannot open at zero
            licenseFloorMinimum: 1e18
        });

        bank.setVaults(address(expansion), address(contraction));
        bank.setAuctions(address(auctions));

        vm.stopBroadcast();

        console2.log("Exchequer", bankAddress);
        console2.log("ISSUE", address(bank.ISSUE_TOKEN()));
        console2.log("BANK", address(bank.BANK_TOKEN()));
        console2.log("ExpansionVault", address(expansion));
        console2.log("ContractionVault", address(contraction));
        console2.log("ExchequerAuctions", address(auctions));
    }
}
