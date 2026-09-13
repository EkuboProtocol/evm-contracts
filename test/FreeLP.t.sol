// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Locker} from "../src/types/locker.sol";
import {PositionId, createPositionId} from "../src/types/positionId.sol";
import {CoreStorageLayout} from "../src/libraries/CoreStorageLayout.sol";
import {StorageSlot} from "../src/types/storageSlot.sol";
import {byteToCallPoints} from "../src/types/callPoints.sol";
import {FreeLP} from "../src/FreeLP.sol";
import {QuoteData} from "../src/lens/QuoteDataFetcher.sol";
import {TokenDataFetcher} from "../src/lens/TokenDataFetcher.sol";
import {FreeLPDataFetcher} from "../src/lens/FreeLPDataFetcher.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolKeyIndex} from "../src/PoolKeyIndex.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolConfig, createConcentratedPoolConfig, createStableswapPoolConfig} from "../src/types/poolConfig.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {RouteNode, TokenAmount} from "../src/base/BaseRouter.sol";
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
            desc.poolKey, desc.tickLower, desc.tickUpper, 0, uint128(msg.value / 2), 0, 1
        );
        lp.refundNativeToken();
    }

    receive() external payable {
        callbackAttempted = true;
        (callbackSucceeded,) = address(lp).call(abi.encodeCall(lp.transferFrom, (address(this), address(123), 1)));
    }
}

contract NativeReentrantDepositor {
    FreeLP private immutable lp;
    FreeLP.Descriptor private d;
    bool private entered;

    constructor(FreeLP manager) {
        lp = manager;
    }

    function open(FreeLP.Descriptor memory descriptor) external payable {
        d = descriptor;
        lp.createPosition{value: msg.value}(d.poolKey, d.tickLower, d.tickUpper, 0, uint128(msg.value / 2), 0, 1);
        lp.refundNativeToken();
    }

    function close() external {
        FreeLPDataFetcher fetcher = new FreeLPDataFetcher(lp.CORE());
        lp.withdraw(1, fetcher.positionAmounts(lp, 1).liquidity, address(this), 0, 0);
        lp.withdraw(2, fetcher.positionAmounts(lp, 2).liquidity, address(this), 0, 0);
    }

    receive() external payable {
        if (!entered) {
            entered = true;
            lp.createPosition{value: msg.value}(d.poolKey, d.tickLower, d.tickUpper, 0, uint128(msg.value), 0, 1);
            lp.refundNativeToken();
        }
    }
}

contract ReentrantBurnExtension {
    FreeLP private lp;
    uint256 private id;
    address private recipient;
    bool private armed;

    function register(ICore core) external {
        core.registerExtension(byteToCallPoints(16));
    }

    function arm(FreeLP manager, uint256 tokenId, address to) external {
        lp = manager;
        id = tokenId;
        recipient = to;
        armed = true;
    }

    function beforeUpdatePosition(Locker, PoolKey memory, PositionId, int128 delta) external {
        if (armed && delta > 0) {
            armed = false;
            FreeLPDataFetcher fetcher = new FreeLPDataFetcher(lp.CORE());
            lp.withdraw(id, fetcher.positionAmounts(lp, id).liquidity, recipient, 0, 0);
        }
    }
}

