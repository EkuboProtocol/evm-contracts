// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BasePositions} from "../src/base/BasePositions.sol";
import {FreePositions} from "../src/FreePositions.sol";
import {Positions} from "../src/Positions.sol";
import {Orders} from "../src/Orders.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {ITWAMM} from "../src/interfaces/extensions/ITWAMM.sol";

/// @title DeployManagers
/// @notice Deploys the Positions/Orders managers with configurable metadata and fees
contract DeployManagers is Script {
    BasePositions public positions;
    Orders public orders;

    function run() public {
        address deployer = vm.envOr("OWNER_ADDRESS", vm.getWallets()[0]);

        bytes32 salt = vm.envOr("SALT", bytes32(0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd));
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(0x00000000000014aA86C5d3c41765bb24e11bd701))));
        ITWAMM twamm = ITWAMM(vm.envOr("TWAMM_ADDRESS", address(0xd4F1060cB9c1A13e1d2d20379b8aa2cF7541eD9b)));

        string memory positionsBaseUrl = _envStringOr("POSITIONS_BASE_URL", "https://prod-api.ekubo.org/positions/");
        string memory ordersBaseUrl = _envStringOr("ORDERS_BASE_URL", "https://prod-api.ekubo.org/orders/");

        uint64 swapProtocolFeeX64 = uint64(vm.envOr("SWAP_PROTOCOL_FEE_X64", uint256(1844674407370955161)));
        uint64 withdrawalProtocolFeeDenominator = uint64(vm.envOr("WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR", uint256(0)));

        vm.startBroadcast();

        if (swapProtocolFeeX64 == 0 && withdrawalProtocolFeeDenominator == 0) {
            console2.log("Deploying FreePositions...");
            positions = new FreePositions{salt: salt}(core, deployer);
        } else {
            console2.log("Deploying Positions...");
            positions = new Positions{salt: salt}(core, deployer, swapProtocolFeeX64, withdrawalProtocolFeeDenominator);
        }
        console2.log("Positions deployed at", address(positions));

        positions.setMetadata({newName: "Ekubo Positions", newSymbol: "ekuPo", newBaseUrl: positionsBaseUrl});
        console2.log("Set positions metadata");

        console2.log("Deploying Orders...");
        orders = new Orders{salt: salt}(core, twamm, deployer);
        console2.log("Orders deployed at", address(orders));

        orders.setMetadata({newName: "Ekubo DCA Orders", newSymbol: "ekuOrd", newBaseUrl: ordersBaseUrl});
        console2.log("Set orders metadata");

        vm.stopBroadcast();
    }

    function _envStringOr(string memory key, string memory defaultValue) internal returns (string memory value) {
        try vm.envString(key) returns (string memory envValue) {
            value = envValue;
        } catch {
            value = defaultValue;
        }
    }
}
