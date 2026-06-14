// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {VE33_SWAP, Ve33Rewards, ve33RewardsCallPoints} from "../../src/extensions/Ve33Rewards.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {computeFee} from "../../src/math/fee.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PositionId, createPositionId} from "../../src/types/positionId.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";

contract Ve33RewardsForwarder is BaseLocker {
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_UPDATE_POSITION = 0;
    uint256 private constant CALL_TYPE_SWAP = 1;

    ICore private immutable CORE_REF;

    constructor(ICore core) BaseLocker(core) {
        CORE_REF = core;
    }

    function updatePosition(PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta)
        external
        returns (PoolBalanceUpdate balanceUpdate)
    {
        balanceUpdate = abi.decode(
            lock(abi.encode(CALL_TYPE_UPDATE_POSITION, msg.sender, poolKey, positionId, liquidityDelta)),
            (PoolBalanceUpdate)
        );
    }

    function swap(PoolKey memory poolKey, bool isToken1, int128 amount, address recipient)
        external
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        (balanceUpdate, stateAfter) = abi.decode(
            lock(
                abi.encode(
                    CALL_TYPE_SWAP,
                    msg.sender,
                    poolKey,
                    createSwapParameters({
                        _isToken1: isToken1, _amount: amount, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
                    }),
                    recipient
                )
            ),
            (PoolBalanceUpdate, PoolState)
        );
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_UPDATE_POSITION) {
            (, address payer, PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta) =
                abi.decode(data, (uint256, address, PoolKey, PositionId, int128));
            PoolBalanceUpdate balanceUpdate = CORE_REF.updatePosition(poolKey, positionId, liquidityDelta);
            _settle(poolKey, payer, payer, balanceUpdate);
            result = abi.encode(balanceUpdate);
        } else {
            (, address payer, PoolKey memory poolKey, bytes32 params, address recipient) =
                abi.decode(data, (uint256, address, PoolKey, bytes32, address));
            (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) = abi.decode(
                CORE_REF.forward(poolKey.config.extension(), abi.encode(VE33_SWAP, poolKey, params)),
                (PoolBalanceUpdate, PoolState)
            );
            _settle(poolKey, payer, recipient, balanceUpdate);
            result = abi.encode(balanceUpdate, stateAfter);
        }
    }

    function _settle(PoolKey memory poolKey, address payer, address recipient, PoolBalanceUpdate balanceUpdate)
        private
    {
        int128 delta0 = balanceUpdate.delta0();
        int128 delta1 = balanceUpdate.delta1();

        if (delta0 > 0) {
            ACCOUNTANT.payFrom(payer, poolKey.token0, uint128(delta0));
        } else if (delta0 < 0) {
            ACCOUNTANT.withdraw(poolKey.token0, recipient, uint128(-delta0));
        }

        if (delta1 > 0) {
            ACCOUNTANT.payFrom(payer, poolKey.token1, uint128(delta1));
        } else if (delta1 < 0) {
            ACCOUNTANT.withdraw(poolKey.token1, recipient, uint128(-delta1));
        }
    }
}

contract Ve33RewardsTest is FullTest {
    using CoreLib for *;

    Ve33Rewards internal ve;
    Ve33RewardsForwarder internal forwarder;
    TestToken internal stakeToken;

    function setUp() public override {
        super.setUp();

        stakeToken = new TestToken(address(this));
        address deployAddress = address(uint160(ve33RewardsCallPoints().toUint8()) << 152);
        deployCodeTo("Ve33Rewards.sol", abi.encode(core, address(this), address(stakeToken)), deployAddress);
        ve = Ve33Rewards(payable(deployAddress));
        forwarder = new Ve33RewardsForwarder(core);

        stakeToken.approve(address(ve), type(uint256).max);
        token0.approve(address(forwarder), type(uint256).max);
        token1.approve(address(forwarder), type(uint256).max);
    }

    function test_forwardedSwapAccountsVoterFee() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(ve)});
        PositionId positionId = createPositionId(bytes24(uint192(1)), -100, 100);
        forwarder.updatePosition(poolKey, positionId, int128(uint128(1e18)));

        uint256 veId = ve.createLock(1e18, uint64(block.timestamp + 4 * 365 days));

        PoolKey[] memory poolKeys = new PoolKey[](1);
        poolKeys[0] = poolKey;
        uint256[] memory weights = new uint256[](1);
        weights[0] = 1;
        uint64[] memory swapFees = new uint64[](1);
        swapFees[0] = uint64(1 << 62);
        ve.vote(veId, poolKeys, weights, swapFees);

        forwarder.swap(poolKey, false, 100_000, address(this));

        uint128 expectedFee = computeFee(100_000, swapFees[0]);
        (uint128 saved0, uint128 saved1) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        assertEq(saved0, expectedFee);
        assertEq(saved1, 0);

        uint256 balanceBefore = token0.balanceOf(address(this));
        (uint128 claimed0, uint128 claimed1) = ve.claimPoolFees(veId, poolKey);
        assertApproxEqAbs(claimed0, expectedFee, 1);
        assertEq(claimed1, 0);
        assertEq(token0.balanceOf(address(this)), balanceBefore + claimed0);

        (saved0, saved1) =
            core.savedBalances(address(ve), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
        assertEq(saved0, expectedFee - claimed0);
        assertEq(saved1, 0);
    }
}
