// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

// Launch swaps through the production Yul router, unmodified. The fixture is the runtime code deployed at
// YUL_ROUTER on Base and Ethereum (identical on both; read at Base block 52,211,824). Its immutables are the
// canonical Core and its own address, so Core and the router are placed at those addresses. The route uses
// the router's generic `forwarded` hop with the forwardee taken from the pool config, as its SDK does.

import {Test} from "forge-std/Test.sol";
import {TestToken} from "./TestToken.sol";
import {ScheduledLaunch, scheduledLaunchCallPoints} from "../src/extensions/ScheduledLaunch.sol";
import {twammCallPoints} from "../src/extensions/TWAMM.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolConfig} from "../src/types/poolConfig.sol";

contract LaunchYulRouterTest is Test {
    address payable constant CORE = payable(0x00000000000014aA86C5d3c41765bb24e11bd701);
    address constant YUL_ROUTER = 0x7B2aA7Ecc0B5936b7C52E6259A19C3BA557d0748;
    bytes32 constant YUL_ROUTER_CODEHASH = 0x6fa0a732d67d2511a1fea42ae5cf7c7435f620fa2ecbd6712cc4d6b81f4a9c87;

    ScheduledLaunch extension;

    function setUp() public {
        vm.warp(1);
        deployCodeTo("Core.sol:Core", CORE);
        address twamm = address(uint160(twammCallPoints().toUint8()) << 152);
        deployCodeTo("TWAMM.sol", abi.encode(CORE), twamm);
        address target = address(uint160(scheduledLaunchCallPoints().toUint8()) << 152);
        deployCodeTo("ScheduledLaunch.sol", abi.encode(CORE, twamm), target);
        extension = ScheduledLaunch(target);
        vm.etch(YUL_ROUTER, vm.parseBytes(vm.trim(vm.readFile("test/fixtures/yul-router-runtime.hex"))));
        assertEq(YUL_ROUTER.codehash, YUL_ROUTER_CODEHASH, "fixture is the deployed router");
    }

    function _config(address quote) internal view returns (ScheduledLaunch.LaunchConfig memory) {
        return ScheduledLaunch.LaunchConfig({
            owner: address(this),
            quoteToken: quote,
            name: "Launch",
            symbol: "LAUNCH",
            decimals: 18,
            totalSupply: 1_000_000e18,
            quoteAmount: 0,
            startTime: 100,
            endTime: 1100,
            targetTick: 0,
            upperTick: 100_000,
            tickSpacing: 100,
            initialFee: uint64(uint256(1 << 64) / 10),
            finalFee: uint64(uint256(1 << 64) / 100),
            migrationTickLower: -1_151_292,
            migrationTickUpper: 1_151_293
        });
    }

    function _int128(int128 value) private pure returns (uint128 encoded) {
        assembly ("memory-safe") {
            encoded := value
        }
    }

    /// @dev One multi-hop with one `forwarded` hop, default price limit, paid by and paid to this contract.
    function _route(PoolKey memory key, address specified, address calculated, int128 amount, bool allowPartial)
        internal
        view
        returns (bytes memory)
    {
        return bytes.concat(
            bytes1(uint8(1)), // has recipient
            bytes1(uint8(0)), // one multi-hop
            bytes20(specified),
            bytes20(calculated),
            bytes16(_int128(1)), // minimum output
            bytes20(address(this)),
            bytes16(_int128(amount)),
            bytes1(uint8(0)), // one hop
            bytes1(uint8(1)), // forwarded hop
            bytes20(key.config.extension()),
            bytes20(key.token0),
            bytes20(key.token1),
            bytes32(PoolConfig.unwrap(key.config)),
            bytes12(uint96(0)),
            bytes4(allowPartial ? uint32(1 << 31) : uint32(0))
        );
    }

    function _decode(bytes memory result) internal pure returns (int256 specified, int256 calculated) {
        (,, specified, calculated) = abi.decode(result, (address, address, int256, int256));
    }

    function _swap(bytes memory route) internal returns (int256, int256) {
        (bool ok, bytes memory result) = YUL_ROUTER.call(route);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        return _decode(result);
    }

    function _quote(bytes memory route) internal returns (int256, int256) {
        (bool ok, bytes memory result) = YUL_ROUTER.call(abi.encodeWithSignature("quote(bytes)", route));
        assertTrue(ok, "quote");
        return _decode(result);
    }

    function test_yulRouterTradesAndQuotesLaunchPool() public {
        for (uint256 i; i < 2; i++) {
            uint256 snapshot = vm.snapshotState();
            address quote = i == 0 ? address(0x10000) : address(type(uint160).max);
            deployCodeTo("TestToken.sol", abi.encode(address(this)), quote);
            (PoolKey memory key, address token) = extension.create(_config(quote));
            assertEq(key.token0 == token, i == 1);
            TestToken(quote).approve(YUL_ROUTER, type(uint256).max);
            MintableERC20(token).approve(YUL_ROUTER, type(uint256).max);
            vm.warp(200);

            bytes memory buy = _route(key, quote, token, 1_000e18, false);
            (int256 quotedIn, int256 quotedOut) = _quote(buy);
            uint256 quoteBefore = TestToken(quote).balanceOf(address(this));
            (int256 paid, int256 bought) = _swap(buy);
            assertEq(paid, 1_000e18);
            assertEq(paid, quotedIn, "buy quote input");
            assertEq(bought, quotedOut, "buy quote output");
            assertEq(quoteBefore - TestToken(quote).balanceOf(address(this)), uint256(paid), "paid");
            assertEq(MintableERC20(token).balanceOf(address(this)), uint256(bought), "received");

            bytes memory sell = _route(key, token, quote, int128(bought / 2), false);
            (, quotedOut) = _quote(sell);
            quoteBefore = TestToken(quote).balanceOf(address(this));
            (, int256 sold) = _swap(sell);
            assertGt(sold, 0);
            assertEq(sold, quotedOut, "sell quote output");
            assertEq(TestToken(quote).balanceOf(address(this)) - quoteBefore, uint256(sold), "sell received");

            // A buy past the range top fills partially: a full-fill route reverts, allowPartial settles the fill.
            (bool ok,) = YUL_ROUTER.call(_route(key, quote, token, 900_000e18, false));
            assertFalse(ok, "full-fill route rejects a partial fill");
            quoteBefore = TestToken(quote).balanceOf(address(this));
            (paid,) = _swap(_route(key, quote, token, 900_000e18, true));
            assertLt(paid, 900_000e18);
            assertEq(quoteBefore - TestToken(quote).balanceOf(address(this)), uint256(paid), "partial paid");
            vm.revertToState(snapshot);
        }
    }
}
