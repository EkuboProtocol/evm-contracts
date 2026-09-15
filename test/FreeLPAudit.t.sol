// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest, MockExtension} from "./FullTest.sol";
import {TestToken} from "./TestToken.sol";
import {FreeLP} from "../src/FreeLP.sol";
import {FreeLPMetadataRenderer} from "../src/FreeLPMetadataRenderer.sol";
import {FreeLPDataFetcher} from "../src/lens/FreeLPDataFetcher.sol";
import {PoolKeyIndex} from "../src/PoolKeyIndex.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PositionId} from "../src/types/positionId.sol";
import {Locker} from "../src/types/locker.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {PoolState} from "../src/types/poolState.sol";
import {byteToCallPoints} from "../src/types/callPoints.sol";
import {createConcentratedPoolConfig} from "../src/types/poolConfig.sol";
import {PoolId} from "../src/types/poolId.sol";
import {RouteNode, TokenAmount} from "../src/base/BaseRouter.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";

contract AuditNativeToken is TestToken {
    FreeLP private manager;
    PoolKey private key;
    bool private deposit;
    bool public nestedDepositSucceeded;
    uint256 public nestedValue;

    function fundNestedDeposit(uint256 amount) external {
        nestedValue = amount;
    }

    constructor(address owner) TestToken(owner) {}

    function arm(FreeLP lp, PoolKey memory pool, bool mint) external {
        manager = lp;
        key = pool;
        deposit = mint;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);
        if (address(manager) != address(0)) {
            if (deposit) {
                (nestedDepositSucceeded,) = address(manager).call{value: nestedValue}(
                    abi.encodeCall(manager.createPosition, (key, 1000, 2000, 1 ether, 0, 1))
                );
            } else {
                manager.refundNativeToken();
            }
        }
        return result;
    }

    receive() external payable {}
}

contract AuditDepositExtension {
    FreeLP private manager;
    address private holder;
    uint256 private tokenId;
    uint8 private action;

    function register(ICore core) external {
        core.registerExtension(byteToCallPoints(8));
    }

    function arm(FreeLP lp, address owner, uint256 id, uint8 mode) external {
        manager = lp;
        holder = owner;
        tokenId = id;
        action = mode;
    }

    function afterUpdatePosition(Locker, PoolKey memory, PositionId, int128 delta, PoolBalanceUpdate, PoolState)
        external
    {
        uint8 mode = action;
        if (mode == 0 || delta <= 0) return;
        action = 0;
        if (mode == 1) manager.withdraw(tokenId, uint128(delta), address(0xbeef));
        else manager.transferFrom(holder, address(0xbeef), tokenId);
    }
}

