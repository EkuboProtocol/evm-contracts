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
/// @notice Deploys the Exchequer economy: the central bank extension, the expansion vault, and the
///         auctions, deterministically, and hands the bank to its owner once wired
/// @dev The whitepaper redacts every monetary parameter and says final values arrive closer to
///      launch, so the values below are documented defaults rather than authoritative ones. See
///      docs/exchequer.md for the reasoning behind each.
///
///      The bank is constructed with the broadcaster as owner so the one-shot wiring can happen in
///      the same run, then ownership is transferred to `OWNER_ADDRESS`. Every contract is deployed
///      through CREATE2 at a salt derived from the deployment salt, so a re-run is a no-op.
///
///      After this script runs, genesis still requires four owner actions:
///        1. `bank.initialize{value: seedEth}(tick)`, which mints the 100,000,000 genesis supply and
///           locks it into the full-range protocol-owned position;
///        2. `bank.configureExpansionVault(targetOrderDuration, minOrderDuration, fee)`, once the
///           ETH/reserve-asset TWAMM pool at that fee tier exists;
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
            // The redistributed half of each resolution fee streams to stayers over the exit window
            redistributionStreamLength: 7 days,
            // An epoch is expansionary only on at least one ETH of net inflow, so the signal costs
            // real capital to move rather than one wei
            minNetFlow: 1 ether
        });
    }

    function run() public returns (Exchequer bank, ExchequerVault expansion, ExchequerAuctions auctions) {
        bytes32 salt = vm.envOr("SALT", DEFAULT_DEPLOYMENT_SALT);
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(DEFAULT_CORE_ADDRESS))));
        IOrders orders = IOrders(vm.envAddress("ORDERS_ADDRESS"));
        address owner = vm.envOr("OWNER_ADDRESS", vm.getWallets()[0]);
        // The hard reserve asset, fixed for the life of the contract
        address reserveAsset = vm.envAddress("RESERVE_ASSET");

        vm.startBroadcast();

        address deployer = msg.sender;

        // The extension address must encode its call points, so the salt is mined. The broadcaster
        // owns the bank until it is wired.
        (address bankAddress,) = deployExtension(
            abi.encodePacked(
                type(Exchequer).creationCode, abi.encode(core, deployer, reserveAsset, launchParameters())
            ),
            salt,
            exchequerCallPoints(),
            address(0),
            "Exchequer"
        );
        bank = Exchequer(payable(bankAddress));

        // The bank owns the vault, so nothing it buys can land anywhere else
        (address vaultAddress,) = deployIfNeeded(
            abi.encodePacked(type(ExchequerVault).creationCode, abi.encode(bankAddress, orders, reserveAsset)),
            keccak256(abi.encode(salt, "ExchequerVault")),
            address(0),
            "ExchequerVault"
        );
        expansion = ExchequerVault(payable(vaultAddress));

        (address auctionsAddress,) = deployIfNeeded(
            abi.encodePacked(
                type(ExchequerAuctions).creationCode,
                abi.encode(
                    bank,
                    // 100 expansion licenses a day
                    uint256(100),
                    // The floor is worth about two days of one branch's yield
                    uint256(2),
                    // and never falls below one whole token, so a day cannot open at zero
                    uint256(1e18),
                    // Policy may offer at most 100 charters a day
                    uint256(100)
                )
            ),
            keccak256(abi.encode(salt, "ExchequerAuctions")),
            address(0),
            "ExchequerAuctions"
        );
        auctions = ExchequerAuctions(auctionsAddress);

        if (bank.expansionVault() == address(0)) bank.setExpansionVault(vaultAddress);
        if (bank.auctions() == address(0)) bank.setAuctions(auctionsAddress);
        if (owner != deployer && bank.owner() == deployer) bank.transferOwnership(owner);

        vm.stopBroadcast();

        console2.log("Exchequer", bankAddress);
        console2.log("ISSUE", address(bank.ISSUE_TOKEN()));
        console2.log("BANK", address(bank.BANK_TOKEN()));
        console2.log("ExpansionVault", address(expansion));
        console2.log("ExchequerAuctions", address(auctions));
    }
}
