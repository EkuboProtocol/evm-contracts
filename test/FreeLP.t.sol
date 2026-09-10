// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {FreeLP} from "../src/FreeLP.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {createConcentratedPoolConfig} from "../src/types/poolConfig.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {RouteNode, TokenAmount} from "../src/base/BaseRouter.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";

contract NativeReentrantHolder {
    FreeLP immutable lp;
    bool public callbackAttempted;
    bool public callbackSucceeded;

    constructor(FreeLP manager) {
        lp = manager;
    }

    function open(FreeLP.Descriptor memory desc) external payable {
        // This range is below the current price: only token1 would be required. Use a range above it for native-only.
        lp.createPosition{value: msg.value}(
            desc, 0, FreeLP.DepositLimits(uint128(msg.value / 2), 0, 1, block.timestamp)
        );
    }

    receive() external payable {
        callbackAttempted = true;
        (callbackSucceeded,) = address(lp).call(abi.encodeCall(lp.transferFrom, (address(this), address(123), 1)));
    }
}

contract ForwardingNftReceiver {
    address immutable destination;

    constructor(address to) {
        destination = to;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        FreeLP lp = FreeLP(msg.sender);
        (uint256[] memory ids, uint256 total) = lp.ownedIds(address(this), 0, 100);
        require(total == 1 && ids[0] == id, "enumeration must precede callback");
        lp.transferFrom(address(this), destination, id);
        return this.onERC721Received.selector;
    }
}

