// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {SimpleSwapper, SimpleQuoter} from "../src/SimpleSwapper.sol";
import {BaseURLTokenURIGenerator} from "../src/BaseURLTokenURIGenerator.sol";
import {PriceFetcher} from "../src/lens/PriceFetcher.sol";
import {Oracle} from "../src/extensions/Oracle.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {CoreDataFetcher} from "../src/lens/CoreDataFetcher.sol";
import {Router} from "../src/Router.sol";
import {TokenDataFetcher} from "../src/lens/TokenDataFetcher.sol";

contract DeployScript is Script {
    error UnrecognizedChainId(uint256 chainId);

    function run() public {
        ICore core;
        Oracle oracle;
        if (block.chainid == 1) {
            core = ICore(payable(0x39D8aB62FCaA5B466eB8397187732b6BA455aaa8));
            oracle = Oracle(0x51ee1902db6D5640163506b9e178A21Ff027282c);
        } else if (block.chainid == 11155111) {
            core = ICore(payable(0x95c26D0C07DD774afc3c82a29F2cb301EE535e25));
            oracle = Oracle(0x51373cFE405C627956FCCB44fa0933Dd48b6151D);
        } else {
            revert UnrecognizedChainId(block.chainid);
        }

        vm.startBroadcast();

        new Router(core);
        // new PriceFetcher(oracle);
        // new CoreDataFetcher(core);
        // new SimpleSwapper(core);
        // new SimpleQuoter(core);
        // new TokenDataFetcher();

        vm.stopBroadcast();
    }
}
