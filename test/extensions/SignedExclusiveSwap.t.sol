// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {computeFee} from "../../src/math/fee.sol";
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
import {ControllerAddress} from "../../src/types/controllerAddress.sol";
import {
    SignedExclusiveSwapPoolState,
    createSignedExclusiveSwapPoolState
} from "../../src/types/signedExclusiveSwapPoolState.sol";
import {ExposedStorageLib} from "../../src/libraries/ExposedStorageLib.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {SignedExclusiveSwapLib} from "../../src/libraries/SignedExclusiveSwapLib.sol";
import {SignedExclusiveSwap, signedExclusiveSwapCallPoints} from "../../src/extensions/SignedExclusiveSwap.sol";
import {ISignedExclusiveSwap} from "../../src/interfaces/extensions/ISignedExclusiveSwap.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {EIP712} from "solady/utils/EIP712.sol";

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

contract SignedExclusiveSwapEIP712Reference is EIP712 {
    bytes32 internal constant _SIGNED_SWAP_TYPEHASH =
        keccak256("SignedSwap(bytes32 poolId,uint256 meta,bytes32 minBalanceUpdate)");

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "Ekubo SignedExclusiveSwap";
        version = "1";
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparator();
    }

    function hashTypedData(bytes32 structHash) external view returns (bytes32) {
        return _hashTypedData(structHash);
    }

    function hashSignedSwapStruct(PoolId poolId, SignedSwapMeta meta, PoolBalanceUpdate minBalanceUpdate)
        external
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                _SIGNED_SWAP_TYPEHASH, PoolId.unwrap(poolId), bytes32(SignedSwapMeta.unwrap(meta)), minBalanceUpdate
            )
        );
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
    using ExposedStorageLib for *;
    using CoreLib for *;
    using SignedExclusiveSwapLib for *;

    uint256 internal controllerPk;
    ControllerAddress internal controller;
    uint256 internal adminPk;
    address internal admin;
    SignedExclusiveSwap internal signedExclusiveSwap;
    SignedExclusiveSwapEIP712Reference internal eip712Reference;
    SignedExclusiveSwapHarness internal harness;
    PoolBalanceUpdate internal constant MIN_BALANCE_UPDATE =
        PoolBalanceUpdate.wrap(bytes32(0x8000000000000000000000000000000080000000000000000000000000000000));

    function setUp() public override {
        FullTest.setUp();

        adminPk = 0xB0B;
        admin = vm.addr(adminPk);
        controllerPk = 0xA11CE;
        while (uint160(vm.addr(controllerPk)) >> 159 != 0) {
            unchecked {
                ++controllerPk;
            }
        }
        controller = ControllerAddress.wrap(vm.addr(controllerPk));

        address deployAddress = address(uint160(signedExclusiveSwapCallPoints().toUint8()) << 152);
        deployCodeTo("SignedExclusiveSwap.sol", abi.encode(core, admin), deployAddress);
        signedExclusiveSwap = SignedExclusiveSwap(deployAddress);
        eip712Reference = new SignedExclusiveSwapEIP712Reference();

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
        poolKey = createSignedExclusiveSwapPool(tick, tickSpacing, controller);
    }

    function createSignedExclusiveSwapPool(int32 tick, uint32 tickSpacing, ControllerAddress poolController)
        internal
        returns (PoolKey memory poolKey)
    {
        return createSignedExclusiveSwapPool(tick, tickSpacing, poolController, 0);
    }

    function createSignedExclusiveSwapPool(int32 tick, uint32 tickSpacing, ControllerAddress poolController, uint64 fee)
        internal
        returns (PoolKey memory poolKey)
    {
        poolKey = signedExclusiveSwapPoolKey(tickSpacing);
        vm.prank(admin);
        signedExclusiveSwap.initializePool(poolKey, tick, poolController, fee);
    }

    function _poolState(PoolKey memory poolKey) internal view returns (SignedExclusiveSwapPoolState) {
        return SignedExclusiveSwapPoolState.wrap(signedExclusiveSwap.sload(PoolId.unwrap(poolKey.toPoolId())));
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
            }).withDefaultSqrtRatioLimit();
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

    function test_owner_fee_administration() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        assertEq(_poolState(poolKey).ownerFee(), 0);
        vm.expectRevert(Ownable.Unauthorized.selector);
        signedExclusiveSwap.setOwnerFee(poolKey, 1);
        vm.prank(admin);
        vm.expectEmit(address(signedExclusiveSwap));
        emit ISignedExclusiveSwap.PoolStateUpdated(
            poolKey.toPoolId(),
            createSignedExclusiveSwapPoolState({
                _controller: controller, _lastUpdateTime: uint32(block.timestamp), _ownerFee: type(uint64).max
            })
        );
        vm.expectCall(address(core), bytes(""), uint64(0));
        signedExclusiveSwap.setOwnerFee(poolKey, type(uint64).max);
        assertEq(_poolState(poolKey).ownerFee(), type(uint64).max);
        vm.expectRevert(Ownable.Unauthorized.selector);
        signedExclusiveSwap.withdrawOwnerFees(address(token0), address(token1), 0, 0, address(this));
    }

    function test_owner_fee_is_per_pool() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        PoolKey memory otherPool = createSignedExclusiveSwapPool(0, 10_000);
        vm.prank(admin);
        signedExclusiveSwap.setOwnerFee(poolKey, 1 << 63);
        assertEq(_poolState(poolKey).ownerFee(), 1 << 63);
        assertEq(_poolState(otherPool).ownerFee(), 0);
        vm.prank(admin);
        signedExclusiveSwap.setPoolController(poolKey, controller);
        advanceTime(1);
        signedExclusiveSwap.accumulatePoolFees(poolKey);
        assertEq(_poolState(poolKey).ownerFee(), 1 << 63);
    }

    function test_revert_owner_fee_uninitialized_pool() public {
        PoolKey memory poolKey = signedExclusiveSwapPoolKey(20_000);
        signedExclusiveSwap.accumulatePoolFees(poolKey);
        assertGt(_poolState(poolKey).lastUpdateTime(), 0);
        vm.prank(admin);
        vm.expectRevert(ICore.PoolNotInitialized.selector);
        signedExclusiveSwap.setOwnerFee(poolKey, 1);
    }

    function test_revert_owner_fee_wrong_extension() public {
        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createConcentratedPoolConfig({_fee: 0, _tickSpacing: 20_000, _extension: address(0)})
        });
        core.initializePool(poolKey, 0);
        vm.prank(admin);
        vm.expectRevert(ICore.PoolNotInitialized.selector);
        signedExclusiveSwap.setOwnerFee(poolKey, 1);
    }

    function _ownerFeeSwap(PoolKey memory poolKey, bool isToken1, int128 amount, uint32 fee)
        internal
        returns (PoolBalanceUpdate balanceUpdate)
    {
        SignedSwapMeta meta =
            createSignedSwapMeta(address(harness), uint32(block.timestamp + 1 hours), fee, type(uint64).max);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            controllerPk, signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, MIN_BALANCE_UPDATE)
        );
        (balanceUpdate,) = harness.swapSigned(
            address(signedExclusiveSwap),
            poolKey,
            createSwapParameters({
                    _isToken1: isToken1, _amount: amount, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
                }).withDefaultSqrtRatioLimit(),
            meta,
            MIN_BALANCE_UPDATE,
            abi.encodePacked(r, s, v),
            address(this),
            address(this)
        );
    }

    function test_fuzz_owner_fee_exact_in_token0(uint64 shareRate, uint128 amount, uint32 swapFee) public {
        _testOwnerFeeSplit(false, false, shareRate, amount, swapFee);
    }

    function test_fuzz_owner_fee_exact_in_token1(uint64 shareRate, uint128 amount, uint32 swapFee) public {
        _testOwnerFeeSplit(true, false, shareRate, amount, swapFee);
    }

    function test_fuzz_owner_fee_exact_out_token0(uint64 shareRate, uint128 amount, uint32 swapFee) public {
        _testOwnerFeeSplit(false, true, shareRate, amount, swapFee);
    }

    function test_fuzz_owner_fee_exact_out_token1(uint64 shareRate, uint128 amount, uint32 swapFee) public {
        _testOwnerFeeSplit(true, true, shareRate, amount, swapFee);
    }

    function _testOwnerFeeSplit(bool isToken1, bool exactOut, uint64 shareRate, uint128 amount, uint32 swapFee)
        internal
    {
        amount = uint128(bound(amount, 1, 100_000));
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000, controller, shareRate);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);
        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);
        uint256 snapshot = vm.snapshotState();
        vm.prank(admin);
        signedExclusiveSwap.setOwnerFee(poolKey, 0);
        int128 swapAmount = exactOut ? -int128(amount) : int128(amount);
        PoolBalanceUpdate baseline = _ownerFeeSwap(poolKey, isToken1, swapAmount, swapFee);
        (uint128 total0, uint128 total1) = core.savedBalances(
            address(signedExclusiveSwap), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId())
        );
        assertTrue(vm.revertToState(snapshot));
        PoolBalanceUpdate actual = _ownerFeeSwap(poolKey, isToken1, swapAmount, swapFee);
        assertEq(PoolBalanceUpdate.unwrap(actual), PoolBalanceUpdate.unwrap(baseline));
        uint128 expected0 = computeFee(total0, shareRate);
        uint128 expected1 = computeFee(total1, shareRate);
        (uint128 owner0, uint128 owner1) =
            core.savedBalances(address(signedExclusiveSwap), poolKey.token0, poolKey.token1, bytes32(0));
        assertEq(owner0, expected0);
        assertEq(owner1, expected1);
        (uint128 lp0, uint128 lp1) = core.savedBalances(
            address(signedExclusiveSwap), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId())
        );
        assertEq(uint256(lp0) + owner0, total0);
        assertEq(uint256(lp1) + owner1, total1);

        // Changing the rate does not take another share of already saved LP fees.
        vm.prank(admin);
        signedExclusiveSwap.setOwnerFee(poolKey, type(uint64).max);
        advanceTime(1);
        signedExclusiveSwap.accumulatePoolFees(poolKey);
        (uint128 after0, uint128 after1) =
            core.savedBalances(address(signedExclusiveSwap), poolKey.token0, poolKey.token1, bytes32(0));
        assertEq(after0, owner0);
        assertEq(after1, owner1);
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        vm.prank(admin);
        signedExclusiveSwap.withdrawOwnerFees(poolKey.token0, poolKey.token1, owner0, owner1, address(this));
        assertEq(token0.balanceOf(address(this)), balance0 + owner0);
        assertEq(token1.balanceOf(address(this)), balance1 + owner1);
        (after0, after1) = core.savedBalances(address(signedExclusiveSwap), poolKey.token0, poolKey.token1, bytes32(0));
        assertEq(after0, 0);
        assertEq(after1, 0);
    }

    function test_owner_fee_boundaries_all_swap_cases() public {
        uint64[3] memory rates = [uint64(0), uint64(1), type(uint64).max];
        for (uint256 direction; direction < 4; ++direction) {
            for (uint256 i; i < rates.length; ++i) {
                uint256 snapshot = vm.snapshotState();
                _testOwnerFeeSplit(direction & 1 != 0, direction & 2 != 0, rates[i], 100_000, type(uint32).max);
                assertTrue(vm.revertToState(snapshot));
            }
        }
    }

    function test_zero_owner_share_skips_saved_balance_call_all_swap_cases() public {
        vm.expectCall(
            address(core),
            abi.encodeWithSelector(ICore.updateSavedBalances.selector, address(token0), address(token1), bytes32(0)),
            uint64(0)
        );
        for (uint256 direction; direction < 4; ++direction) {
            for (uint256 scenario; scenario < 4; ++scenario) {
                uint256 snapshot = vm.snapshotState();
                uint64 rate = scenario == 0 || scenario == 3 ? 0 : type(uint64).max;
                PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000, controller, rate);
                createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);
                token0.approve(address(harness), type(uint256).max);
                token1.approve(address(harness), type(uint256).max);
                uint32 swapFee = scenario == 1 || scenario == 3 ? 0 : uint32(1 << 26);
                int128 amount = scenario == 2 ? int128(0) : int128(100_000);
                if (direction & 2 != 0) amount = -amount;
                _ownerFeeSwap(poolKey, direction & 1 != 0, amount, swapFee);
                (uint128 owner0, uint128 owner1) =
                    core.savedBalances(address(signedExclusiveSwap), poolKey.token0, poolKey.token1, bytes32(0));
                assertEq(owner0, 0);
                assertEq(owner1, 0);
                assertTrue(vm.revertToState(snapshot));
            }
        }
    }

    function test_owner_fee_inline_donation_and_rate_change() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);
        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);
        _ownerFeeSwap(poolKey, false, 100_000, uint32(1 << 26));
        advanceTime(1);
        uint256 snapshot = vm.snapshotState();
        _ownerFeeSwap(poolKey, false, 100_000, uint32(1 << 26));
        (, uint128 total) = core.savedBalances(
            address(signedExclusiveSwap), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId())
        );
        // Inline donation retains one unit of the old LP balance.
        uint128 newFee = total - 1;
        assertGt(newFee, 0);
        assertTrue(vm.revertToState(snapshot));
        vm.prank(admin);
        signedExclusiveSwap.setOwnerFee(poolKey, 1 << 63);
        _ownerFeeSwap(poolKey, false, 100_000, uint32(1 << 26));
        (, uint128 ownerShare) =
            core.savedBalances(address(signedExclusiveSwap), poolKey.token0, poolKey.token1, bytes32(0));
        assertEq(ownerShare, (newFee + 1) / 2);
        (, uint128 lpShare) = core.savedBalances(
            address(signedExclusiveSwap), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId())
        );
        assertEq(lpShare + ownerShare, total);
        vm.prank(admin);
        vm.expectRevert();
        signedExclusiveSwap.withdrawOwnerFees(poolKey.token0, poolKey.token1, 0, ownerShare + 1, address(this));
    }

    function test_owner_fee_rounds_up_entire_single_unit_fee() public {
        _testOwnerFeeSplit(false, true, 1, 1, uint32(1 << 26));
    }

    function test_zero_collected_fee_skips_owner_balance_update() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);
        vm.prank(admin);
        signedExclusiveSwap.setOwnerFee(poolKey, type(uint64).max);
        vm.expectCall(address(core), abi.encodeWithSelector(ICore.updateSavedBalances.selector), uint64(0));
        _ownerFeeSwap(poolKey, false, 0, type(uint32).max);
    }

    function test_hash_signed_swap_payload_matches_solady_eip712() public view {
        PoolId poolId = signedExclusiveSwapPoolKey(20_000).toPoolId();
        SignedSwapMeta meta = createSignedSwapMeta(address(harness), uint32(block.timestamp + 1 hours), 1_234_567, 777);
        PoolBalanceUpdate minBalanceUpdate = createPoolBalanceUpdate(123_456, -234_567);

        bytes32 structHash = eip712Reference.hashSignedSwapStruct(poolId, meta, minBalanceUpdate);
        bytes32 digestFromEIP712 = eip712Reference.hashTypedData(structHash);
        bytes32 digestFromLibrary = SignedExclusiveSwapLib.hashSignedSwapPayload(
            ISignedExclusiveSwap(address(eip712Reference)), poolId, meta, minBalanceUpdate
        );

        assertEq(digestFromLibrary, digestFromEIP712);
        assertEq(
            SignedExclusiveSwapLib.computeDomainSeparatorHash(ISignedExclusiveSwap(address(eip712Reference))),
            eip712Reference.domainSeparator()
        );
    }

    /// forge-config: default.isolate = true
    function test_gas_signed_swap_token0_input_no_meta_fee() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
                _isToken1: false, _amount: 100_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
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
            }).withDefaultSqrtRatioLimit();
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
            }).withDefaultSqrtRatioLimit();
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

    /// forge-config: default.isolate = true
    function test_gas_broadcast_signed_swaps_single() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);

        SignedSwapMeta meta = createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), 0, 303);
        PoolBalanceUpdate minBalanceUpdate = createPoolBalanceUpdate(10, -20);
        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, minBalanceUpdate);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        ISignedExclusiveSwap.SignedSwapBroadcast[] memory signedSwaps =
            new ISignedExclusiveSwap.SignedSwapBroadcast[](1);
        signedSwaps[0] = ISignedExclusiveSwap.SignedSwapBroadcast({
            poolId: poolKey.toPoolId(), meta: meta, minBalanceUpdate: minBalanceUpdate, signature: signature
        });

        coolAllContracts();
        signedExclusiveSwap.broadcastSignedSwaps(signedSwaps);
        vm.snapshotGasLastCall("signedExclusiveSwap broadcastSignedSwaps (single)");
    }

    function test_revert_nonce_reuse() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
                _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
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

    function test_nonce_max_not_consumed() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
                _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
        uint64 nonce = type(uint64).max;
        SignedSwapMeta meta =
            createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), uint32(uint256(1 << 32) / 500), nonce);

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

        uint256 word = nonce >> 8;
        uint8 bit = uint8(nonce & 0xff);
        assertFalse(signedExclusiveSwap.nonceBitmap(word).isSet(bit));
    }

    function test_revert_unauthorized_locker() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
                _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
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

    function test_revert_deadline_too_far_fuzz(uint256 currentTimestampInput) public {
        vm.warp(currentTimestampInput);
        uint32 currentTimestamp = uint32(currentTimestampInput);
        uint32 deadlineTooFar;
        unchecked {
            deadlineTooFar = currentTimestamp + 30 days + 1;
        }

        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
                _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
        SignedSwapMeta meta = createSignedSwapMeta(address(0), deadlineTooFar, uint32(uint256(1 << 32) / 500), 100);

        vm.expectRevert(ISignedExclusiveSwap.DeadlineTooFar.selector);
        harness.swapSigned(
            address(signedExclusiveSwap), poolKey, params, meta, MIN_BALANCE_UPDATE, hex"", address(this), address(this)
        );
    }

    function test_revert_direct_core_initialize_pool() public {
        PoolKey memory poolKey = signedExclusiveSwapPoolKey(20_000);

        vm.expectRevert(ISignedExclusiveSwap.PoolInitializationDisabled.selector);
        core.initializePool(poolKey, 0);
    }

    function test_initialize_pool_emits_pool_state_updated() public {
        PoolKey memory poolKey = signedExclusiveSwapPoolKey(20_000);
        SignedExclusiveSwapPoolState expectedState = createSignedExclusiveSwapPoolState({
            _controller: controller, _lastUpdateTime: uint32(block.timestamp), _ownerFee: 1 << 63
        });

        vm.expectEmit(true, false, false, true, address(signedExclusiveSwap));
        emit ISignedExclusiveSwap.PoolStateUpdated(poolKey.toPoolId(), expectedState);

        vm.prank(admin);
        signedExclusiveSwap.initializePool(poolKey, 0, controller, 1 << 63);
        assertEq(
            SignedExclusiveSwapPoolState.unwrap(_poolState(poolKey)), SignedExclusiveSwapPoolState.unwrap(expectedState)
        );
    }

    function test_owner_initializes_pool_with_specified_controller() public {
        uint256 nextControllerPk = 0xC0FFEE;
        while (uint160(vm.addr(nextControllerPk)) >> 159 != 0) {
            unchecked {
                ++nextControllerPk;
            }
        }
        ControllerAddress nextController = ControllerAddress.wrap(vm.addr(nextControllerPk));

        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000, nextController);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
                _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
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
        MockSigner1271 contractController;
        for (uint256 i; i < 16; ++i) {
            contractController = new MockSigner1271(ControllerAddress.unwrap(controller));
            if (uint160(address(contractController)) >> 159 == 1) break;
        }
        assertTrue(uint160(address(contractController)) >> 159 == 1);

        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        vm.prank(admin);
        signedExclusiveSwap.setPoolController(poolKey, ControllerAddress.wrap(address(contractController)));

        SwapParameters params = createSwapParameters({
                _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
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
            }).withDefaultSqrtRatioLimit();
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
            }).withDefaultSqrtRatioLimit();
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
            }).withDefaultSqrtRatioLimit();
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

        SwapParameters params = createSwapParameters({
                _isToken1: true, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
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

    function test_revert_signature_expired() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
                _isToken1: true, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
        SignedSwapMeta meta =
            createSignedSwapMeta(address(0), uint32(block.timestamp - 1), uint32(uint256(1 << 32) / 500), 215);
        PoolBalanceUpdate minBalanceUpdate = createPoolBalanceUpdate(-40_000, 50_000);

        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, minBalanceUpdate);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ISignedExclusiveSwap.SignatureExpired.selector);
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

    function test_revert_invalid_signature() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
                _isToken1: true, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
        SignedSwapMeta meta =
            createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), uint32(uint256(1 << 32) / 500), 216);
        PoolBalanceUpdate minBalanceUpdateSigned = createPoolBalanceUpdate(-40_000, 50_000);

        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, minBalanceUpdateSigned);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.expectRevert(ISignedExclusiveSwap.InvalidSignature.selector);
        harness.swapSigned(
            address(signedExclusiveSwap),
            poolKey,
            params,
            meta,
            createPoolBalanceUpdate(-30_000, 50_000),
            signature,
            address(this),
            address(this)
        );
    }

    function test_broadcast_signed_swaps_emits_for_each_valid_signature() public {
        PoolKey memory firstPoolKey = createSignedExclusiveSwapPool(0, 20_000);
        PoolKey memory secondPoolKey = createSignedExclusiveSwapPool(0, 10_000);

        SignedSwapMeta firstMeta = createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), 0, 217);
        SignedSwapMeta secondMeta = createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), 1234, 218);
        PoolBalanceUpdate firstMinBalanceUpdate = createPoolBalanceUpdate(10, -20);
        PoolBalanceUpdate secondMinBalanceUpdate = createPoolBalanceUpdate(-30, 40);

        bytes32 firstDigest =
            signedExclusiveSwap.hashSignedSwapPayload(firstPoolKey.toPoolId(), firstMeta, firstMinBalanceUpdate);
        (uint8 firstV, bytes32 firstR, bytes32 firstS) = vm.sign(controllerPk, firstDigest);
        bytes memory firstSignature = abi.encodePacked(firstR, firstS, firstV);

        bytes32 secondDigest =
            signedExclusiveSwap.hashSignedSwapPayload(secondPoolKey.toPoolId(), secondMeta, secondMinBalanceUpdate);
        (uint8 secondV, bytes32 secondR, bytes32 secondS) = vm.sign(controllerPk, secondDigest);
        bytes memory secondSignature = abi.encodePacked(secondR, secondS, secondV);

        ISignedExclusiveSwap.SignedSwapBroadcast[] memory signedSwaps =
            new ISignedExclusiveSwap.SignedSwapBroadcast[](2);
        signedSwaps[0] = ISignedExclusiveSwap.SignedSwapBroadcast({
            poolId: firstPoolKey.toPoolId(),
            meta: firstMeta,
            minBalanceUpdate: firstMinBalanceUpdate,
            signature: firstSignature
        });
        signedSwaps[1] = ISignedExclusiveSwap.SignedSwapBroadcast({
            poolId: secondPoolKey.toPoolId(),
            meta: secondMeta,
            minBalanceUpdate: secondMinBalanceUpdate,
            signature: secondSignature
        });

        vm.expectEmit(true, false, false, true, address(signedExclusiveSwap));
        emit ISignedExclusiveSwap.SignedSwapBroadcasted(
            firstPoolKey.toPoolId(), firstMeta, firstMinBalanceUpdate, firstSignature
        );
        vm.expectEmit(true, false, false, true, address(signedExclusiveSwap));
        emit ISignedExclusiveSwap.SignedSwapBroadcasted(
            secondPoolKey.toPoolId(), secondMeta, secondMinBalanceUpdate, secondSignature
        );

        signedExclusiveSwap.broadcastSignedSwaps(signedSwaps);
    }

    function test_revert_broadcast_signed_swaps_invalid_signature() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);

        SignedSwapMeta meta = createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), 0, 219);
        PoolBalanceUpdate minBalanceUpdateSigned = createPoolBalanceUpdate(50, -60);
        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, minBalanceUpdateSigned);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        ISignedExclusiveSwap.SignedSwapBroadcast[] memory signedSwaps =
            new ISignedExclusiveSwap.SignedSwapBroadcast[](1);
        signedSwaps[0] = ISignedExclusiveSwap.SignedSwapBroadcast({
            poolId: poolKey.toPoolId(),
            meta: meta,
            minBalanceUpdate: createPoolBalanceUpdate(51, -60),
            signature: signature
        });

        vm.expectRevert(ISignedExclusiveSwap.InvalidSignature.selector);
        signedExclusiveSwap.broadcastSignedSwaps(signedSwaps);
    }

    function test_revert_broadcast_signed_swaps_expired_signature() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);

        SignedSwapMeta meta = createSignedSwapMeta(address(0), uint32(block.timestamp - 1), 0, 220);
        PoolBalanceUpdate minBalanceUpdate = createPoolBalanceUpdate(50, -60);
        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, minBalanceUpdate);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        ISignedExclusiveSwap.SignedSwapBroadcast[] memory signedSwaps =
            new ISignedExclusiveSwap.SignedSwapBroadcast[](1);
        signedSwaps[0] = ISignedExclusiveSwap.SignedSwapBroadcast({
            poolId: poolKey.toPoolId(), meta: meta, minBalanceUpdate: minBalanceUpdate, signature: signature
        });

        vm.expectRevert(ISignedExclusiveSwap.SignatureExpired.selector);
        signedExclusiveSwap.broadcastSignedSwaps(signedSwaps);
    }

    function test_revert_broadcast_signed_swaps_deadline_too_far() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);

        SignedSwapMeta meta = createSignedSwapMeta(address(0), uint32(block.timestamp + 30 days + 1), 0, 221);
        PoolBalanceUpdate minBalanceUpdate = createPoolBalanceUpdate(50, -60);
        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, minBalanceUpdate);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        ISignedExclusiveSwap.SignedSwapBroadcast[] memory signedSwaps =
            new ISignedExclusiveSwap.SignedSwapBroadcast[](1);
        signedSwaps[0] = ISignedExclusiveSwap.SignedSwapBroadcast({
            poolId: poolKey.toPoolId(), meta: meta, minBalanceUpdate: minBalanceUpdate, signature: signature
        });

        vm.expectRevert(ISignedExclusiveSwap.DeadlineTooFar.selector);
        signedExclusiveSwap.broadcastSignedSwaps(signedSwaps);
    }

    function test_revert_broadcast_signed_swaps_nonce_already_used() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
                _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
        SignedSwapMeta meta = createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), 0, 222);
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

        ISignedExclusiveSwap.SignedSwapBroadcast[] memory signedSwaps =
            new ISignedExclusiveSwap.SignedSwapBroadcast[](1);
        signedSwaps[0] = ISignedExclusiveSwap.SignedSwapBroadcast({
            poolId: poolKey.toPoolId(), meta: meta, minBalanceUpdate: MIN_BALANCE_UPDATE, signature: signature
        });

        vm.expectRevert(ISignedExclusiveSwap.NonceAlreadyUsed.selector);
        signedExclusiveSwap.broadcastSignedSwaps(signedSwaps);
    }

    function test_domain_separator_tracks_chain_id_changes() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        uint256 originalChainId = block.chainid;
        vm.chainId(originalChainId + 1);

        SwapParameters params = createSwapParameters({
                _isToken1: false, _amount: 50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
        SignedSwapMeta meta = createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), 0, 223);
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

        vm.chainId(originalChainId);
    }

    function test_revert_initialize_pool_not_owner() public {
        PoolKey memory poolKey = signedExclusiveSwapPoolKey(20_000);

        vm.expectRevert(Ownable.Unauthorized.selector);
        signedExclusiveSwap.initializePool(poolKey, 0, controller, 0);
    }

    function test_revert_initialize_pool_wrong_extension() public {
        PoolKey memory poolKey = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createConcentratedPoolConfig({_fee: 0, _tickSpacing: 20_000, _extension: address(0)})
        });

        vm.prank(admin);
        vm.expectRevert(ISignedExclusiveSwap.PoolExtensionMustBeSelf.selector);
        signedExclusiveSwap.initializePool(poolKey, 0, controller, 0);
    }

    function test_revert_initialize_pool_zero_controller() public {
        PoolKey memory poolKey = signedExclusiveSwapPoolKey(20_000);

        vm.prank(admin);
        vm.expectRevert(ISignedExclusiveSwap.InvalidController.selector);
        signedExclusiveSwap.initializePool(poolKey, 0, ControllerAddress.wrap(address(0)), 0);
    }

    function test_revert_initialize_pool_contract_with_eoa_controller_encoding() public {
        MockSigner1271 codeSource = new MockSigner1271(ControllerAddress.unwrap(controller));
        address lowBitContract = address(0x123456);
        vm.etch(lowBitContract, address(codeSource).code);

        PoolKey memory poolKey = signedExclusiveSwapPoolKey(20_000);

        vm.prank(admin);
        vm.expectRevert(ISignedExclusiveSwap.InvalidController.selector);
        signedExclusiveSwap.initializePool(poolKey, 0, ControllerAddress.wrap(lowBitContract), 0);
    }

    function test_revert_initialize_pool_eoa_with_contract_controller_encoding() public {
        address highBitNoCode = address(uint160(1) << 159);
        assertEq(highBitNoCode.code.length, 0);

        PoolKey memory poolKey = signedExclusiveSwapPoolKey(20_000);

        vm.prank(admin);
        vm.expectRevert(ISignedExclusiveSwap.InvalidController.selector);
        signedExclusiveSwap.initializePool(poolKey, 0, ControllerAddress.wrap(highBitNoCode), 0);
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
        signedExclusiveSwap.setPoolController(poolKey, ControllerAddress.wrap(address(0x1234)));
    }

    function test_revert_set_pool_controller_invalid_controller() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);

        vm.prank(admin);
        vm.expectRevert(ISignedExclusiveSwap.InvalidController.selector);
        signedExclusiveSwap.setPoolController(poolKey, ControllerAddress.wrap(address(0)));
    }

    function test_exact_out_token0_output_charges_meta_fee_on_token1_input() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
                _isToken1: false, _amount: -50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
        uint32 fee = uint32(uint256(1 << 32) / 100); // 1%
        SignedSwapMeta meta = createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), fee, 224);
        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, MIN_BALANCE_UPDATE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

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

        assertLt(balanceUpdate.delta0(), 0);
        assertGt(balanceUpdate.delta1(), 0);

        PoolId poolId = poolKey.toPoolId();
        (, uint128 saved1) =
            core.savedBalances(address(signedExclusiveSwap), poolKey.token0, poolKey.token1, PoolId.unwrap(poolId));
        assertGt(saved1, 0);
    }

    function test_exact_out_token1_output_charges_meta_fee_on_token0_input() public {
        PoolKey memory poolKey = createSignedExclusiveSwapPool(0, 20_000);
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(harness), type(uint256).max);
        token1.approve(address(harness), type(uint256).max);

        SwapParameters params = createSwapParameters({
                _isToken1: true, _amount: -50_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }).withDefaultSqrtRatioLimit();
        uint32 fee = uint32(uint256(1 << 32) / 100); // 1%
        SignedSwapMeta meta = createSignedSwapMeta(address(0), uint32(block.timestamp + 1 hours), fee, 225);
        bytes32 digest = signedExclusiveSwap.hashSignedSwapPayload(poolKey.toPoolId(), meta, MIN_BALANCE_UPDATE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(controllerPk, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

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

        assertGt(balanceUpdate.delta0(), 0);
        assertLt(balanceUpdate.delta1(), 0);

        PoolId poolId = poolKey.toPoolId();
        (uint128 saved0,) =
            core.savedBalances(address(signedExclusiveSwap), poolKey.token0, poolKey.token1, PoolId.unwrap(poolId));
        assertGt(saved0, 0);
    }
}