contract FreeLPAuditTest is FullTest {
    FreeLP lp;
    PoolKeyIndex index;
    FreeLPDataFetcher reader;

    function setUp() public override {
        super.setUp();
        index = new PoolKeyIndex(core);
        lp = new FreeLP(core, index, new FreeLPMetadataRenderer());
        reader = new FreeLPDataFetcher(core);
        token0.approve(address(lp), type(uint256).max);
        token1.approve(address(lp), type(uint256).max);
        vm.deal(address(this), 20 ether);
    }

    function test_auditExplicitRefundReturnsNativeSurplus() public {
        PoolKey memory key = createETHPool(0, 0, 10);
        uint256 beforeBalance = address(this).balance;
        (,, uint128 spent,) = lp.createPosition{value: 2 ether}(key, 1000, 2000, 1 ether, 0, 1);
        lp.refundNativeToken();
        assertEq(address(lp).balance, 0);
        assertEq(address(this).balance, beforeBalance - spent);
        vm.prank(address(0xbeef));
        lp.refundNativeToken();
        assertEq(address(0xbeef).balance, 0);
    }

    function _nativeToken(bool mint) private returns (AuditNativeToken token) {
        token = new AuditNativeToken(address(this));
        PoolKey memory key = PoolKey(address(0), address(token), createConcentratedPoolConfig(0, 10, address(0)));
        core.initializePool(key, 0);
        token.approve(address(lp), type(uint256).max);
        token.arm(lp, key, mint);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(lp.createPosition, (key, -1000, 1000, 1 ether, 1 ether, 1));
        calls[1] = abi.encodeCall(lp.refundNativeToken, ());
        lp.multicall{value: 3 ether}(calls);
    }

    function test_auditSharedNativeBalanceIsAvailableToCallbackRefund() public {
        AuditNativeToken token = _nativeToken(false);
        assertGt(address(token).balance, 0);
        assertEq(address(lp).balance, 0);
    }

    function test_auditSharedNativeBalanceIsAvailableToCallbackDeposit() public {
        AuditNativeToken token = _nativeToken(true);
        assertTrue(token.nestedDepositSucceeded());
        assertEq(lp.balanceOf(address(token)), 1);
        assertEq(address(lp).balance, 0);
    }

    function _depositAttack(uint8 mode) private {
        address target = address((uint160(8) << 152) | 0x1234);
        vm.etch(target, address(new AuditDepositExtension()).code);
        AuditDepositExtension extension = AuditDepositExtension(target);
        extension.register(core);
        PoolKey memory key = createPool(0, 0, 10, target);
        (uint256 id, uint128 initial,,) = lp.createPosition(key, -1000, 1000, 1 ether, 1 ether, 1);
        lp.setApprovalForAll(target, true);
        extension.arm(lp, address(this), id, mode);
        vm.expectRevert(FreeLP.InvalidValue.selector);
        lp.addLiquidity(id, 1 ether, 1 ether, 1);
        assertEq(reader.positionAmounts(lp, id).liquidity, initial);
        assertEq(lp.ownerOf(id), address(this));
    }

    function test_auditNestedCallerCanDepositItsOwnNativeFunds() public {
        AuditNativeToken token = new AuditNativeToken(address(this));
        PoolKey memory key = PoolKey(address(0), address(token), createConcentratedPoolConfig(0, 10, address(0)));
        core.initializePool(key, 0);
        token.approve(address(lp), type(uint256).max);
        token.arm(lp, key, true);
        vm.deal(address(token), 1 ether);
        token.fundNestedDeposit(1 ether);
        lp.createPosition{value: 3 ether}(key, -1000, 1000, 1 ether, 1 ether, 1);
        lp.refundNativeToken();
        assertTrue(token.nestedDepositSucceeded());
        assertEq(lp.balanceOf(address(token)), 1);
        assertEq(lp.balanceOf(address(this)), 1);
        assertEq(address(lp).balance, 0);
    }

    function test_auditUnassignedNativeBalanceRemainsPermissionlesslyRefundable() public {
        vm.deal(address(lp), 3 ether);
        uint256 beforeBalance = address(this).balance;
        lp.refundNativeToken();
        assertEq(address(lp).balance, 0);
        assertEq(address(this).balance, beforeBalance + 3 ether);
    }

    function test_auditNativeDepositMayLeaveLeftoversWithoutRefund() public {
        PoolKey memory key = createETHPool(0, 0, 10);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(lp.createPosition, (key, 1000, 2000, 1 ether, 0, 1));
        bytes[] memory results = lp.multicall{value: 1 ether + 1}(calls);
        (uint256 id,, uint128 spent,) = abi.decode(results[0], (uint256, uint128, uint128, uint128));
        assertEq(lp.ownerOf(id), address(this));
        assertEq(address(lp).balance, 1 ether + 1 - spent);
        assertGt(address(lp).balance, 0);
    }

    function test_auditWholePairReadCanExceedGasWhileIndexedReadsRemainAvailable() public {
        PoolKey memory key;
        for (uint64 i; i < 128; ++i) {
            key = createPool(0, i, 10);
            index.register(key);
        }
        vm.cool(address(index));
        (bool whole,) =
            address(index).staticcall{gas: 50000}(abi.encodeCall(index.getPoolKeysByPair, (key.token0, key.token1)));
        assertFalse(whole);
        vm.cool(address(index));
        (bool bounded, bytes memory data) =
            address(index).staticcall{gas: 50000}(abi.encodeCall(index.pairPoolIds, (key.token0, key.token1, 127)));
        assertTrue(bounded);
        assertEq(abi.decode(data, (bytes32)), PoolId.unwrap(key.toPoolId()));
        assertEq(index.pairPoolIdCount(key.token0, key.token1), 128);
    }

    function test_auditWithdrawalUsesExecutionPriceWithoutOutputBounds() public {
        PoolKey memory key = createPool(0, 0, 10);
        (uint256 id, uint128 liquidity,,) = lp.createPosition(key, -1000, 1000, 1 ether, 1 ether, 1);
        FreeLPDataFetcher.Amounts memory beforeAmounts = reader.positionAmounts(lp, id);
        assertGt(beforeAmounts.principal1, 0);
        token0.approve(address(router), 10 ether);
        router.swapAllowPartialFill(RouteNode(key, SqrtRatio.wrap(0), 0), TokenAmount(address(token0), 10 ether));
        (uint256 amount0, uint256 amount1) = lp.withdraw(id, liquidity, address(this));
        assertGt(amount0, beforeAmounts.principal0);
        assertEq(amount1, 0);
    }

    function test_auditAddedLiquidityCannotBeWithdrawnDuringCallback() public {
        _depositAttack(1);
    }

    function test_auditDepositCannotChangeOwnerDuringCallback() public {
        _depositAttack(2);
    }

    function test_auditCombinedFeeAndPrincipalAboveUint128() public {
        MockExtension extension = createAndRegisterExtension(byteToCallPoints(8));
        PoolKey memory key = createPool(0, 0, 10, address(extension));
        (uint256 id, uint128 liquidity,,) = lp.createPosition(key, -1000, 1000, 1 ether, 1 ether, 1);
        token0.approve(address(extension), type(uint256).max);
        token1.approve(address(extension), type(uint256).max);
        extension.accumulateFees(key, type(uint128).max, type(uint128).max);
        (uint256 amount0, uint256 amount1) = lp.withdraw(id, liquidity, address(this));
        assertGt(amount0, type(uint128).max);
        assertGt(amount1, type(uint128).max);
        assertEq(lp.balanceOf(address(this)), 0);
    }
}
