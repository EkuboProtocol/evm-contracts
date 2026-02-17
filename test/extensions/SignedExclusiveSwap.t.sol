// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {SignedExclusiveSwapLib} from "../../src/libraries/SignedExclusiveSwapLib.sol";
import {SignedExclusiveSwap, signedExclusiveSwapCallPoints} from "../../src/extensions/SignedExclusiveSwap.sol";
import {ISignedExclusiveSwap, SignedSwapPayload} from "../../src/interfaces/extensions/ISignedExclusiveSwap.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {Locker} from "../../src/types/locker.sol";

contract SignedExclusiveSwapHarness is BaseLocker {
    using FlashAccountantLib for *;
    using SignedExclusiveSwapLib for ICore;

    constructor(ICore core) BaseLocker(core) {}

    function swapSigned(address extension, SignedSwapPayload memory payload, address swapper, address recipient)
        external
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        (balanceUpdate, stateAfter) =
            abi.decode(lock(abi.encode(extension, payload, swapper, recipient)), (PoolBalanceUpdate, PoolState));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        (address extension, SignedSwapPayload memory payload, address swapper, address recipient) =
            abi.decode(data, (address, SignedSwapPayload, address, address));

        (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) =
            ICore(payable(address(ACCOUNTANT))).swap(extension, payload);

        if (payload.params.isPriceIncreasing()) {
            if (balanceUpdate.delta0() != 0) {
                ACCOUNTANT.withdraw(payload.poolKey.token0, recipient, uint128(-balanceUpdate.delta0()));
            }
            if (balanceUpdate.delta1() != 0) {
                ACCOUNTANT.payFrom(swapper, payload.poolKey.token1, uint128(balanceUpdate.delta1()));
            }
        } else {
            if (balanceUpdate.delta1() != 0) {
                ACCOUNTANT.withdraw(payload.poolKey.token1, recipient, uint128(-balanceUpdate.delta1()));
            }
            if (balanceUpdate.delta0() != 0) {
                ACCOUNTANT.payFrom(swapper, payload.poolKey.token0, uint128(balanceUpdate.delta0()));
            }
        }

        result = abi.encode(balanceUpdate, stateAfter);
    }
}

contract SignedExclusiveSwapTest is FullTest {
    using CoreLib for *;
    using SignedExclusiveSwapLib for *;

    uint256 internal controllerPk;
    address internal controller;
    SignedExclusiveSwap internal signedExclusiveSwap;
    SignedExclusiveSwapHarness internal harness;

    function setUp() public override {
        FullTest.setUp();

        controllerPk = 0xA11CE;
        controller = vm.addr(controllerPk);

        address deployAddress = address(uint160(signedExclusiveSwapCallPoints().toUint8()) << 152);
        deployCodeTo("SignedExclusiveSwap.sol", abi.encode(core, controller), deployAddress);
        signedExclusiveSwap = SignedExclusiveSwap(deployAddress);

        harness = new SignedExclusiveSwapHarness(core);
    }

    function coolAllContracts() internal override {
        FullTest.coolAllContracts();
        vm.cool(address(signedExclusiveSwap));
        vm.cool(address(harness));
    }

    function _createPayload(
        PoolKey memory poolKey,
        SwapParameters params,
        address authorizedLocker,
        uint64 deadline,
        uint64 extraFee,
        uint256 nonce
    ) internal view returns (SignedSwapPayload memory payload) {
        payload = SignedSwapPayload({
            poolKey: poolKey,
            params: params,
            authorizedLocker: authorizedLocker,
            deadline: deadline,
            extraFee: extraFee,
            nonce: nonce,
            signature: bytes("")
        });
    }

    function test_signed_swap_helper_and_deferred_fee_donation() public {
        PoolKey memory poolKey = createPool({
            _token0: address(token0),
            _token1: address(token1),
            tick: 0,
            config: createConcentratedPoolConfig({
                _fee: uint64(uint256(1 << 64) / 100), _tickSpacing: 20_000, _extension: address(signedExclusiveSwap)
            })
        });
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        uint64 extraFee = uint64(uint256(1 << 64) / 200); // 0.5%
        uint64 deadline = uint64(block.timestamp + 1 hours);
        uint256 nonce = 7;

        SignedSwapPayload memory payload = _createPayload(
            poolKey,
            createSwapParameters({
                _isToken1: false, _amount: 100_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }),
            address(harness),
            deadline,
            extraFee,
            nonce
        );

        bytes32 digest = payload.hashTypedData(address(signedExclusiveSwap));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        payload.signature = abi.encodePacked(r, s, v);

        coolAllContracts();
        (PoolBalanceUpdate balanceUpdate,) =
            harness.swapSigned(address(signedExclusiveSwap), payload, address(this), address(this));

        assertEq(balanceUpdate.delta0(), 100_000);
        assertLt(balanceUpdate.delta1(), 0);
        assertTrue(signedExclusiveSwap.nonceBitmap(nonce >> 8).isSet(uint8(nonce & 0xff)));

        PoolId poolId = poolKey.toPoolId();
        (, uint128 saved1Before) =
            core.savedBalances(address(signedExclusiveSwap), poolKey.token0, poolKey.token1, PoolId.unwrap(poolId));
        assertGt(saved1Before, 0);

        advanceTime(1);
        signedExclusiveSwap.accumulatePoolFees(poolKey);
        (, uint128 saved1After) =
            core.savedBalances(address(signedExclusiveSwap), poolKey.token0, poolKey.token1, PoolId.unwrap(poolId));
        assertEq(saved1After, 1);
    }

    function test_revert_nonce_reuse() public {
        PoolKey memory poolKey = createPool({
            _token0: address(token0),
            _token1: address(token1),
            tick: 0,
            config: createConcentratedPoolConfig({
                _fee: uint64(uint256(1 << 64) / 100), _tickSpacing: 20_000, _extension: address(signedExclusiveSwap)
            })
        });
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SignedSwapPayload memory payload = _createPayload(
            poolKey,
            createSwapParameters({
                _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }),
            address(0),
            uint64(block.timestamp + 1 hours),
            uint64(uint256(1 << 64) / 500),
            11
        );

        bytes32 digest = payload.hashTypedData(address(signedExclusiveSwap));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        payload.signature = abi.encodePacked(r, s, v);

        harness.swapSigned(address(signedExclusiveSwap), payload, address(this), address(this));

        vm.expectRevert(ISignedExclusiveSwap.NonceAlreadyUsed.selector);
        harness.swapSigned(address(signedExclusiveSwap), payload, address(this), address(this));
    }

    function test_revert_unauthorized_locker() public {
        PoolKey memory poolKey = createPool({
            _token0: address(token0),
            _token1: address(token1),
            tick: 0,
            config: createConcentratedPoolConfig({
                _fee: uint64(uint256(1 << 64) / 100), _tickSpacing: 20_000, _extension: address(signedExclusiveSwap)
            })
        });
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SignedSwapPayload memory payload = _createPayload(
            poolKey,
            createSwapParameters({
                _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }),
            address(0xBEEF),
            uint64(block.timestamp + 1 hours),
            uint64(uint256(1 << 64) / 500),
            99
        );

        bytes32 digest = payload.hashTypedData(address(signedExclusiveSwap));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        payload.signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ISignedExclusiveSwap.UnauthorizedLocker.selector);
        harness.swapSigned(address(signedExclusiveSwap), payload, address(this), address(this));
    }
}
