// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {SignedSwapMeta, createSignedSwapMeta} from "../../src/types/signedSwapMeta.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {Bitmap} from "../../src/types/bitmap.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {SignedExclusiveSwapLib} from "../../src/libraries/SignedExclusiveSwapLib.sol";
import {SignedExclusiveSwap, signedExclusiveSwapCallPoints} from "../../src/extensions/SignedExclusiveSwap.sol";
import {ISignedExclusiveSwap} from "../../src/interfaces/extensions/ISignedExclusiveSwap.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract MockSigner1271 {
    address internal immutable _signer;
    bytes4 internal constant _MAGIC_VALUE = 0x1626ba7e;

    constructor(address signer) {
        _signer = signer;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (uint8 v, bytes32 r, bytes32 s) = vmSafeDecodeSignature(signature);
        if (ecrecover(hash, v, r, s) == _signer) return _MAGIC_VALUE;
        return bytes4(0xffffffff);
    }

    function vmSafeDecodeSignature(bytes calldata signature) private pure returns (uint8 v, bytes32 r, bytes32 s) {
        if (signature.length != 65) return (0, bytes32(0), bytes32(0));
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
    }
}

contract SignedExclusiveSwapHarness is BaseLocker {
    using FlashAccountantLib for *;
    using SignedExclusiveSwapLib for ICore;

    constructor(ICore core) BaseLocker(core) {}

    function swapSigned(
        address extension,
        PoolKey memory poolKey,
        SwapParameters params,
        SignedSwapMeta meta,
        PoolBalanceUpdate minBalanceUpdate,
        bytes memory signature,
        address swapper,
        address recipient
    ) external returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) {
        (balanceUpdate, stateAfter) = abi.decode(
            lock(abi.encode(extension, poolKey, params, meta, minBalanceUpdate, signature, swapper, recipient)),
            (PoolBalanceUpdate, PoolState)
        );
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        (
            address extension,
            PoolKey memory poolKey,
            SwapParameters params,
            SignedSwapMeta meta,
            PoolBalanceUpdate minBalanceUpdate,
            bytes memory signature,
            address swapper,
            address recipient
        ) = abi.decode(
            data, (address, PoolKey, SwapParameters, SignedSwapMeta, PoolBalanceUpdate, bytes, address, address)
        );

        (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) =
            ICore(payable(address(ACCOUNTANT))).swap(extension, poolKey, params, meta, minBalanceUpdate, signature);

        if (params.isPriceIncreasing()) {
            if (balanceUpdate.delta0() != 0) {
                ACCOUNTANT.withdraw(poolKey.token0, recipient, uint128(-balanceUpdate.delta0()));
            }
            if (balanceUpdate.delta1() != 0) {
                ACCOUNTANT.payFrom(swapper, poolKey.token1, uint128(balanceUpdate.delta1()));
            }
        } else {
            if (balanceUpdate.delta1() != 0) {
                ACCOUNTANT.withdraw(poolKey.token1, recipient, uint128(-balanceUpdate.delta1()));
            }
            if (balanceUpdate.delta0() != 0) {
                ACCOUNTANT.payFrom(swapper, poolKey.token0, uint128(balanceUpdate.delta0()));
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
    uint256 internal adminPk;
    address internal admin;
    SignedExclusiveSwap internal signedExclusiveSwap;
    SignedExclusiveSwapHarness internal harness;
    PoolBalanceUpdate internal constant MIN_BALANCE_UPDATE =
        PoolBalanceUpdate.wrap(bytes32(0x8000000000000000000000000000000080000000000000000000000000000000));

    function setUp() public override {
        FullTest.setUp();

        adminPk = 0xB0B;
        admin = vm.addr(adminPk);
        controllerPk = 0xA11CE;
        controller = vm.addr(controllerPk);

        address deployAddress = address(uint160(signedExclusiveSwapCallPoints().toUint8()) << 152);
        deployCodeTo("SignedExclusiveSwap.sol", abi.encode(core, admin), deployAddress);
        signedExclusiveSwap = SignedExclusiveSwap(deployAddress);

        harness = new SignedExclusiveSwapHarness(core);
    }

    function coolAllContracts() internal override {
        FullTest.coolAllContracts();
        vm.cool(address(signedExclusiveSwap));
        vm.cool(address(harness));
    }

    function signedExclusiveSwapPoolKey(uint32 tickSpacing) internal view returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createConcentratedPoolConfig({
                _fee: 0, _tickSpacing: tickSpacing, _extension: address(signedExclusiveSwap)
            })
        });
    }

    function createSignedExclusiveSwapPool(int32 tick, uint32 tickSpacing) internal returns (PoolKey memory poolKey) {
        poolKey = createSignedExclusiveSwapPool(tick, tickSpacing, controller, true);
    }

    function createSignedExclusiveSwapPool(
        int32 tick,
        uint32 tickSpacing,
        address poolController,
        bool poolControllerIsEoa
    ) internal returns (PoolKey memory poolKey) {
        poolKey = signedExclusiveSwapPoolKey(tickSpacing);
        vm.prank(admin);
        signedExclusiveSwap.initializePool(poolKey, tick, poolController, poolControllerIsEoa);
    }

    function test_signed_swap_helper_and_deferred_fee_donation() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        uint32 fee = uint32(uint256(1 << 32) / 200); // 0.5%
        uint32 deadline = uint32(block.timestamp + 1 hours);
        uint32 nonce = 7;
        SwapParameters params = createSwapParameters({
            _isToken1: false, _amount: 100_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
        });
        SignedSwapMeta meta = createSignedSwapMeta(address(harness), deadline, fee, nonce);

        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, MIN_BALANCE_UPDATE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        coolAllContracts();
        (PoolBalanceUpdate balanceUpdate,) = harness.swapSigned(
            address(signedExclusiveSwap),
            poolKey,
            params,
            meta,
            MIN_BALANCE_UPDATE,
            signature,
            address(this),
            address(this)
        );

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

    /// forge-config: default.isolate = true
    function test_gas_signed_swap_token0_input_no_meta_fee() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
            _isToken1: false, _amount: 100_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
        });
        SignedSwapMeta meta = createSignedSwapMeta(address(harness), uint32(block.timestamp + 1 hours), 0, 300);
        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, MIN_BALANCE_UPDATE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        coolAllContracts();
        harness.swapSigned(
            address(signedExclusiveSwap),
            poolKey,
            params,
            meta,
            MIN_BALANCE_UPDATE,
            signature,
            address(this),
            address(this)
        );
        vm.snapshotGasLastCall("signedExclusiveSwap token0 input (no meta fee)");
    }

    /// forge-config: default.isolate = true
    function test_gas_signed_swap_token0_input_with_meta_fee() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
            _isToken1: false, _amount: 100_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
        });
        uint32 fee = uint32(uint256(1 << 32) / 200); // 0.5%
        SignedSwapMeta meta = createSignedSwapMeta(address(harness), uint32(block.timestamp + 1 hours), fee, 301);
        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, MIN_BALANCE_UPDATE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        coolAllContracts();
        harness.swapSigned(
            address(signedExclusiveSwap),
            poolKey,
            params,
            meta,
            MIN_BALANCE_UPDATE,
            signature,
            address(this),
            address(this)
        );
        vm.snapshotGasLastCall("signedExclusiveSwap token0 input (with meta fee)");
    }

    /// forge-config: default.isolate = true
    function test_gas_signed_swap_token1_input_with_meta_fee() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
            _isToken1: true, _amount: 100_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
        });
        uint32 fee = uint32(uint256(1 << 32) / 200); // 0.5%
        SignedSwapMeta meta = createSignedSwapMeta(address(harness), uint32(block.timestamp + 1 hours), fee, 302);
        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, MIN_BALANCE_UPDATE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        coolAllContracts();
        harness.swapSigned(
            address(signedExclusiveSwap),
            poolKey,
            params,
            meta,
            MIN_BALANCE_UPDATE,
            signature,
            address(this),
            address(this)
        );
        vm.snapshotGasLastCall("signedExclusiveSwap token1 input (with meta fee)");
    }

    function test_revert_nonce_reuse() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
            _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
        });
        SignedSwapMeta meta =
            createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), uint32(uint256(1 << 32) / 500), 11);

        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, MIN_BALANCE_UPDATE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        harness.swapSigned(
            address(signedExclusiveSwap),
            poolKey,
            params,
            meta,
            MIN_BALANCE_UPDATE,
            signature,
            address(this),
            address(this)
        );

        vm.expectRevert(ISignedExclusiveSwap.NonceAlreadyUsed.selector);
        harness.swapSigned(
            address(signedExclusiveSwap),
            poolKey,
            params,
            meta,
            MIN_BALANCE_UPDATE,
            signature,
            address(this),
            address(this)
        );
    }

    function test_revert_unauthorized_locker() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
            _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
        });
        SignedSwapMeta meta = createSignedSwapMeta(
            address(0xBEEF), uint32(block.timestamp + 1 hours), uint32(uint256(1 << 32) / 500), 99
        );

        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, MIN_BALANCE_UPDATE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ISignedExclusiveSwap.UnauthorizedLocker.selector);
        harness.swapSigned(
            address(signedExclusiveSwap),
            poolKey,
            params,
            meta,
            MIN_BALANCE_UPDATE,
            signature,
            address(this),
            address(this)
        );
    }

    function test_revert_direct_core_initialize_pool() public {
        PoolKey memory poolKey = signedExclusiveSwapPoolKey(20_000);

        vm.expectRevert(ISignedExclusiveSwap.PoolInitializationDisabled.selector);
        core.initializePool(poolKey, 0);
    }

    function test_initialize_pool_emits_pool_controller_updated() public {
        PoolKey memory poolKey = signedExclusiveSwapPoolKey(20_000);

        vm.expectEmit(true, true, false, true, address(signedExclusiveSwap));
        emit ISignedExclusiveSwap.PoolControllerUpdated(poolKey.toPoolId(), controller, true);

        vm.prank(admin);
        signedExclusiveSwap.initializePool(poolKey, 0, controller, true);
    }

    function test_owner_initializes_pool_with_specified_controller() public {
        uint256 nextControllerPk = 0xC0FFEE;
        address nextController = vm.addr(nextControllerPk);

        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000, nextController, true);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
            _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
        });
        SignedSwapMeta meta =
            createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), uint32(uint256(1 << 32) / 500), 121);

        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, MIN_BALANCE_UPDATE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(nextControllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        harness.swapSigned(
            address(signedExclusiveSwap),
            poolKey,
            params,
            meta,
            MIN_BALANCE_UPDATE,
            signature,
            address(this),
            address(this)
        );
    }

    function test_owner_updates_existing_pool_controller_to_contract() public {
        MockSigner1271 contractController = new MockSigner1271(controller);

        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        vm.prank(admin);
        signedExclusiveSwap.setPoolController(poolKey, address(contractController), false);

        SwapParameters params = createSwapParameters({
            _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
        });
        SignedSwapMeta meta =
            createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), uint32(uint256(1 << 32) / 500), 131);

        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, MIN_BALANCE_UPDATE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        harness.swapSigned(
            address(signedExclusiveSwap),
            poolKey,
            params,
            meta,
            MIN_BALANCE_UPDATE,
            signature,
            address(this),
            address(this)
        );
    }

    function test_revert_min_balance_update_not_met() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
            _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
        });
        SignedSwapMeta meta =
            createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), uint32(uint256(1 << 32) / 500), 211);
        PoolBalanceUpdate minBalanceUpdate = createPoolBalanceUpdate(type(int128).max, type(int128).max);

        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, minBalanceUpdate);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert();
        harness.swapSigned(
            address(signedExclusiveSwap),
            poolKey,
            params,
            meta,
            minBalanceUpdate,
            signature,
            address(this),
            address(this)
        );
    }

    function test_min_balance_update_allows_reasonable_bounds_token0_input() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
            _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
        });
        SignedSwapMeta meta =
            createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), uint32(uint256(1 << 32) / 500), 212);
        PoolBalanceUpdate minBalanceUpdate = createPoolBalanceUpdate(50_000, -60_000);

        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, minBalanceUpdate);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        (PoolBalanceUpdate actual,) = harness.swapSigned(
            address(signedExclusiveSwap),
            poolKey,
            params,
            meta,
            minBalanceUpdate,
            signature,
            address(this),
            address(this)
        );

        assertGe(actual.delta0(), minBalanceUpdate.delta0());
        assertGe(actual.delta1(), minBalanceUpdate.delta1());
    }

    function test_revert_min_balance_update_too_strict_pool_output_token0_input() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
            _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
        });
        SignedSwapMeta meta =
            createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), uint32(uint256(1 << 32) / 500), 213);
        PoolBalanceUpdate minBalanceUpdate = createPoolBalanceUpdate(50_000, -40_000);

        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, minBalanceUpdate);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert();
        harness.swapSigned(
            address(signedExclusiveSwap),
            poolKey,
            params,
            meta,
            minBalanceUpdate,
            signature,
            address(this),
            address(this)
        );
    }

    function test_revert_min_balance_update_too_strict_pool_output_token1_input() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params =
            createSwapParameters({_isToken1: true, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0});
        SignedSwapMeta meta =
            createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), uint32(uint256(1 << 32) / 500), 214);
        PoolBalanceUpdate minBalanceUpdate = createPoolBalanceUpdate(-40_000, 50_000);

        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, minBalanceUpdate);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert();
        harness.swapSigned(
            address(signedExclusiveSwap),
            poolKey,
            params,
            meta,
            minBalanceUpdate,
            signature,
            address(this),
            address(this)
        );
    }

    function test_revert_initialize_pool_not_owner() public {
        PoolKey memory poolKey = signedExclusiveSwapPoolKey(20_000);

        vm.expectRevert(Ownable.Unauthorized.selector);
        signedExclusiveSwap.initializePool(poolKey, 0, controller, true);
    }

    function test_revert_initialize_pool_wrong_extension() public {
        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createConcentratedPoolConfig({_fee: 0, _tickSpacing: 20_000, _extension: address(0)})
        });

        vm.prank(admin);
        vm.expectRevert(ISignedExclusiveSwap.PoolExtensionMustBeSelf.selector);
        signedExclusiveSwap.initializePool(poolKey, 0, controller, true);
    }

    function test_owner_can_set_nonce_bitmap() public {
        uint256 word = 42;
        Bitmap bitmap = Bitmap.wrap(type(uint256).max);

        vm.prank(admin);
        signedExclusiveSwap.setNonceBitmap(word, bitmap);

        assertEq(Bitmap.unwrap(signedExclusiveSwap.nonceBitmap(word)), type(uint256).max);
    }

    function test_revert_set_nonce_bitmap_not_owner() public {
        vm.expectRevert(Ownable.Unauthorized.selector);
        signedExclusiveSwap.setNonceBitmap(1, Bitmap.wrap(123));
    }

    function test_revert_set_pool_controller_not_owner() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);

        vm.expectRevert(Ownable.Unauthorized.selector);
        signedExclusiveSwap.setPoolController(poolKey, address(0x1234), true);
    }
}
