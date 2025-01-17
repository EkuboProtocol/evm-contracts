// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console} from "forge-std/Script.sol";
import {Core} from "../src/Core.sol";
import {Positions, ITokenURIGenerator} from "../src/Positions.sol";
import {Router} from "../src/Router.sol";
import {Oracle} from "../src/extensions/Oracle.sol";
import {BaseURLTokenURIGenerator} from "../src/BaseURLTokenURIGenerator.sol";

import {WETH} from "solady/tokens/WETH.sol";

contract DeployScript is Script {
    error UnrecognizedChainId(uint256 chainId);

    address public owner = vm.envAddress("OWNER");

    Core public core;
    ITokenURIGenerator public tokenURIGenerator;
    Positions public positions;
    Router public router;
    Oracle public oracle;

    // function setUp() public {}

    function run() public {
        vm.startBroadcast();

        WETH weth;
        string memory baseUrl;
        address ekuboToken;
        if (block.chainid == 1) {
            // mainnet
            // https://etherscan.io/token/0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2
            weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
            baseUrl = "https://mainnet-evm-api.ekubo.org/";
            ekuboToken = 0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f;
        } else if (block.chainid == 11155111) {
            // sepolia
            // https://sepolia.etherscan.io/token/0x7b79995e5f793a07bc00c21412e50ecae098e7f9
            weth = WETH(payable(0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9));
            baseUrl = "https://sepolia-evm-api.ekubo.org/";
            ekuboToken = 0x618C25b11a5e9B5Ad60B04bb64FcBdfBad7621d1;
        } else {
            revert UnrecognizedChainId(block.chainid);
        }

        core = new Core{salt: 0x0}(owner);
        tokenURIGenerator = new BaseURLTokenURIGenerator(owner, baseUrl);
        positions = new Positions{salt: 0x0}(core, tokenURIGenerator, weth);
        router = new Router{salt: 0x0}(core, weth);
        oracle = new Oracle{salt: 0x0}(core, ekuboToken);

        vm.stopBroadcast();
    }
}
