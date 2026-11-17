// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Core} from "../src/Core.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {TokenWrapper} from "../src/TokenWrapper.sol";
import {TokenWrapperFactory} from "../src/TokenWrapperFactory.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {BaseForwardee} from "../src/base/BaseForwardee.sol";
import {Locker} from "../src/types/locker.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {TestToken} from "./TestToken.sol";
import {TokenWrapperPeriphery} from "./TokenWrapper.t.sol";

contract UnsettledWrapperLocker is BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function forwardOnly(address target, bytes memory payload) external {
        lock(abi.encode(target, payload));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (address target, bytes memory payload) = abi.decode(data, (address, bytes));
        ACCOUNTANT.forward(target, payload);
        return bytes("");
    }
}

contract ReentrantWrapperUnderlying is TestToken {
    TokenWrapperPeriphery private periphery;
    TokenWrapper private ownWrapper;
    TokenWrapper private source;
    TokenWrapper private destination;
    bool public rejectedUnrelatedMigration;

    constructor(address recipient) TestToken(recipient) {}

    function configure(TokenWrapperPeriphery p, TokenWrapper own, TokenWrapper s, TokenWrapper d) external {
        periphery = p;
        ownWrapper = own;
        source = s;
        destination = d;
        s.approve(address(p), 1);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (address(periphery) != address(0)) {
            TokenWrapperPeriphery p = periphery;
            periphery = TokenWrapperPeriphery(address(0));
            try p.migrate(ownWrapper, destination, address(this), 1) {
                revert("unrelated asset migration succeeded");
            } catch (bytes memory reason) {
                require(bytes4(reason) == TokenWrapperFactory.InvalidMigration.selector, "wrong failure");
                rejectedUnrelatedMigration = true;
            }
            // A legitimate nested lock still works during the untrusted token's payment callback.
            p.migrate(source, destination, address(this), 1);
        }
        return super.transferFrom(from, to, amount);
    }
}

