// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {SimpleSwapper, SimpleQuoter} from "../src/SimpleSwapper.sol";
import {PriceFetcher} from "../src/lens/PriceFetcher.sol";
import {Oracle} from "../src/extensions/Oracle.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {CoreDataFetcher} from "../src/lens/CoreDataFetcher.sol";
import {Router} from "../src/Router.sol";
import {TokenDataFetcher} from "../src/lens/TokenDataFetcher.sol";

contract DeployScript is Script {
    function run() public {
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));
        Oracle oracle = Oracle(vm.envAddress("ORACLE_ADDRESS"));

        vm.startBroadcast();

        new Router{salt: 0x0}(core);
        new PriceFetcher{salt: 0x0}(oracle);
        new CoreDataFetcher{salt: 0x0}(core);
        new SimpleSwapper{salt: 0x0}(core);
        new SimpleQuoter{salt: 0x0}(core);
        new TokenDataFetcher{salt: 0x0}();

        vm.stopBroadcast();
    }
}
