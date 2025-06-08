// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {PriceFetcher} from "../src/lens/PriceFetcher.sol";
import {Oracle} from "../src/extensions/Oracle.sol";
import {IForwardee} from "../src/interfaces/IFlashAccountant.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {CoreDataFetcher} from "../src/lens/CoreDataFetcher.sol";
import {Router} from "../src/Router.sol";
import {TokenDataFetcher} from "../src/lens/TokenDataFetcher.sol";
import {QuoteDataFetcher} from "../src/lens/QuoteDataFetcher.sol";

contract DeployStatelessScript is Script {
    function run() public {
        ICore core = ICore(payable(vm.envAddress("CORE_ADDRESS")));
        Oracle oracle = Oracle(vm.envAddress("ORACLE_ADDRESS"));

        bytes32 salt = vm.envOr("SALT", bytes32(0x0));

        vm.startBroadcast();

        new Router{salt: salt}(core);
        new PriceFetcher{salt: salt}(oracle);
        new CoreDataFetcher{salt: salt}(core);
        new QuoteDataFetcher{salt: salt}(core);
        new TokenDataFetcher{salt: salt}();

        vm.stopBroadcast();
    }
}