contract TokenWrapperMigrationTest is Test {
    Core core;
    TokenWrapperFactory factory;
    TokenWrapperPeriphery periphery;
    UnsettledWrapperLocker raw;
    TestToken underlying;
    TokenWrapper source;
    TokenWrapper destination;

    function setUp() public {
        vm.warp(1);
        core = new Core();
        factory = new TokenWrapperFactory(core);
        periphery = new TokenWrapperPeriphery(core);
        raw = new UnsettledWrapperLocker(core);
        underlying = new TestToken(address(this));
        source = factory.deployWrapper(IERC20(address(underlying)), 100);
        destination = factory.deployWrapper(IERC20(address(underlying)), 200);
        underlying.approve(address(periphery), type(uint256).max);
        source.approve(address(periphery), type(uint256).max);
        destination.approve(address(periphery), type(uint256).max);
    }

    function testCannotEnterSingletonDirectlyOrSpoofWrapper() public {
        periphery.wrap(source, 10);
        vm.expectRevert(TokenWrapperFactory.UnknownWrapper.selector);
        raw.forwardOnly(address(factory), abi.encode(int256(-10), destination));
        vm.expectRevert(BaseForwardee.BaseForwardeeAccountantOnly.selector);
        destination.forwarded_2374103877(Locker.wrap(bytes32(uint256(uint160(address(factory))))));
        assertEq(source.totalSupply(), 10);
        assertEq(destination.totalSupply(), 0);
    }

    function testUnsettledMigrationRevertsAtomically() public {
        periphery.wrap(source, 10);
        vm.expectRevert();
        raw.forwardOnly(address(source), abi.encode(int256(-10), destination));
        assertEq(source.totalSupply(), 10);
        assertEq(destination.totalSupply(), 0);
        assertEq(source.balanceOf(address(this)), 10);
    }

    function testMalformedAndNonnegativeMigration() public {
        vm.expectRevert(TokenWrapper.InvalidForwardDataLength.selector);
        raw.forwardOnly(address(source), bytes(""));
        vm.expectRevert(TokenWrapper.InvalidForwardDataLength.selector);
        raw.forwardOnly(address(source), abi.encode(int256(1), destination, uint256(0)));
        vm.expectRevert(TokenWrapperFactory.InvalidMigration.selector);
        raw.forwardOnly(address(source), abi.encode(int256(0), destination));
        vm.expectRevert(TokenWrapperFactory.InvalidMigration.selector);
        raw.forwardOnly(address(source), abi.encode(int256(1), destination));
    }

    function testMigrationAmountBoundaryAndChain() public {
        uint128 maxAmount = uint128(type(int128).max);
        periphery.wrap(source, maxAmount);
        periphery.migrate(source, destination, address(this), maxAmount);
        TokenWrapper last = factory.deployWrapper(IERC20(address(underlying)), 300);
        periphery.migrate(destination, last, address(this), maxAmount);
        assertEq(source.totalSupply(), 0);
        assertEq(destination.totalSupply(), 0);
        assertEq(last.totalSupply(), maxAmount);
        vm.warp(300);
        last.approve(address(periphery), maxAmount);
        periphery.unwrap(last, maxAmount);
        assertEq(underlying.balanceOf(address(core)), 0);
    }

    function testFirstRejectedMigrationAmount() public {
        uint128 amount = uint128(type(int128).max) + 1;
        periphery.wrap(source, amount);
        vm.expectRevert(SafeCastLib.Overflow.selector);
        periphery.migrate(source, destination, address(this), amount);
        assertEq(source.totalSupply(), amount);
        assertEq(destination.totalSupply(), 0);
    }

    function testDestinationBackingOverflowRollsBack() public {
        uint128 chunk = uint128(type(int128).max);
        periphery.wrap(destination, chunk);
        periphery.wrap(destination, chunk);
        periphery.wrap(destination, 1);
        periphery.wrap(source, 1);
        vm.expectRevert(ICore.SavedBalanceOverflow.selector);
        periphery.migrate(source, destination, address(this), 1);
        assertEq(destination.totalSupply(), type(uint128).max);
        assertEq(source.totalSupply(), 1);
    }

    function testCallbackCannotCrossAssetsAndCanNestMigration() public {
        ReentrantWrapperUnderlying malicious = new ReentrantWrapperUnderlying(address(this));
        TokenWrapper maliciousWrapper = factory.deployWrapper(IERC20(address(malicious)), 100);
        periphery.wrap(source, 10);
        source.transfer(address(malicious), 1);
        malicious.configure(periphery, maliciousWrapper, source, destination);
        malicious.approve(address(periphery), 5);
        periphery.wrap(maliciousWrapper, 5);
        assertTrue(malicious.rejectedUnrelatedMigration());
        assertEq(source.totalSupply(), 9);
        assertEq(destination.totalSupply(), 1);
        assertEq(destination.balanceOf(address(malicious)), 1);
        assertEq(source.balanceOf(address(this)), 9);
        assertEq(underlying.balanceOf(address(core)), 10);
        assertEq(maliciousWrapper.totalSupply(), 5);
        assertEq(malicious.balanceOf(address(core)), 5);
    }

    function testNativeMigration() public {
        TokenWrapper nativeSource = factory.deployWrapper(IERC20(address(0)), 100);
        TokenWrapper nativeDestination = factory.deployWrapper(IERC20(address(0)), 200);
        vm.deal(address(periphery), 1 ether);
        periphery.wrap(nativeSource, 1 ether);
        nativeSource.approve(address(periphery), 1 ether);
        periphery.migrate(nativeSource, nativeDestination, address(this), 1 ether);
        assertEq(address(core).balance, 1 ether);
        assertEq(nativeSource.totalSupply(), 0);
        assertEq(nativeDestination.totalSupply(), 1 ether);
        nativeDestination.approve(address(periphery), 1 ether);
        vm.warp(200);
        periphery.unwrap(nativeDestination, address(0x1234), 1 ether);
        assertEq(address(0x1234).balance, 1 ether);
        assertEq(address(core).balance, 0);
    }
}