contract ForwardingNftReceiver {
    address immutable destination;

    constructor(address to) {
        destination = to;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        FreeLP lp = FreeLP(payable(msg.sender));
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
    FreeLPDataFetcher reader;
    PoolKeyIndex index;
    FreeLP.Descriptor d;

    function setUp() public override {
        super.setUp();
        index = new PoolKeyIndex(core);
        lp = new FreeLP(core, index);
        reader = new FreeLPDataFetcher(core);
        d = FreeLP.Descriptor(
            PoolKey(address(token0), address(token1), createConcentratedPoolConfig(1 << 60, 10, address(0))),
            -1000,
            1000
        );
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
    }

    function create(uint128 amount) internal returns (uint256 id, uint128 liquidity) {
        (id, liquidity,,) = lp.createPosition(d.poolKey, d.tickLower, d.tickUpper, 0, amount, amount, 1);
    }

    function _cold() private {
        vm.cool(address(lp));
        vm.cool(address(core));
        vm.cool(address(token0));
        vm.cool(address(token1));
        vm.cool(address(index));
    }

    function test_gas_firstPoolPosition() public {
        _cold();
        create(1 ether);
        vm.snapshotGasLastCall("FreeLP", "create first pool position");
    }

    function test_gas_secondPoolPosition() public {
        create(1 ether);
        _cold();
        create(1 ether);
        vm.snapshotGasLastCall("FreeLP", "create second pool position cold");
    }

    function test_gas_secondPoolPositionWarm() public {
        create(1 ether);
        create(1 ether);
        vm.snapshotGasLastCall("FreeLP", "create second pool position warm");
    }

    function test_gas_firstPositionExistingPool() public {
        core.initializePool(d.poolKey, 0);
        index.register(d.poolKey);
        _cold();
        create(1 ether);
        vm.snapshotGasLastCall("FreeLP", "create first position existing pool");
    }

    function test_unifiedFetcherQuotesAndBalances() public {
        create(1 ether);
        FreeLPDataFetcher fetcher = new FreeLPDataFetcher(core);
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = d.poolKey;
        QuoteData[] memory quotes = fetcher.getQuoteData(keys, 1);
        (uint256 ratio,, uint128 liquidity) = reader.poolState(lp, d.poolKey);
        assertEq(quotes.length, 1);
        assertEq(quotes[0].sqrtRatio.toFixed(), ratio);
        assertEq(quotes[0].liquidity, liquidity);
        assertGt(quotes[0].ticks.length, 0);
        address[] memory tokens = new address[](2);
        tokens[0] = address(token0);
        tokens[1] = NATIVE_TOKEN_ADDRESS;
        address[] memory spenders = new address[](1);
        spenders[0] = address(lp);
        (TokenDataFetcher.Balance[] memory balances, TokenDataFetcher.Allowance[] memory allowances) =
            fetcher.getNonzeroBalancesAndAllowances(address(this), tokens, spenders);
        assertEq(balances[0].amount, token0.balanceOf(address(this)));
        assertEq(balances[1].amount, address(this).balance);
        assertEq(allowances[0].amount, token0.allowance(address(this), address(lp)));
    }

    function test_ownedPositions_missingManager_and_zeroHolder() public {
        FreeLPDataFetcher fetcher = new FreeLPDataFetcher(core);
        (uint256 chainId, bool deployed, FreeLPDataFetcher.OwnedPosition[] memory items) =
            fetcher.ownedPositions(FreeLP(payable(address(123))), address(this));
        assertEq(chainId, block.chainid);
        assertFalse(deployed);
        assertEq(items.length, 0);
        (, deployed, items) = fetcher.ownedPositions(lp, address(0));
        assertTrue(deployed);
        assertEq(items.length, 0);
        assertLt(address(fetcher).code.length, 24576);
    }

    function test_ownedPositions_snapshot_tracks_transfers_fees_and_burns() public {
        FreeLPDataFetcher fetcher = new FreeLPDataFetcher(core);
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
        assertEq(abi.encode(items[0].descriptor), abi.encode(reader.descriptor(lp, first)));
        assertEq(abi.encode(items[0].amounts), abi.encode(reader.positionAmounts(lp, first)));
        assertGt(items[0].amounts.fees0, 0);
        (uint256 ratio,,) = reader.poolState(lp, d.poolKey);
        assertEq(items[0].sqrtRatio, ratio);
        assertEq(items[0].metadata, lp.tokenURI(first));
        lp.transferFrom(address(this), address(123), first);
        (,, items) = fetcher.ownedPositions(lp, address(this));
        assertEq(items.length, 1);
        assertEq(items[0].id, second);
        lp.withdraw(second, items[0].amounts.liquidity, address(this), 0, 0);
        (,, items) = fetcher.ownedPositions(lp, address(this));
        assertEq(items.length, 0);
        (,, items) = fetcher.ownedPositions(lp, address(123));
        assertEq(items.length, 1);
        assertEq(items[0].id, first);
    }

    function test_lifecycle() public {
        (uint256 id, uint128 liquidity) = create(1 ether);
        assertEq(lp.ownerOf(id), address(this));
        FreeLP.Descriptor memory stored = reader.descriptor(lp, id);
        assertEq(stored.poolKey.token0, address(token0));
        assertEq(stored.tickLower, -1000);
        assertEq(reader.positionAmounts(lp, id).liquidity, liquidity);
        (uint128 added,,) = lp.addLiquidity(id, 1 ether, 1 ether, 1);
        uint256 paid0 = token0.balanceOf(address(core));
        uint256 paid1 = token1.balanceOf(address(core));
        (uint128 a, uint128 b) = lp.withdraw(id, liquidity + added, address(this), 0, 0);
        assertApproxEqAbs(a, paid0, 2);
        assertApproxEqAbs(b, paid1, 2);
        assertEq(lp.balanceOf(address(this)), 0);
        assertEq(lp.totalSupply(), 0);
        vm.expectRevert();
        lp.tokenURI(id);
        (uint256 next,) = create(1 ether);
        assertGt(next, id);
    }

    function test_fullWithdrawalClearsStorageAndApproval() public {
        (uint256 id, uint128 liquidity) = create(1 ether);
        lp.approve(address(123), id);
        bytes32 firstSlot = keccak256(abi.encode(id, uint256(1)));
        lp.withdraw(id, liquidity, address(this), 0, 0);
        for (uint256 i; i < 2; ++i) {
            assertEq(vm.load(address(lp), bytes32(uint256(firstSlot) + i)), bytes32(0));
        }
        assertEq(lp.totalSupply(), 0);
        assertEq(lp.balanceOf(address(this)), 0);
        vm.expectRevert();
        lp.ownerOf(id);
        vm.expectRevert();
        reader.descriptor(lp, id);
        vm.expectRevert();
        lp.addLiquidity(id, 1 ether, 1 ether, 1);
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
        lp.withdraw(id, liquidity, address(this), 0, 0);
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
        lp.withdraw(3, reader.positionAmounts(lp, 3).liquidity, address(this), 0, 0);
        _assertOwnership([address(this), address(111), address(222)]);
        assertEq(lp.tokenByIndex(2), 9);
        assertEq(lp.tokenOfOwnerByIndex(address(this), 2), 7);
    }

    function testFuzz_ownerSlotBoundsSurviveTransfer(int32 lower, int32 upper) public {
        d.tickLower = int32(bound(lower, -887272, -1)) * 10;
        d.tickUpper = int32(bound(upper, 1, 887272)) * 10;
        (uint256 id,) = create(1 ether);
        lp.transferFrom(address(this), address(123), id);
        (PoolId poolId, int32 storedLower, int32 storedUpper) = lp.position(id);
        assertEq(PoolId.unwrap(poolId), PoolId.unwrap(d.poolKey.toPoolId()));
        assertEq(storedLower, d.tickLower);
        assertEq(storedUpper, d.tickUpper);
        assertEq(abi.encode(reader.descriptor(lp, id)), abi.encode(d));
    }

    function test_sharedPoolRegistrySurvivesBurnAndIsDiscoverable() public {
        (uint256 first, uint128 liquidity) = create(1 ether);
        d.tickLower = -2000;
        (uint256 second,) = create(1 ether);
        assertEq(index.poolIdCount(), 1);
        assertEq(index.tokenPoolIdCount(address(token0)), 1);
        assertEq(index.tokenPoolIdCount(address(token1)), 1);
        assertEq(index.extensionPoolIdCount(address(0)), 1);
        lp.withdraw(first, liquidity, address(this), 0, 0);
        PoolKey[] memory keys = index.getPoolKeysByToken(address(token0));
        assertEq(abi.encode(keys[0]), abi.encode(d.poolKey));
        assertEq(reader.descriptor(lp, second).tickLower, -2000);
        FreeLP other = new FreeLP(core, index);
        token0.approve(address(other), type(uint256).max);
        token1.approve(address(other), type(uint256).max);
        other.createPosition(d.poolKey, -1000, 1000, 0, 1 ether, 1 ether, 1);
        assertEq(index.poolIdCount(), 1);
        assertEq(abi.encode(reader.descriptor(other, 1).poolKey), abi.encode(d.poolKey));
    }

    function test_payableMulticallSharesNativeBalanceAndRefundsOnce() public {
        d.poolKey.token0 = NATIVE_TOKEN_ADDRESS;
        d.tickLower = 1000;
        d.tickUpper = 2000;
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(lp.createPosition, (d.poolKey, 1000, 2000, 0, 1 ether, 0, 1));
        calls[1] = calls[0];
        calls[2] = abi.encodeCall(lp.addLiquidity, (1, 1 ether, 0, 1));
        calls[3] = abi.encodeCall(lp.refundNativeToken, ());
        vm.deal(address(this), 4 ether);
        bytes[] memory results = lp.multicall{value: 4 ether}(calls);
        (,, uint128 firstPaid,) = abi.decode(results[0], (uint256, uint128, uint128, uint128));
        (,, uint128 secondPaid,) = abi.decode(results[1], (uint256, uint128, uint128, uint128));
        (, uint128 addedPaid,) = abi.decode(results[2], (uint128, uint128, uint128));
        assertEq(address(this).balance, 4 ether - firstPaid - secondPaid - addedPaid);
        assertEq(address(lp).balance, 0);
        assertEq(lp.totalSupply(), 2);
        assertEq(index.poolIdCount(), 1);
    }

    function test_payableMulticallCannotSpendMsgValueTwice() public {
        d.poolKey.token0 = NATIVE_TOKEN_ADDRESS;
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(lp.createPosition, (d.poolKey, 1000, 2000, 0, 1 ether, 0, 1));
        calls[1] = calls[0];
        vm.deal(address(this), 1 ether);
        vm.expectRevert();
        lp.multicall{value: 1 ether}(calls);
        assertEq(lp.totalSupply(), 0);
        assertEq(index.poolIdCount(), 0);
        assertEq(address(this).balance, 1 ether);
    }

    function test_payableWithdrawCanFundDepositInSameMulticall() public {
        d.poolKey.token0 = NATIVE_TOKEN_ADDRESS;
        d.tickLower = 1000;
        d.tickUpper = 2000;
        (uint256 id, uint128 liquidity,,) = lp.createPosition{value: 1 ether}(d.poolKey, 1000, 2000, 0, 1 ether, 0, 1);
        lp.refundNativeToken();
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(lp.withdraw, (id, liquidity, address(lp), 0, 0));
        calls[1] = abi.encodeCall(lp.createPosition, (d.poolKey, 1000, 2000, 0, 1 ether, 0, 1));
        calls[2] = abi.encodeCall(lp.refundNativeToken, ());
        lp.multicall{value: 10}(calls);
        assertEq(lp.totalSupply(), 1);
        assertEq(lp.ownerOf(2), address(this));
        assertEq(address(lp).balance, 0);
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
        lp.withdraw(second, liquidity, address(this), 0, 0);
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
        lp.withdraw(id, liquidity, address(this), 0, 0);
        vm.expectRevert(FreeLP.Slippage.selector);
        lp.withdraw(id, liquidity, address(this), 2 ether, 0);
        assertEq(reader.positionAmounts(lp, id).liquidity, liquidity);
        address operator = makeAddr("operator");
        lp.approve(operator, id);
        vm.prank(operator);
        lp.withdraw(id, liquidity, operator, 0, 0);
        assertGt(token0.balanceOf(operator), 0);
    }

    function test_collectFeesWithoutManagerFee() public {
        (uint256 id,) = create(1 ether);
        token0.approve(address(router), 1 ether);
        router.swapAllowPartialFill(RouteNode(d.poolKey, SqrtRatio.wrap(0), 0), TokenAmount(address(token0), 1000));
        FreeLPDataFetcher.Amounts memory before = reader.positionAmounts(lp, id);
        assertGt(before.fees0, 0);
        (uint128 a, uint128 b) = lp.withdraw(id, 0, address(this), 0, 0);
        assertEq(a, before.fees0);
        assertEq(b, before.fees1);
        assertEq(reader.positionAmounts(lp, id).fees0, 0);
    }

    function test_nativeRefundAndWithdrawal() public {
        d.poolKey.token0 = NATIVE_TOKEN_ADDRESS;
        vm.deal(address(this), 10 ether);
        (uint256 id, uint128 liquidity, uint128 paid,) =
            lp.createPosition{value: 2 ether}(d.poolKey, d.tickLower, d.tickUpper, 0, 1 ether, 1 ether, 1);
        lp.refundNativeToken();
        assertEq(address(this).balance, 10 ether - paid);
        assertEq(address(lp).balance, 0);
        lp.withdraw(id, liquidity, address(this), 0, 0);
        assertApproxEqAbs(address(this).balance, 10 ether, 1);
    }

    function test_invalidDescriptorAndZeroLiquidity() public {
        d.tickUpper = d.tickLower;
        vm.expectRevert(BoundsOrder.selector);
        create(100);
        d.tickUpper = 1000;
        d.poolKey.config = createConcentratedPoolConfig(0, 10, address(0));
        vm.expectRevert(FreeLP.Slippage.selector);
        lp.createPosition(d.poolKey, d.tickLower, d.tickUpper, 0, 0, 0, 0);
    }

    function testFuzz_stableswapWithExtension(uint8 amplification, int32 center) public {
        amplification = uint8(bound(amplification, 0, 26));
        center = int32(bound(center, -1000000, 1000000)) / 16 * 16;
        address extension = address(createAndRegisterExtension());
        d.poolKey.config = createStableswapPoolConfig(type(uint64).max / 1000, amplification, center, extension);
        (d.tickLower, d.tickUpper) = d.poolKey.config.stableswapActiveLiquidityTickRange();
        (uint256 id, uint128 liquidity,,) =
            lp.createPosition(d.poolKey, d.tickLower, d.tickUpper, center, 1 ether, 1 ether, 1);
        assertEq(abi.encode(reader.descriptor(lp, id)), abi.encode(d));
        assertGt(reader.positionAmounts(lp, id).principal0 + reader.positionAmounts(lp, id).principal1, 0);
        lp.withdraw(id, liquidity, address(this), 0, 0);
    }

    function test_concentratedWithExtension() public {
        d.poolKey.config = createConcentratedPoolConfig(123456789, 10, address(createAndRegisterExtension()));
        (uint256 id, uint128 liquidity) = create(1 ether);
        assertEq(abi.encode(reader.descriptor(lp, id)), abi.encode(d));
        lp.withdraw(id, liquidity, address(this), 0, 0);
    }

    function test_stableswapFeesRemainOwedOutsideActiveRange() public {
        d.poolKey.config =
            createStableswapPoolConfig(type(uint64).max / 100, 10, 0, address(createAndRegisterExtension()));
        (d.tickLower, d.tickUpper) = d.poolKey.config.stableswapActiveLiquidityTickRange();
        (uint256 id,) = create(1 ether);
        token0.approve(address(router), 10 ether);
        router.swapAllowPartialFill(RouteNode(d.poolKey, SqrtRatio.wrap(0), 0), TokenAmount(address(token0), 10 ether));
        (, int32 tick,) = reader.poolState(lp, d.poolKey);
        assertLe(tick, d.tickLower);
        FreeLPDataFetcher.Amounts memory amounts = reader.positionAmounts(lp, id);
        assertGt(amounts.fees0, 0);
        (uint128 a, uint128 b) = lp.withdraw(id, 0, address(this), 0, 0);
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
        (uint256 second, uint128 secondLiquidity) = create(1000);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(lp.withdraw, (id, liquidity, address(this), 0, 0));
        calls[1] = abi.encodeCall(lp.withdraw, (second, secondLiquidity, address(this), 0, 0));
        lp.multicall(calls);
        assertEq(lp.balanceOf(address(this)), 0);
    }

    function test_refundCallbackCanTransferAfterSettlement() public {
        d.poolKey.token0 = NATIVE_TOKEN_ADDRESS;
        d.tickLower = 1000;
        d.tickUpper = 2000;
        NativeReentrantHolder holder = new NativeReentrantHolder(lp);
        vm.deal(address(this), 2 ether);
        holder.open{value: 2 ether}(d);
        assertTrue(holder.callbackAttempted());
        assertTrue(holder.callbackSucceeded());
        assertEq(lp.ownerOf(1), address(123));
        assertEq(lp.balanceOf(address(holder)), 0);
        assertEq(lp.tokenOfOwnerByIndex(address(123), 0), 1);
        assertEq(lp.totalSupply(), 1);
        assertGt(reader.positionAmounts(lp, 1).liquidity, 0);
        assertEq(address(lp).balance, 0);
    }

    function test_refundCallbackCanCreateAnotherPosition() public {
        d.poolKey.token0 = NATIVE_TOKEN_ADDRESS;
        d.tickLower = 1000;
        d.tickUpper = 2000;
        NativeReentrantDepositor holder = new NativeReentrantDepositor(lp);
        vm.deal(address(this), 2 ether);
        holder.open{value: 2 ether}(d);
        assertEq(lp.balanceOf(address(holder)), 2);
        assertEq(lp.totalSupply(), 2);
        assertEq(lp.tokenOfOwnerByIndex(address(holder), 0), 1);
        assertEq(lp.tokenOfOwnerByIndex(address(holder), 1), 2);
        assertGt(reader.positionAmounts(lp, 1).liquidity, 0);
        assertGt(reader.positionAmounts(lp, 2).liquidity, 0);
        assertEq(address(lp).balance, 0);
        holder.close();
        assertEq(lp.totalSupply(), 0);
        assertApproxEqAbs(address(holder).balance, 2 ether, 4);
        assertEq(address(lp).balance, 0);
    }

    function test_positionAmountsRejectsLiquidityOutsideSignedRange() public {
        (uint256 id,) = create(1 ether);
        StorageSlot slot = CoreStorageLayout.poolPositionsSlot(
            d.poolKey.toPoolId(), address(lp), createPositionId(bytes24(uint192(id)), d.tickLower, d.tickUpper)
        );
        // An extension can read during a Core callback before the deposit's bounds check returns.
        vm.store(address(core), StorageSlot.unwrap(slot), bytes32(uint256(1) << 255));
        vm.expectRevert(FreeLP.InvalidValue.selector);
        reader.positionAmounts(lp, id);
    }

    function test_nestedBurnCannotOrphanAnOuterDeposit() public {
        ReentrantBurnExtension implementation = new ReentrantBurnExtension();
        ReentrantBurnExtension extension = ReentrantBurnExtension(address(uint160(16) << 152));
        vm.etch(address(extension), address(implementation).code);
        extension.register(core);
        d.poolKey.config = createConcentratedPoolConfig(123456789, 10, address(extension));
        (uint256 id, uint128 liquidity) = create(1 ether);
        lp.setApprovalForAll(address(extension), true);
        extension.arm(lp, id, address(this));
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        lp.addLiquidity(id, 1 ether, 1 ether, 1);
        assertEq(lp.ownerOf(id), address(this));
        assertEq(reader.positionAmounts(lp, id).liquidity, liquidity);
        assertEq(lp.totalSupply(), 1);
        assertEq(token0.balanceOf(address(this)), balance0);
        assertEq(token1.balanceOf(address(this)), balance1);
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
                uint128 liquidity = reader.positionAmounts(lp, id).liquidity;
                vm.prank(to);
                lp.withdraw(id, liquidity, to, 0, 0);
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
        lp.withdraw(id, portion, address(this), 0, 0);
        assertEq(reader.positionAmounts(lp, id).liquidity, liquidity - portion);
        lp.withdraw(id, liquidity - portion, address(this), 0, 0);
        vm.expectRevert();
        lp.ownerOf(id);
    }
}
