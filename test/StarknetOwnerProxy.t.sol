// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {StarknetOwnerProxy, IStarknetMessaging} from "../src/StarknetOwnerProxy.sol";

contract StarknetOwnerProxyTest is Test {
    StarknetOwnerProxy public proxy;

    function setUp() public {
        proxy = new StarknetOwnerProxy(IStarknetMessaging(address(0x1)), 123);
    }

    function test_get_payload_empty() public view {
        uint256[] memory expected = new uint256[](3);
        expected[0] = 0xdeadbeef;
        expected[1] = 123;
        expected[2] = 0;
        assertEq(proxy.getPayload(address(0xdeadbeef), 123, hex""), expected);
    }

    function test_get_payload_one_partial_word() public view {
        uint256[] memory expected = new uint256[](4);
        expected[0] = 0xdeadbeef;
        expected[1] = 123;
        expected[2] = 3;
        expected[3] = 0xabcdef << 224;
        assertEq(
            proxy.getPayload(address(0xdeadbeef), 123, hex"abcdef"),
            expected
        );
    }

    function test_get_payload_one_whole_word() public view {
        uint256[] memory expected = new uint256[](4);
        expected[0] = 0xdeadbeef;
        expected[1] = 123;
        expected[2] = 31;
        expected[
            3
        ] = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;

        assertEq(
            proxy.getPayload(
                address(0xdeadbeef),
                123,
                hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
            ),
            expected
        );
    }
    function test_get_payload_one_whole_word_and_one_byte() public view {
        uint256[] memory expected = new uint256[](5);
        expected[0] = 0xdeadbeef;
        expected[1] = 123;
        expected[2] = 32;
        expected[
            3
        ] = 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff;
        expected[
            4
        ] = 0xff000000000000000000000000000000000000000000000000000000000000;

        assertEq(
            proxy.getPayload(
                address(0xdeadbeef),
                123,
                hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
            ),
            expected
        );
    }
}