contract FreeLPTest is FullTest {
    FreeLP lp;
    FreeLP.Descriptor d;

    function setUp() public override {
        super.setUp();
        lp = new FreeLP(core);
        d = FreeLP.Descriptor(
            PoolKey(address(token0), address(token1), createConcentratedPoolConfig(1 << 60, 10, address(0))),
            -1000,
            1000
        );
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
    }

    function limits(uint128 amount) internal view returns (FreeLP.DepositLimits memory) {
        return FreeLP.DepositLimits(amount, amount, 1, block.timestamp + 100);
    }

    function create(uint128 amount) internal returns (uint256 id, uint128 liquidity) {
        (id, liquidity,,) = lp.createPosition(d, 0, limits(amount));
    }

    function test_lifecycle() public {
        (uint256 id, uint128 liquidity) = create(1 ether);
        assertEq(lp.ownerOf(id), address(this));
        FreeLP.Descriptor memory stored = lp.descriptor(id);
        assertEq(stored.poolKey.token0, address(token0));
        assertEq(stored.tickLower, -1000);
        assertEq(lp.positionAmounts(id).liquidity, liquidity);
        vm.expectRevert(FreeLP.PositionNotEmpty.selector);
        lp.burn(id);
        (uint128 added,,) = lp.addLiquidity(id, limits(1 ether));
        uint256 paid0 = token0.balanceOf(address(core));
        uint256 paid1 = token1.balanceOf(address(core));
        (uint128 a, uint128 b) = lp.withdraw(id, liquidity + added, address(this), 0, 0, block.timestamp);
        assertApproxEqAbs(a, paid0, 2);
        assertApproxEqAbs(b, paid1, 2);
        lp.burn(id);
        (, uint256 total) = lp.ownedIds(address(this), 0, 100);
        assertEq(total, 0);
        vm.expectRevert();
        lp.tokenURI(id);
        (uint256 next,) = create(1 ether);
        assertGt(next, id);
    }

    function test_transfersAndPagination() public {
        (uint256 first,) = create(1000);
        (uint256 second,) = create(1000);
        (uint256 third,) = create(1000);
        lp.transferFrom(address(this), address(this), second);
        (uint256[] memory ids, uint256 total) = lp.ownedIds(address(this), 1, 1);
        assertEq(ids[0], second);
        assertEq(total, 3);
        address recipient = makeAddr("recipient");
        lp.transferFrom(address(this), recipient, second);
        (ids, total) = lp.ownedIds(address(this), 0, 100);
        assertEq(total, 2);
        assertEq(ids[0], first);
        assertEq(ids[1], third);
        (ids, total) = lp.ownedIds(recipient, 0, 100);
        assertEq(ids[0], second);
        assertEq(total, 1);
        vm.prank(recipient);
        lp.transferFrom(recipient, address(this), second);
        assertEq(lp.balanceOf(address(this)), 3);
        vm.expectRevert(FreeLP.InvalidPage.selector);
        lp.ownedIds(address(this), 0, 101);
    }

    function test_authorizationAndSlippage() public {
        (uint256 id, uint128 liquidity) = create(1 ether);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(FreeLP.Unauthorized.selector);
        lp.withdraw(id, liquidity, address(this), 0, 0, block.timestamp);
        vm.expectRevert(FreeLP.Slippage.selector);
        lp.withdraw(id, liquidity, address(this), 2 ether, 0, block.timestamp);
        assertEq(lp.positionAmounts(id).liquidity, liquidity);
        vm.warp(1000);
        vm.expectRevert(FreeLP.Expired.selector);
        lp.withdraw(id, liquidity, address(this), 0, 0, 999);
        address operator = makeAddr("operator");
        lp.approve(operator, id);
        vm.prank(operator);
        lp.withdraw(id, liquidity, operator, 0, 0, block.timestamp);
        assertGt(token0.balanceOf(operator), 0);
    }

    function test_collectFeesWithoutManagerFee() public {
        (uint256 id,) = create(1 ether);
        token0.approve(address(router), 1 ether);
        router.swapAllowPartialFill(RouteNode(d.poolKey, SqrtRatio.wrap(0), 0), TokenAmount(address(token0), 1000));
        FreeLP.Amounts memory before = lp.positionAmounts(id);
        assertGt(before.fees0, 0);
        (uint128 a, uint128 b) = lp.withdraw(id, 0, address(this), 0, 0, block.timestamp);
        assertEq(a, before.fees0);
        assertEq(b, before.fees1);
        assertEq(lp.positionAmounts(id).fees0, 0);
    }

    function test_nativeRefundAndWithdrawal() public {
        d.poolKey.token0 = NATIVE_TOKEN_ADDRESS;
        vm.deal(address(this), 10 ether);
        (uint256 id, uint128 liquidity, uint128 paid,) = lp.createPosition{value: 2 ether}(d, 0, limits(1 ether));
        assertEq(address(this).balance, 10 ether - paid);
        assertEq(address(lp).balance, 0);
        lp.withdraw(id, liquidity, address(this), 0, 0, block.timestamp);
        assertApproxEqAbs(address(this).balance, 10 ether, 1);
    }

    function test_invalidDescriptorAndZeroLiquidity() public {
        d.tickUpper = d.tickLower;
        vm.expectRevert(FreeLP.InvalidRange.selector);
        create(100);
        d.tickUpper = 1000;
        d.poolKey.config = createConcentratedPoolConfig(0, 10, address(1));
        vm.expectRevert(FreeLP.UnsupportedPool.selector);
        create(100);
        d.poolKey.config = createConcentratedPoolConfig(0, 10, address(0));
        vm.expectRevert(FreeLP.Slippage.selector);
        lp.createPosition(d, 0, FreeLP.DepositLimits(0, 0, 0, block.timestamp));
    }

    function test_metadataIsFullyOnChain() public {
        (uint256 id,) = create(1000);
        string memory uri = lp.tokenURI(id);
        assertTrue(LibString.startsWith(uri, "data:application/json;base64,"));
        string memory json = string(Base64.decode(LibString.slice(uri, 29)));
        assertEq(vm.parseJsonString(json, ".name"), "Liquidity Position #1");
        string memory image = vm.parseJsonString(json, ".image");
        assertTrue(LibString.startsWith(image, "data:image/svg+xml;base64,"));
        string memory svg = string(Base64.decode(LibString.slice(image, 26)));
        assertTrue(LibString.contains(svg, "<svg"));
        assertTrue(LibString.contains(svg, LibString.toHexString(address(token0))));
        assertLt(address(lp).code.length, 24576);
    }

    function test_multicallAtomic() public {
        (uint256 id, uint128 liquidity) = create(1000);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(lp.withdraw, (id, liquidity, address(this), 0, 0, block.timestamp));
        calls[1] = abi.encodeCall(lp.burn, (id));
        lp.multicall(calls);
        assertEq(lp.balanceOf(address(this)), 0);
    }

    function test_refundCallbackCannotTransferDuringDeposit() public {
        d.poolKey.token0 = NATIVE_TOKEN_ADDRESS;
        d.tickLower = 1000;
        d.tickUpper = 2000;
        NativeReentrantHolder holder = new NativeReentrantHolder(lp);
        vm.deal(address(this), 2 ether);
        holder.open{value: 2 ether}(d);
        assertTrue(holder.callbackAttempted());
        assertFalse(holder.callbackSucceeded());
        assertEq(lp.ownerOf(1), address(holder));
        assertEq(address(lp).balance, 0);
    }

    function test_safeTransferCallbackCanForwardWithConsistentEnumeration() public {
        (uint256 id,) = create(1000);
        address destination = makeAddr("destination");
        ForwardingNftReceiver receiver = new ForwardingNftReceiver(destination);
        lp.safeTransferFrom(address(this), address(receiver), id);
        assertEq(lp.ownerOf(id), destination);
        (, uint256 remaining) = lp.ownedIds(address(receiver), 0, 100);
        assertEq(remaining, 0);
        (uint256[] memory ids, uint256 total) = lp.ownedIds(destination, 0, 100);
        assertEq(total, 1);
        assertEq(ids[0], id);
    }

    function testFuzz_ownershipEnumeration(uint256 seed, uint8 steps) public {
        steps = uint8(bound(steps, 1, 50));
        address[3] memory holders = [address(this), address(111), address(222)];
        for (uint256 i; i < 5; i++) {
            create(1000);
        }
        for (uint256 i; i < steps; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 id = seed % 5 + 1;
            address from = lp.ownerOf(id);
            address to = holders[(seed >> 128) % 3];
            vm.prank(from);
            lp.transferFrom(from, to, id);
            _assertOwnership(holders);
        }
    }

    function _assertOwnership(address[3] memory holders) private view {
        uint256 seen;
        uint256 mask;
        for (uint256 i; i < holders.length; i++) {
            (uint256[] memory ids, uint256 total) = lp.ownedIds(holders[i], 0, 100);
            assertEq(total, lp.balanceOf(holders[i]));
            for (uint256 j; j < ids.length; j++) {
                assertEq(lp.ownerOf(ids[j]), holders[i]);
                assertEq(mask & (1 << ids[j]), 0);
                mask |= 1 << ids[j];
                seen++;
            }
        }
        assertEq(seen, 5);
    }

    function testFuzz_portionWithdrawal(uint96 amount, uint16 fraction) public {
        amount = uint96(bound(amount, 1000, 1e24));
        fraction = uint16(bound(fraction, 1, 9999));
        (uint256 id, uint128 liquidity) = create(amount);
        uint128 portion = uint128(uint256(liquidity) * fraction / 10000);
        lp.withdraw(id, portion, address(this), 0, 0, block.timestamp);
        assertEq(lp.positionAmounts(id).liquidity, liquidity - portion);
        lp.withdraw(id, liquidity - portion, address(this), 0, 0, block.timestamp);
        assertEq(lp.positionAmounts(id).liquidity, 0);
        lp.burn(id);
    }
}
