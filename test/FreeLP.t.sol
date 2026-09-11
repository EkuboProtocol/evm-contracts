// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {FreeLP} from "../src/FreeLP.sol";
import {FreeLPDataFetcher} from "../src/lens/FreeLPDataFetcher.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolConfig, createConcentratedPoolConfig, createStableswapPoolConfig} from "../src/types/poolConfig.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {RouteNode, TokenAmount} from "../src/base/BaseRouter.sol";
import {FreeLPPool, FreeLPRange, createFreeLPPool, createFreeLPRange} from "../src/types/freeLPDescriptor.sol";
import {BoundsOrder, StableswapMustBeFullRange} from "../src/types/positionId.sol";
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
        require(
            lp.balanceOf(address(this)) == 1 && lp.tokenOfOwnerByIndex(address(this), 0) == id,
            "enumeration must precede callback"
        );
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

    function test_ownedPositions_missingManager_and_zeroHolder() public {
        FreeLPDataFetcher fetcher = new FreeLPDataFetcher();
        (uint256 chainId, bool deployed, FreeLPDataFetcher.OwnedPosition[] memory items) =
            fetcher.ownedPositions(FreeLP(address(123)), address(this));
        assertEq(chainId, block.chainid);
        assertFalse(deployed);
        assertEq(items.length, 0);
        (, deployed, items) = fetcher.ownedPositions(lp, address(0));
        assertTrue(deployed);
        assertEq(items.length, 0);
        assertLt(address(fetcher).code.length, 24576);
    }

    function test_ownedPositions_snapshot_tracks_transfers_fees_and_burns() public {
        FreeLPDataFetcher fetcher = new FreeLPDataFetcher();
        (uint256 chainId, bool deployed, FreeLPDataFetcher.OwnedPosition[] memory empty) =
            fetcher.ownedPositions(lp, address(this));
        assertTrue(deployed);
        assertEq(chainId, block.chainid);
        assertEq(empty.length, 0);
        (uint256 first,) = create(1 ether);
        (uint256 second,) = create(2 ether);
        token0.approve(address(router), 1 ether);
        router.swapAllowPartialFill(RouteNode(d.poolKey, SqrtRatio.wrap(0), 0), TokenAmount(address(token0), 1000));
        (,, FreeLPDataFetcher.OwnedPosition[] memory items) = fetcher.ownedPositions(lp, address(this));
        assertEq(items.length, 2);
        assertEq(items[0].id, first);
        assertEq(items[1].id, second);
        assertEq(abi.encode(items[0].descriptor), abi.encode(lp.descriptor(first)));
        assertEq(abi.encode(items[0].amounts), abi.encode(lp.positionAmounts(first)));
        assertGt(items[0].amounts.fees0, 0);
        (uint256 ratio,,) = lp.poolState(d.poolKey);
        assertEq(items[0].sqrtRatio, ratio);
        assertEq(items[0].metadata, lp.tokenURI(first));
        lp.transferFrom(address(this), address(123), first);
        (,, items) = fetcher.ownedPositions(lp, address(this));
        assertEq(items.length, 1);
        assertEq(items[0].id, second);
        lp.withdraw(second, items[0].amounts.liquidity, address(this), 0, 0, block.timestamp);
        lp.burn(second);
        (,, items) = fetcher.ownedPositions(lp, address(this));
        assertEq(items.length, 0);
        (,, items) = fetcher.ownedPositions(lp, address(123));
        assertEq(items.length, 1);
        assertEq(items[0].id, first);
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
        assertEq(lp.balanceOf(address(this)), 0);
        assertEq(lp.totalSupply(), 0);
        vm.expectRevert();
        lp.tokenURI(id);
        (uint256 next,) = create(1 ether);
        assertGt(next, id);
    }

    function test_idExhaustionNeverReusesBurnedIds() public {
        // FreeLP's counter occupies the low 64 bits of slot zero; Solady ERC721 uses separate hashed slots.
        vm.store(address(lp), bytes32(0), bytes32(uint256(type(uint64).max - 1)));
        (uint256 id, uint128 liquidity) = create(1000);
        assertEq(id, type(uint64).max);
        assertEq(lp.tokenByIndex(0), id);
        assertEq(lp.tokenOfOwnerByIndex(address(this), 0), id);
        vm.expectRevert(FreeLP.TokenIdsExhausted.selector);
        create(1000);
        lp.withdraw(id, liquidity, address(this), 0, 0, block.timestamp);
        lp.burn(id);
        vm.expectRevert(FreeLP.TokenIdsExhausted.selector);
        create(1000);
        assertEq(lp.totalSupply(), 0);
    }

    function test_fourIdsPerStorageWord() public {
        for (uint256 i; i < 9; i++) {
            create(1000);
        }
        uint256 expected = 1 | (uint256(2) << 64) | (uint256(3) << 128) | (uint256(4) << 192);
        bytes32 globalStart = keccak256(abi.encode(uint256(3)));
        bytes32 ownerStart = keccak256(abi.encode(keccak256(abi.encode(address(this), uint256(2)))));
        assertEq(uint256(vm.load(address(lp), globalStart)), expected);
        assertEq(uint256(vm.load(address(lp), ownerStart)), expected);
        lp.transferFrom(address(this), address(111), 4);
        lp.transferFrom(address(this), address(222), 5);
        lp.withdraw(3, lp.positionAmounts(3).liquidity, address(this), 0, 0, block.timestamp);
        lp.burn(3);
        _assertOwnership([address(this), address(111), address(222)]);
        assertEq(lp.tokenByIndex(2), 9);
        assertEq(lp.tokenOfOwnerByIndex(address(this), 2), 7);
    }

    function testFuzz_packedDescriptorRoundtrip(
        address a,
        address b,
        uint96 configBits,
        int32 lower,
        int32 upper,
        address extension
    ) public pure {
        PoolConfig config = PoolConfig.wrap(bytes32(uint256(configBits)));
        FreeLPPool pool = createFreeLPPool(a, config);
        FreeLPRange range = createFreeLPRange(b, lower, upper, extension);
        assertEq(pool.token0(), a);
        assertEq(PoolConfig.unwrap(pool.config()), PoolConfig.unwrap(config));
        assertEq(range.token1(), b);
        assertEq(range.tickLower(), lower);
        assertEq(range.tickUpper(), upper);
        assertEq(range.extensionHigh(), uint32(uint160(extension) >> 128));
        assertEq(
            uint256(PoolConfig.unwrap(pool.fullConfig(range, uint128(uint160(extension))))),
            (uint256(uint160(extension)) << 96) | configBits
        );
    }

    function test_enumerableInterfacesAndBounds() public {
        assertTrue(lp.supportsInterface(0x01ffc9a7));
        assertTrue(lp.supportsInterface(0x80ac58cd));
        assertTrue(lp.supportsInterface(0x5b5e139f));
        assertTrue(lp.supportsInterface(0x780e9d63));
        assertFalse(lp.supportsInterface(0xffffffff));
        assertEq(lp.totalSupply(), 0);
        vm.expectRevert(FreeLP.EnumerationIndexOutOfBounds.selector);
        lp.tokenByIndex(0);
        vm.expectRevert(FreeLP.EnumerationIndexOutOfBounds.selector);
        lp.tokenOfOwnerByIndex(address(0), 0);
        vm.expectRevert(FreeLP.EnumerationIndexOutOfBounds.selector);
        lp.tokenOfOwnerByIndex(address(this), 0);
    }

    function test_transfersAndEnumeration() public {
        (uint256 first,) = create(1000);
        (uint256 second, uint128 liquidity) = create(1000);
        (uint256 third,) = create(1000);
        lp.transferFrom(address(this), address(this), second);
        assertEq(lp.tokenOfOwnerByIndex(address(this), 1), second);
        assertEq(lp.totalSupply(), 3);
        address recipient = makeAddr("recipient");
        lp.transferFrom(address(this), recipient, second);
        assertEq(lp.balanceOf(address(this)), 2);
        assertEq(lp.tokenOfOwnerByIndex(address(this), 0), first);
        assertEq(lp.tokenOfOwnerByIndex(address(this), 1), third);
        assertEq(lp.tokenOfOwnerByIndex(recipient, 0), second);
        assertEq(lp.balanceOf(recipient), 1);
        assertEq(lp.tokenByIndex(1), second);
        vm.prank(recipient);
        lp.transferFrom(recipient, address(this), second);
        lp.withdraw(second, liquidity, address(this), 0, 0, block.timestamp);
        lp.burn(second);
        assertEq(lp.totalSupply(), 2);
        assertEq(lp.tokenByIndex(0), first);
        assertEq(lp.tokenByIndex(1), third);
        vm.expectRevert(FreeLP.EnumerationIndexOutOfBounds.selector);
        lp.tokenByIndex(2);
        vm.expectRevert(FreeLP.EnumerationIndexOutOfBounds.selector);
        lp.tokenOfOwnerByIndex(address(this), 2);
        vm.expectRevert(FreeLP.EnumerationIndexOutOfBounds.selector);
        lp.tokenOfOwnerByIndex(recipient, 0);
        (uint256 fourth,) = create(1000);
        assertGt(fourth, third);
        assertEq(lp.tokenByIndex(2), fourth);
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
        vm.expectRevert(BoundsOrder.selector);
        create(100);
        d.tickUpper = 1000;
        d.poolKey.config = createConcentratedPoolConfig(0, 10, address(0));
        vm.expectRevert(FreeLP.Slippage.selector);
        lp.createPosition(d, 0, FreeLP.DepositLimits(0, 0, 0, block.timestamp));
    }

    function testFuzz_stableswapWithExtension(uint8 amplification, int32 center) public {
        amplification = uint8(bound(amplification, 0, 26));
        center = int32(bound(center, -1000000, 1000000)) / 16 * 16;
        address extension = address(createAndRegisterExtension());
        d.poolKey.config = createStableswapPoolConfig(type(uint64).max / 1000, amplification, center, extension);
        (d.tickLower, d.tickUpper) = d.poolKey.config.stableswapActiveLiquidityTickRange();
        (uint256 id, uint128 liquidity,,) = lp.createPosition(d, center, limits(1 ether));
        assertEq(abi.encode(lp.descriptor(id)), abi.encode(d));
        assertGt(lp.positionAmounts(id).principal0 + lp.positionAmounts(id).principal1, 0);
        lp.withdraw(id, liquidity, address(this), 0, 0, block.timestamp);
        lp.burn(id);
    }

    function test_concentratedWithExtension() public {
        d.poolKey.config = createConcentratedPoolConfig(123456789, 10, address(createAndRegisterExtension()));
        (uint256 id, uint128 liquidity) = create(1 ether);
        assertEq(abi.encode(lp.descriptor(id)), abi.encode(d));
        lp.withdraw(id, liquidity, address(this), 0, 0, block.timestamp);
        lp.burn(id);
    }

    function test_stableswapFeesRemainOwedOutsideActiveRange() public {
        d.poolKey.config =
            createStableswapPoolConfig(type(uint64).max / 100, 10, 0, address(createAndRegisterExtension()));
        (d.tickLower, d.tickUpper) = d.poolKey.config.stableswapActiveLiquidityTickRange();
        (uint256 id,) = create(1 ether);
        token0.approve(address(router), 10 ether);
        router.swapAllowPartialFill(RouteNode(d.poolKey, SqrtRatio.wrap(0), 0), TokenAmount(address(token0), 10 ether));
        (, int32 tick,) = lp.poolState(d.poolKey);
        assertLe(tick, d.tickLower);
        FreeLP.Amounts memory amounts = lp.positionAmounts(id);
        assertGt(amounts.fees0, 0);
        (uint128 a, uint128 b) = lp.withdraw(id, 0, address(this), 0, 0, block.timestamp);
        assertEq(a, amounts.fees0);
        assertEq(b, amounts.fees1);
    }

    function test_stableswapRejectsPartialRange() public {
        d.poolKey.config = createStableswapPoolConfig(0, 10, 0, address(0));
        vm.expectRevert(StableswapMustBeFullRange.selector);
        create(1000);
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
        assertEq(lp.balanceOf(address(receiver)), 0);
        assertEq(lp.balanceOf(destination), 1);
        assertEq(lp.tokenOfOwnerByIndex(destination, 0), id);
        assertEq(lp.totalSupply(), 1);
        assertEq(lp.tokenByIndex(0), id);
    }

    function testFuzz_ownershipEnumeration(uint256 seed, uint8 steps) public {
        steps = uint8(bound(steps, 1, 50));
        address[3] memory holders = [address(this), address(111), address(222)];
        for (uint256 i; i < 5; i++) {
            create(1000);
        }
        for (uint256 i; i < steps; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 id = lp.tokenByIndex(seed % lp.totalSupply());
            address from = lp.ownerOf(id);
            address to = holders[(seed >> 128) % 3];
            vm.prank(from);
            lp.transferFrom(from, to, id);
            if (seed % 3 == 0) {
                uint128 liquidity = lp.positionAmounts(id).liquidity;
                vm.prank(to);
                lp.withdraw(id, liquidity, to, 0, 0, block.timestamp);
                vm.prank(to);
                lp.burn(id);
                _assertOwnership(holders);
                create(1000);
            }
            _assertOwnership(holders);
        }
    }

    function _assertOwnership(address[3] memory holders) private view {
        uint256 seen;
        uint256 mask;
        for (uint256 i; i < holders.length; i++) {
            uint256 total = lp.balanceOf(holders[i]);
            for (uint256 j; j < total; j++) {
                uint256 id = lp.tokenOfOwnerByIndex(holders[i], j);
                assertEq(lp.ownerOf(id), holders[i]);
                assertEq(mask & (1 << id), 0);
                mask |= 1 << id;
                seen++;
            }
        }
        assertEq(seen, lp.totalSupply());
        uint256 globalMask;
        for (uint256 i; i < lp.totalSupply(); i++) {
            uint256 id = lp.tokenByIndex(i);
            assertEq(globalMask & (1 << id), 0);
            globalMask |= 1 << id;
        }
        assertEq(globalMask, mask);
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
