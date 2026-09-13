// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {TestToken} from "./TestToken.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {FreeLP} from "../src/FreeLP.sol";
import {FreeLPMetadataRenderer} from "../src/FreeLPMetadataRenderer.sol";
import {FreeLPDataFetcher} from "../src/lens/FreeLPDataFetcher.sol";
import {PoolKeyIndex} from "../src/PoolKeyIndex.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PositionId} from "../src/types/positionId.sol";
import {Locker} from "../src/types/locker.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {PoolState} from "../src/types/poolState.sol";
import {CallPoints} from "../src/types/callPoints.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {createConcentratedPoolConfig} from "../src/types/poolConfig.sol";

contract ReviewCallbackProbe {
    FreeLP public lp;
    address public holder;
    address public destination;
    uint256 public observations;
    uint256 public existingObservations;
    bool public attemptTransfer;
    bool public transferred;
    event Observed(uint256 id, bool exists, bool transferred);

    function configure(FreeLP manager, address owner, address recipient, bool attempt) external {
        lp = manager;
        holder = owner;
        destination = recipient;
        attemptTransfer = attempt;
        observations = 0;
        existingObservations = 0;
        transferred = false;
    }

    function register(ICore core, CallPoints memory points) external {
        core.registerExtension(points);
    }

    function beforeUpdatePosition(Locker, PoolKey memory, PositionId id, int128) external {
        _observe(id);
    }

    function afterUpdatePosition(Locker, PoolKey memory, PositionId id, int128, PoolBalanceUpdate, PoolState) external {
        _observe(id);
    }

    function beforeCollectFees(Locker, PoolKey memory, PositionId id) external {
        _observe(id);
    }

    function afterCollectFees(Locker, PoolKey memory, PositionId id, uint128, uint128) external {
        _observe(id);
    }

    function _observe(PositionId positionId) private {
        uint256 id = uint192(positionId.salt());
        (bool exists,) = address(lp).staticcall(abi.encodeCall(lp.ownerOf, (id)));
        observations++;
        if (exists) existingObservations++;
        bool moved;
        if (attemptTransfer) (moved,) = address(lp).call(abi.encodeCall(lp.transferFrom, (holder, destination, id)));
        transferred = transferred || moved;
        emit Observed(id, exists, moved);
    }
}

contract ReviewPaymentToken is TestToken {
    FreeLP private lp;
    address private holder;
    bool public observed;
    bool public nftExisted;
    bool public transferSucceeded;
    constructor(address owner) TestToken(owner) {}

    function configure(FreeLP manager, address owner) external {
        lp = manager;
        holder = owner;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);
        if (address(lp) != address(0)) {
            observed = true;
            uint256 id = lp.nextId() - 1;
            (nftExisted,) = address(lp).staticcall(abi.encodeCall(lp.ownerOf, (id)));
            (transferSucceeded,) = address(lp).call(abi.encodeCall(lp.transferFrom, (holder, address(0xbeef), id)));
        }
        return result;
    }
}

contract ReviewRejectNative {
    receive() external payable {
        revert("reject principal");
    }
}

