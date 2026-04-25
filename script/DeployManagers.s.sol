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
import {deployIfNeeded} from "./DeployAll.s.sol";

/// @title DeployManagers
/// @notice Deploys the Positions/Orders managers with configurable metadata and fees
contract DeployManagers is Script {
    BasePositions public positions;
    Orders public orders;

    function run() public {
        address deployer = vm.envOr("OWNER_ADDRESS", vm.getWallets()[0]);

        bytes32 salt = vm.envOr("SALT", bytes32(0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd));
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(0x00000000000014aA86C5d3c41765bb24e11bd701))));
        ITWAMM twamm = ITWAMM(vm.envOr("TWAMM_ADDRESS", address(0xd47f1B1eDCfEaBb08F6eBd8FC337c27E636C75BA)));

        string memory positionsBaseUrl = _envStringOr("POSITIONS_BASE_URL", "https://prod-api.ekubo.org/positions/");
        string memory ordersBaseUrl = _envStringOr("ORDERS_BASE_URL", "https://prod-api.ekubo.org/orders/");

        uint64 swapProtocolFeeX64 = uint64(vm.envOr("SWAP_PROTOCOL_FEE_X64", uint256(1844674407370955161)));
        uint64 withdrawalProtocolFeeDenominator = uint64(vm.envOr("WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR", uint256(0)));

        vm.startBroadcast();

        bytes memory positionsInitCode;
        string memory positionsName;
        if (swapProtocolFeeX64 == 0 && withdrawalProtocolFeeDenominator == 0) {
            positionsInitCode = abi.encodePacked(type(FreePositions).creationCode, abi.encode(core, deployer));
            positionsName = "FreePositions";
        } else {
            positionsInitCode = abi.encodePacked(
                type(Positions).creationCode,
                abi.encode(core, deployer, swapProtocolFeeX64, withdrawalProtocolFeeDenominator)
            );
            positionsName = "Positions";
        }

        bool deployedPositions;
        address positionsAddress;
        (positionsAddress, deployedPositions) = deployIfNeeded(positionsInitCode, salt, address(0), positionsName);
        positions = BasePositions(positionsAddress);

        if (deployedPositions) {
            positions.setMetadata({newName: "Ekubo Positions", newSymbol: "ekuPo", newBaseUrl: positionsBaseUrl});
            console2.log("Set positions metadata");
        }

        bool deployedOrders;
        address ordersAddress;
        (ordersAddress, deployedOrders) = deployIfNeeded(
            abi.encodePacked(type(Orders).creationCode, abi.encode(core, twamm, deployer)), salt, address(0), "Orders"
        );
        orders = Orders(ordersAddress);

        if (deployedOrders) {
            orders.setMetadata({newName: "Ekubo DCA Orders", newSymbol: "ekuOrd", newBaseUrl: ordersBaseUrl});
            console2.log("Set orders metadata");
        }

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
