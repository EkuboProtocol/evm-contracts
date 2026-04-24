// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {IRevenueBuybacks} from "../src/interfaces/IRevenueBuybacks.sol";

contract ConfigureRevenueBuybacks is Script {
    uint32 internal constant DEFAULT_MIN_ORDER_DURATION = 3 days;
    uint32 internal constant DEFAULT_TARGET_ORDER_DURATION = 7 days;
    uint64 internal constant DEFAULT_FEE = 55340232221128654; // 0.3%

    function run() public {
        IRevenueBuybacks buybacks = IRevenueBuybacks(payable(vm.envAddress("BUYBACKS_ADDRESS")));
        address token = vm.envAddress("SELL_TOKEN");
        uint32 targetOrderDuration = uint32(vm.envOr("TARGET_ORDER_DURATION", uint256(DEFAULT_TARGET_ORDER_DURATION)));
        uint32 minOrderDuration = uint32(vm.envOr("MIN_ORDER_DURATION", uint256(DEFAULT_MIN_ORDER_DURATION)));
        uint64 fee = uint64(vm.envOr("FEE", uint256(DEFAULT_FEE)));

        vm.startBroadcast();
        buybacks.configure(token, targetOrderDuration, minOrderDuration, fee);
        vm.stopBroadcast();
    }
}