contract FreeLPReviewTest is FullTest {
    using CoreLib for ICore;
    FreeLP lp;
    PoolKeyIndex index;
    FreeLPDataFetcher reader;
    PoolKey key;

    function setUp() public override {
        super.setUp();
        index = new PoolKeyIndex(core);
        lp = new FreeLP(core, index, new FreeLPMetadataRenderer());
        reader = new FreeLPDataFetcher(core);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        key = createPool(0, 0, 10);
    }

    function _create(PoolKey memory pool) private returns (uint256 id, uint128 liquidity) {
        (id, liquidity,,) = lp.createPosition(pool, -1000, 1000, 1 ether, 1 ether, 1);
    }

    function _probe() private returns (ReviewCallbackProbe probe, PoolKey memory pool) {
        CallPoints memory points = CallPoints(false, false, false, false, true, true, true, true);
        address implementation = address(new ReviewCallbackProbe());
        address target = address((uint160(points.toUint8()) << 152) | 0x9876);
        vm.etch(target, implementation.code);
        probe = ReviewCallbackProbe(target);
        probe.register(core, points);
        probe.configure(lp, address(this), address(0xbeef), true);
        lp.setApprovalForAll(target, true);
        pool = createPool(0, 0, 10, target);
    }

    function test_reviewMintAfterExtensionCallbacksAndOrderedEvents() public {
        (ReviewCallbackProbe probe, PoolKey memory pool) = _probe();
        vm.recordLogs();
        (uint256 id,) = _create(pool);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(probe.observations(), 2);
        assertEq(probe.existingObservations(), 0);
        assertFalse(probe.transferred());
        assertEq(lp.ownerOf(id), address(this));
        uint256 created = _event(
            logs, address(lp), keccak256("PositionCreated(uint256,address,(address,address,bytes32),int32,int32)")
        );
        uint256 observed = _event(logs, address(probe), keccak256("Observed(uint256,bool,bool)"));
        uint256 added = _event(logs, address(lp), keccak256("LiquidityAdded(uint256,uint128,uint128,uint128)"));
        uint256 minted = _event(logs, address(lp), keccak256("Transfer(address,address,uint256)"));
        assertLt(created, observed);
        assertLt(observed, added);
        assertLt(added, minted);
    }

    function _event(Vm.Log[] memory logs, address emitter, bytes32 topic) private pure returns (uint256) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) return i;
        }
        revert("missing event");
    }

    function test_reviewMintAfterTokenPaymentCallback() public {
        ReviewPaymentToken payment = new ReviewPaymentToken(address(this));
        payment.approve(address(lp), type(uint256).max);
        payment.configure(lp, address(this));
        lp.setApprovalForAll(address(payment), true);
        address a = address(payment);
        address b = address(token1);
        if (a > b) (a, b) = (b, a);
        PoolKey memory pool = createPool(a, b, 0, createConcentratedPoolConfig(0, 10, address(0)));
        (uint256 id,) = _create(pool);
        assertTrue(payment.observed());
        assertFalse(payment.nftExisted());
        assertFalse(payment.transferSucceeded());
        assertEq(lp.ownerOf(id), address(this));
    }

    function test_reviewFullWithdrawalBurnsBeforeEveryCoreCallback() public {
        (ReviewCallbackProbe probe, PoolKey memory pool) = _probe();
        (uint256 id, uint128 liquidity) = _create(pool);
        probe.configure(lp, address(this), address(0xbeef), true);
        lp.withdraw(id, liquidity, address(this));
        assertEq(probe.observations(), 4);
        assertEq(probe.existingObservations(), 0);
        assertFalse(probe.transferred());
        assertEq(lp.balanceOf(address(this)), 0);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        lp.ownerOf(id);
    }

    function test_reviewPartialWithdrawalCannotSellNftDuringCoreCallback() public {
        (ReviewCallbackProbe probe, PoolKey memory pool) = _probe();
        (uint256 id, uint128 liquidity) = _create(pool);
        probe.configure(lp, address(this), address(0xbeef), true);
        vm.expectRevert(FreeLP.InvalidValue.selector);
        lp.withdraw(id, liquidity / 2, address(this));
        assertEq(lp.ownerOf(id), address(this));
        assertEq(reader.positionAmounts(lp, id).liquidity, liquidity);
    }

    function test_reviewFailedPayoutRestoresBurnedNftAndLiquidity() public {
        vm.deal(address(this), 2 ether);
        PoolKey memory pool = createETHPool(0, 0, 10);
        (uint256 id, uint128 liquidity,,) = lp.createPosition{value: 1 ether}(pool, -1000, 1000, 1 ether, 1 ether, 1);
        lp.refundNativeToken();
        address recipient = address(new ReviewRejectNative());
        vm.expectRevert();
        lp.withdraw(id, liquidity, recipient);
        assertEq(lp.ownerOf(id), address(this));
        assertEq(reader.positionAmounts(lp, id).liquidity, liquidity);
        assertEq(lp.tokenOfOwnerByIndex(address(this), 0), id);
    }

    function test_reviewSelfTransferLeavesOwnerEnumerationAndPositionUnchanged() public {
        (uint256 first, uint128 liquidity) = _create(key);
        (uint256 second,) = _create(key);
        (PoolId poolId, int32 lower, int32 upper) = lp.position(first);
        lp.approve(address(0xbeef), first);
        lp.transferFrom(address(this), address(this), first);
        assertEq(lp.balanceOf(address(this)), 2);
        assertEq(lp.tokenOfOwnerByIndex(address(this), 0), first);
        assertEq(lp.tokenOfOwnerByIndex(address(this), 1), second);
        (PoolId afterId, int32 afterLower, int32 afterUpper) = lp.position(first);
        assertEq(PoolId.unwrap(afterId), PoolId.unwrap(poolId));
        assertEq(afterLower, lower);
        assertEq(afterUpper, upper);
        assertEq(reader.positionAmounts(lp, first).liquidity, liquidity);
        assertEq(lp.nextId(), 3);
        // Standard ERC721 transfer semantics still clear approval, even for self-transfers.
        assertEq(lp.getApproved(first), address(0));
    }

    function test_reviewTransfersToZeroAreNotBurns() public {
        (uint256 id, uint128 liquidity) = _create(key);
        vm.expectRevert(ERC721.TransferToZeroAddress.selector);
        lp.transferFrom(address(this), address(0), id);
        vm.expectRevert(ERC721.TransferToZeroAddress.selector);
        lp.safeTransferFrom(address(this), address(0), id);
        vm.expectRevert(ERC721.TransferToZeroAddress.selector);
        lp.safeTransferFrom(address(this), address(0), id, "");
        assertEq(lp.ownerOf(id), address(this));
        assertEq(reader.positionAmounts(lp, id).liquidity, liquidity);
        (bool standaloneBurn,) = address(lp).call(abi.encodeWithSignature("burn(uint256)", id));
        assertFalse(standaloneBurn);
    }

    function test_reviewIdempotentRegistrationNeedsNoExternalPrecheck() public {
        vm.mockCallRevert(address(index), abi.encodeCall(index.isRegistered, (key.toPoolId())), "extra external check");
        _create(key);
        _create(key);
        assertEq(index.poolIdCount(), 1);
        assertEq(index.tokenPoolIdCount(key.token0), 1);
        assertEq(index.tokenPoolIdCount(key.token1), 1);
    }

    function test_reviewExplicitInitializationIsIdempotent() public {
        PoolKey memory pool = PoolKey(address(token0), address(token1), createConcentratedPoolConfig(1, 10, address(0)));
        vm.expectRevert(ICore.PoolNotInitialized.selector);
        _create(pool);
        (bool initialized, SqrtRatio first) = lp.maybeInitializePool(pool, 123);
        assertTrue(initialized);
        (bool again, SqrtRatio second) = lp.maybeInitializePool(pool, -999);
        assertFalse(again);
        assertEq(SqrtRatio.unwrap(first), SqrtRatio.unwrap(second));
        _create(pool);
    }

    function test_reviewManagerAndRendererFitRuntimeCodeLimit() public view {
        assertLe(address(lp).code.length, 24576);
        assertLe(address(lp.METADATA_RENDERER()).code.length, 24576);
    }

    function test_reviewFailedMulticallRollsBackInitializationAndIdAllocation() public {
        PoolKey memory pool = PoolKey(address(token0), address(token1), createConcentratedPoolConfig(2, 10, address(0)));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(lp.maybeInitializePool, (pool, 0));
        calls[1] = abi.encodeCall(lp.createPosition, (pool, -1000, 1000, 0, 0, 1));
        vm.expectRevert(FreeLP.Slippage.selector);
        lp.multicall(calls);
        assertFalse(ICore(core).poolState(pool.toPoolId()).isInitialized());
        assertEq(lp.nextId(), 1);
        assertFalse(index.isRegistered(pool.toPoolId()));
    }
}
