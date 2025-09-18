// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import "forge-std/Test.sol";
import {Core} from "../src/Core.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {TestToken} from "./TestToken.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {ILocker} from "../src/interfaces/IFlashAccountant.sol";

contract WithdrawMultipleTest is Test, ILocker {
    using CoreLib for ICore;

    Core core;
    TestToken token0;
    TestToken token1;
    address recipient = address(0x1234);

    string private currentAction;
    bytes private currentData;

    function setUp() public {
        core = new Core();
        token0 = new TestToken(address(core));
        token1 = new TestToken(address(core));

        // Give core some ETH for native token withdrawals
        vm.deal(address(core), 10 ether);
    }

    function testWithdrawSingle() public {
        uint128 amount = 100e18;

        // Test single token withdrawal using CoreLib
        currentAction = "withdrawSingle";
        currentData = abi.encode(address(token0), recipient, amount);

        core.lock();

        assertEq(token0.balanceOf(recipient), amount);
    }

    function testWithdrawTwo() public {
        uint128 amount0 = 100e18;
        uint128 amount1 = 200e18;

        // Test two token withdrawal using CoreLib
        currentAction = "withdrawTwo";
        currentData = abi.encode(address(token0), address(token1), recipient, amount0, amount1);

        core.lock();

        assertEq(token0.balanceOf(recipient), amount0);
        assertEq(token1.balanceOf(recipient), amount1);
    }

    function testWithdrawMultipleDirectly() public {
        uint128 amount0 = 50e18;
        uint128 amount1 = 75e18;

        // Test direct withdrawMultiple call
        currentAction = "withdrawMultipleDirect";
        currentData = abi.encode(address(token0), recipient, amount0, address(token1), recipient, amount1);

        core.lock();

        assertEq(token0.balanceOf(recipient), amount0);
        assertEq(token1.balanceOf(recipient), amount1);
    }

    function locked(uint256) external {
        if (keccak256(bytes(currentAction)) == keccak256("withdrawSingle")) {
            (address token, address to, uint128 amount) = abi.decode(currentData, (address, address, uint128));
            ICore(core).withdrawSingle(token, to, amount);
        } else if (keccak256(bytes(currentAction)) == keccak256("withdrawTwo")) {
            (address token0_, address token1_, address to, uint128 amount0, uint128 amount1) =
                abi.decode(currentData, (address, address, address, uint128, uint128));
            ICore(core).withdrawTwo(token0_, token1_, to, amount0, amount1);
        } else if (keccak256(bytes(currentAction)) == keccak256("withdrawMultipleDirect")) {
            // Manually construct the calldata for withdrawMultiple
            (address token0_, address to0, uint128 amount0, address token1_, address to1, uint128 amount1) =
                abi.decode(currentData, (address, address, uint128, address, address, uint128));

            // Call withdrawMultiple directly with packed calldata
            bytes memory callData =
                abi.encodePacked(core.withdrawMultiple.selector, token0_, to0, amount0, token1_, to1, amount1);

            (bool success,) = address(core).call(callData);
            require(success, "withdrawMultiple failed");
        }
    }
}
