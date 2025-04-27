// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {Positions} from "../src/Positions.sol";
import {Router} from "../src/Router.sol";
import {Orders} from "../src/Orders.sol";
import {SniperNoSniping} from "../src/SniperNoSniping.sol";

contract DeploySniperNoSniping is Script {
    function run() public {
        bytes32 salt = vm.envOr("SALT", bytes32(0x0));

        vm.startBroadcast();

        new SniperNoSniping{salt: salt}({
            _router: Router(0x9995855C00494d039aB6792f18e368e530DFf931),
            _positions: Positions(0xA37cc341634AFD9E0919D334606E676dbAb63E17),
            _orders: Orders(0xAE1430E3E089794bEaCBA260657FcD0F0967C18A),
            _orderDuration: 4096,
            _minLeadTime: 3600,
            _tokenTotalSupply: 1_000_000e18,
            _fee: uint64((uint256(1) << 64) / 100),
            _tickSpacing: 1000
        });

        vm.stopBroadcast();
    }
}
