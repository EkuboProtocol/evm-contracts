// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC6909} from "solady/tokens/ERC6909.sol";
import {StableswapLPPositions} from "../src/StableswapLPPositions.sol";
import {IStableswapLPPositions} from "../src/interfaces/IStableswapLPPositions.sol";
import {StableswapLPTokenWrapper} from "../src/wrappers/StableswapLPTokenWrapper.sol";
import {StableswapLPTokenWrapperFactory} from "../src/wrappers/StableswapLPTokenWrapperFactory.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolConfig, createStableswapPoolConfig} from "../src/types/poolConfig.sol";
import {TestToken} from "./TestToken.sol";
import {FullTest} from "./FullTest.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";

contract StableswapLPTokenWrapperTest is FullTest {
    using CoreLib for *;

    StableswapLPPositions lpPositions;
    StableswapLPTokenWrapperFactory factory;
    StableswapLPTokenWrapper wrapper;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant DEADLINE = type(uint256).max;
    PoolKey poolKey;
    uint256 tokenId;

    function setUp() public override {
        super.setUp();

        lpPositions = new StableswapLPPositions(core, owner, 0);
        factory = new StableswapLPTokenWrapperFactory(IStableswapLPPositions(address(lpPositions)));

        // Create stableswap pool
        PoolConfig config = createStableswapPoolConfig(1 << 63, 10, 0, address(0));
        poolKey = PoolKey({token0: address(token0), token1: address(token1), config: config});
        core.initializePool(poolKey, 0);
        tokenId = uint256(PoolId.unwrap(poolKey.toPoolId()));

        // Deploy wrapper
        address wrapperAddr = factory.getOrCreateWrapper(tokenId);
        wrapper = StableswapLPTokenWrapper(wrapperAddr);

        // Fund users
        token0.transfer(alice, 1_000_000 ether);
        token1.transfer(alice, 1_000_000 ether);
        token0.transfer(bob, 1_000_000 ether);
        token1.transfer(bob, 1_000_000 ether);

        // Approve LP positions for deposits
        vm.prank(alice);
        token0.approve(address(lpPositions), type(uint256).max);
        vm.prank(alice);
        token1.approve(address(lpPositions), type(uint256).max);
        vm.prank(bob);
        token0.approve(address(lpPositions), type(uint256).max);
        vm.prank(bob);
        token1.approve(address(lpPositions), type(uint256).max);
    }

    function _depositAs(address user, uint128 amount) internal returns (uint256 lpTokens) {
        vm.prank(user);
        (lpTokens,,) = lpPositions.deposit(poolKey, amount, amount, 0, DEADLINE);
    }

    function _approveAndWrap(address user, uint256 amount) internal {
        vm.prank(user);
        ERC6909(address(lpPositions)).approve(address(wrapper), tokenId, amount);
        vm.prank(user);
        wrapper.wrap(amount);
    }

    function _unwrap(address user, uint256 amount) internal {
        vm.prank(user);
        wrapper.unwrap(amount);
    }

    // --- Factory Tests ---

    function test_factory_createsWrapper() public view {
        assertEq(factory.wrappers(tokenId), address(wrapper));
    }

    function test_factory_returnsSameWrapperOnSecondCall() public {
        address second = factory.getOrCreateWrapper(tokenId);
        assertEq(second, address(wrapper));
    }

    function test_factory_predictAddress() public view {
        address predicted = factory.predictWrapperAddress(tokenId);
        assertEq(predicted, address(wrapper));
    }

    function test_factory_differentPoolsDifferentWrappers() public {
        // Create a second pool
        TestToken tokenA = new TestToken(address(this));
        TestToken tokenB = new TestToken(address(this));
        (TestToken t0, TestToken t1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

        PoolConfig config = createStableswapPoolConfig(1 << 63, 10, 0, address(0));
        PoolKey memory poolKey2 = PoolKey({token0: address(t0), token1: address(t1), config: config});
        core.initializePool(poolKey2, 0);
        uint256 tokenId2 = uint256(PoolId.unwrap(poolKey2.toPoolId()));

        address wrapper2 = factory.getOrCreateWrapper(tokenId2);
        assertTrue(wrapper2 != address(wrapper));
    }

    // --- Wrapper Metadata Tests ---

    function test_wrapper_name() public view {
        assertEq(wrapper.name(), "Wrapped Ekubo Stableswap LP");
    }

    function test_wrapper_symbol() public view {
        assertEq(wrapper.symbol(), "wEKUBO-SLP");
    }

    function test_wrapper_decimals() public view {
        assertEq(wrapper.decimals(), 18);
    }

    // --- Wrap Tests ---

    function test_wrap_basic() public {
        uint256 lpTokens = _depositAs(alice, 100 ether);

        _approveAndWrap(alice, lpTokens);

        assertEq(wrapper.balanceOf(alice), lpTokens, "ERC20 balance mismatch");
        assertEq(
            ERC6909(address(lpPositions)).balanceOf(alice, tokenId), 0, "ERC6909 balance should be zero after wrap"
        );
        assertEq(
            ERC6909(address(lpPositions)).balanceOf(address(wrapper), tokenId),
            lpTokens,
            "Wrapper should hold ERC6909"
        );
    }

    function test_wrap_emitsEvent() public {
        uint256 lpTokens = _depositAs(alice, 100 ether);

        vm.prank(alice);
        ERC6909(address(lpPositions)).approve(address(wrapper), tokenId, lpTokens);

        vm.expectEmit(address(wrapper));
        emit StableswapLPTokenWrapper.Wrapped(alice, lpTokens);

        vm.prank(alice);
        wrapper.wrap(lpTokens);
    }

    function test_wrap_partialAmount() public {
        uint256 lpTokens = _depositAs(alice, 100 ether);
        uint256 half = lpTokens / 2;

        _approveAndWrap(alice, half);

        assertEq(wrapper.balanceOf(alice), half);
        assertEq(ERC6909(address(lpPositions)).balanceOf(alice, tokenId), lpTokens - half);
    }

    function test_wrap_revertsWithoutApproval() public {
        uint256 lpTokens = _depositAs(alice, 100 ether);

        vm.prank(alice);
        vm.expectRevert();
        wrapper.wrap(lpTokens);
    }

    // --- Unwrap Tests ---

    function test_unwrap_basic() public {
        uint256 lpTokens = _depositAs(alice, 100 ether);
        _approveAndWrap(alice, lpTokens);

        _unwrap(alice, lpTokens);

        assertEq(wrapper.balanceOf(alice), 0, "ERC20 should be zero after unwrap");
        assertEq(
            ERC6909(address(lpPositions)).balanceOf(alice, tokenId), lpTokens, "ERC6909 should be restored after unwrap"
        );
        assertEq(
            ERC6909(address(lpPositions)).balanceOf(address(wrapper), tokenId),
            0,
            "Wrapper should hold zero ERC6909"
        );
    }

    function test_unwrap_emitsEvent() public {
        uint256 lpTokens = _depositAs(alice, 100 ether);
        _approveAndWrap(alice, lpTokens);

        vm.expectEmit(address(wrapper));
        emit StableswapLPTokenWrapper.Unwrapped(alice, lpTokens);

        vm.prank(alice);
        wrapper.unwrap(lpTokens);
    }

    function test_unwrap_partialAmount() public {
        uint256 lpTokens = _depositAs(alice, 100 ether);
        _approveAndWrap(alice, lpTokens);

        uint256 half = lpTokens / 2;
        _unwrap(alice, half);

        assertEq(wrapper.balanceOf(alice), lpTokens - half);
        assertEq(ERC6909(address(lpPositions)).balanceOf(alice, tokenId), half);
    }

    function test_unwrap_revertsIfInsufficientBalance() public {
        uint256 lpTokens = _depositAs(alice, 100 ether);
        _approveAndWrap(alice, lpTokens);

        vm.prank(alice);
        vm.expectRevert();
        wrapper.unwrap(lpTokens + 1);
    }

    // --- Round-trip Tests ---

    function test_wrapUnwrap_roundTrip() public {
        uint256 lpTokens = _depositAs(alice, 100 ether);
        uint256 erc6909Before = ERC6909(address(lpPositions)).balanceOf(alice, tokenId);

        _approveAndWrap(alice, lpTokens);
        _unwrap(alice, lpTokens);

        uint256 erc6909After = ERC6909(address(lpPositions)).balanceOf(alice, tokenId);
        assertEq(erc6909After, erc6909Before, "Round-trip should preserve ERC6909 balance");
    }

    function test_multipleUsers_wrapUnwrap() public {
        uint256 aliceLp = _depositAs(alice, 100 ether);
        uint256 bobLp = _depositAs(bob, 50 ether);

        _approveAndWrap(alice, aliceLp);
        _approveAndWrap(bob, bobLp);

        assertEq(wrapper.balanceOf(alice), aliceLp);
        assertEq(wrapper.balanceOf(bob), bobLp);
        assertEq(wrapper.totalSupply(), aliceLp + bobLp);

        _unwrap(alice, aliceLp);
        _unwrap(bob, bobLp);

        assertEq(wrapper.totalSupply(), 0);
        assertEq(ERC6909(address(lpPositions)).balanceOf(address(wrapper), tokenId), 0);
    }

    // --- ERC20 Transfer Tests ---

    function test_erc20Transfer_works() public {
        uint256 lpTokens = _depositAs(alice, 100 ether);
        _approveAndWrap(alice, lpTokens);

        vm.prank(alice);
        wrapper.transfer(bob, lpTokens);

        assertEq(wrapper.balanceOf(alice), 0);
        assertEq(wrapper.balanceOf(bob), lpTokens);
    }

    function test_erc20Transfer_thenUnwrap() public {
        uint256 lpTokens = _depositAs(alice, 100 ether);
        _approveAndWrap(alice, lpTokens);

        // Alice transfers ERC20 to Bob
        vm.prank(alice);
        wrapper.transfer(bob, lpTokens);

        // Bob unwraps to get ERC6909
        _unwrap(bob, lpTokens);

        assertEq(ERC6909(address(lpPositions)).balanceOf(bob, tokenId), lpTokens);
        assertEq(ERC6909(address(lpPositions)).balanceOf(alice, tokenId), 0);
    }

    // --- Invariant: totalSupply == ERC6909 balance ---

    function test_invariant_totalSupplyMatchesERC6909Balance() public {
        uint256 aliceLp = _depositAs(alice, 100 ether);
        uint256 bobLp = _depositAs(bob, 50 ether);

        // Wrap alice
        _approveAndWrap(alice, aliceLp);
        _assertTotalSupplyInvariant();

        // Wrap bob
        _approveAndWrap(bob, bobLp);
        _assertTotalSupplyInvariant();

        // Unwrap alice
        _unwrap(alice, aliceLp);
        _assertTotalSupplyInvariant();

        // Unwrap bob
        _unwrap(bob, bobLp);
        _assertTotalSupplyInvariant();
    }

    function test_invariant_totalSupplyAfterERC20Transfers() public {
        uint256 lpTokens = _depositAs(alice, 100 ether);
        _approveAndWrap(alice, lpTokens);

        // ERC20 transfer should not affect the invariant
        vm.prank(alice);
        wrapper.transfer(bob, lpTokens / 2);
        _assertTotalSupplyInvariant();

        // Partial unwrap by bob
        _unwrap(bob, lpTokens / 4);
        _assertTotalSupplyInvariant();
    }

    function testFuzz_invariant_wrapUnwrap(uint128 depositAmount, uint128 wrapFraction) public {
        depositAmount = uint128(bound(depositAmount, 1001, 100 ether));
        uint256 lpTokens = _depositAs(alice, depositAmount);
        uint256 wrapAmount = bound(wrapFraction, 1, lpTokens);

        _approveAndWrap(alice, wrapAmount);
        _assertTotalSupplyInvariant();

        _unwrap(alice, wrapAmount);
        _assertTotalSupplyInvariant();
    }

    function _assertTotalSupplyInvariant() internal view {
        uint256 erc20Supply = wrapper.totalSupply();
        uint256 erc6909Balance = ERC6909(address(lpPositions)).balanceOf(address(wrapper), tokenId);
        assertEq(erc20Supply, erc6909Balance, "Invariant violated: totalSupply != ERC6909 balance");
    }

    // --- Access Control Tests ---

}
