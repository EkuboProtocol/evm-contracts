// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {FullTest} from "./FullTest.sol";
import {TokenWrapper} from "../src/TokenWrapper.sol";
import {TokenWrapperFactory} from "../src/TokenWrapperFactory.sol";
import {toDate, toQuarter} from "../src/libraries/TimeDescriptor.sol";
import {TestToken} from "./TestToken.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";

contract TokenWrapperPeriphery is BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function wrap(TokenWrapper wrapper, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, msg.sender, int256(uint256(amount))));
    }

    function wrap(TokenWrapper wrapper, address recipient, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, recipient, int256(uint256(amount))));
    }

    function unwrap(TokenWrapper wrapper, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, msg.sender, -int256(uint256(amount))));
    }

    function unwrap(TokenWrapper wrapper, address recipient, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, recipient, -int256(uint256(amount))));
    }

    function migrate(TokenWrapper source, TokenWrapper destination, address recipient, uint128 amount) external {
        lock(abi.encode(source, destination, msg.sender, recipient, amount));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        if (data.length == 160) {
            (
                TokenWrapper source,
                TokenWrapper destination,
                address migrationPayer,
                address migrationRecipient,
                uint128 migrationAmount
            ) = abi.decode(data, (TokenWrapper, TokenWrapper, address, address, uint128));
            ACCOUNTANT.forward(address(source), abi.encode(-int256(uint256(migrationAmount)), destination));
            ACCOUNTANT.withdraw(address(destination), migrationRecipient, migrationAmount);
            ACCOUNTANT.payFrom(migrationPayer, address(source), migrationAmount);
            return bytes("");
        }
        (TokenWrapper wrapper, address payer, address recipient, int256 amount) =
            abi.decode(data, (TokenWrapper, address, address, int256));

        if (amount >= 0) {
            // this creates the deltas
            ACCOUNTANT.forward(address(wrapper), abi.encode(amount));
            // now withdraw to the recipient
            if (uint128(uint256(amount)) > 0) {
                ACCOUNTANT.withdraw(address(wrapper), recipient, uint128(uint256(amount)));
            }
            // and pay the wrapped token from the payer
            if (uint256(amount) != 0) {
                if (address(wrapper.UNDERLYING_TOKEN()) == NATIVE_TOKEN_ADDRESS) {
                    SafeTransferLib.safeTransferETH(address(ACCOUNTANT), uint256(amount));
                } else {
                    ACCOUNTANT.payFrom(payer, address(wrapper.UNDERLYING_TOKEN()), uint256(amount));
                }
            }
        } else {
            // this creates the deltas
            ACCOUNTANT.forward(address(wrapper), abi.encode(amount));
            // now withdraw to the recipient
            if (uint128(uint256(-amount)) > 0) {
                ACCOUNTANT.withdraw(address(wrapper.UNDERLYING_TOKEN()), recipient, uint128(uint256(-amount)));
            }
            // and pay the wrapped token from the payer
            if (uint256(-amount) != 0) {
                if (address(wrapper) == NATIVE_TOKEN_ADDRESS) {
                    SafeTransferLib.safeTransferETH(address(ACCOUNTANT), uint256(-amount));
                } else {
                    ACCOUNTANT.payFrom(payer, address(wrapper), uint256(-amount));
                }
            }
        }
    }
}

contract TokenWrapperTest is FullTest {
    TokenWrapperFactory factory;
    TokenWrapperPeriphery periphery;
    TestToken underlying;

    function setUp() public override {
        FullTest.setUp();
        underlying = new TestToken(address(this));
        factory = new TokenWrapperFactory(core);
        periphery = new TokenWrapperPeriphery(core);
    }

    function coolAllContracts() internal virtual override {
        FullTest.coolAllContracts();
        vm.cool(address(underlying));
        vm.cool(address(factory));
        vm.cool(address(periphery));
        vm.cool(address(periphery));
    }

    /// forge-config: default.isolate = true
    function testDeployWrapperGas() public {
        factory.deployWrapper(IERC20(address(underlying)), 1756140269);
        vm.snapshotGasLastCall("deployWrapper");
    }

    function testTokenInfo(uint256 time, uint256 unlockTime) public {
        vm.warp(time);

        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), unlockTime);

        assertEq(wrapper.symbol(), string.concat("gTT-", toQuarter(unlockTime)));
        assertEq(wrapper.name(), string.concat("TestToken ", toDate(unlockTime)));
        assertEq(wrapper.UNLOCK_TIME(), unlockTime);
        assertEq(address(wrapper.UNDERLYING_TOKEN()), address(underlying));
    }

    function testWrap(uint256 time, uint64 unlockTime, uint128 wrapAmount) public {
        vm.warp(time);
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), unlockTime);
        wrapAmount = uint128(bound(wrapAmount, 0, uint128(type(int128).max)));

        underlying.approve(address(periphery), wrapAmount);
        assertEq(wrapper.totalSupply(), 0);
        periphery.wrap(wrapper, wrapAmount);
        assertEq(wrapper.totalSupply(), wrapAmount);

        assertEq(wrapper.balanceOf(address(this)), wrapAmount, "Didn't mint wrapper");
        assertEq(underlying.balanceOf(address(core)), wrapAmount, "Didn't transfer underlying");
    }

    /// forge-config: default.isolate = true
    function testWrapGas() public {
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), 0);
        underlying.approve(address(periphery), 1);
        coolAllContracts();
        vm.cool(address(wrapper));
        periphery.wrap(wrapper, 1);
        vm.snapshotGasLastCall("wrap");
    }

    function testUnwrapTo(address recipient, uint128 wrapAmount, uint128 unwrapAmount, uint256 time) public {
        vm.assume(recipient != address(core));
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), 1755616480);
        wrapAmount = uint128(bound(wrapAmount, 1, uint128(type(int128).max)));
        unwrapAmount = uint128(bound(unwrapAmount, 1, wrapAmount));

        underlying.approve(address(periphery), wrapAmount);

        vm.expectEmit(address(wrapper));
        emit IERC20.Transfer(address(core), address(this), wrapAmount);

        periphery.wrap(wrapper, wrapAmount);
        uint256 oldBalance = underlying.balanceOf(recipient);

        wrapper.approve(address(periphery), wrapAmount);

        vm.warp(time);
        if (time < wrapper.UNLOCK_TIME()) {
            assertEq(wrapper.totalSupply(), wrapAmount);
            vm.expectRevert(TokenWrapper.TooEarly.selector);
            periphery.unwrap(wrapper, recipient, unwrapAmount);
            assertEq(wrapper.totalSupply(), wrapAmount);
        } else {
            assertEq(wrapper.totalSupply(), wrapAmount);

            vm.expectEmit(address(wrapper));
            emit IERC20.Transfer(address(this), address(core), unwrapAmount);

            periphery.unwrap(wrapper, recipient, unwrapAmount);
            assertEq(wrapper.balanceOf(address(this)), wrapAmount - unwrapAmount, "Didn't burn wrapper");
            assertEq(underlying.balanceOf(recipient), oldBalance + unwrapAmount, "Didn't transfer underlying");
            assertEq(wrapper.totalSupply(), wrapAmount - unwrapAmount);
        }
    }

    function testMigrate(uint96 rawAmount, uint96 rawPartial, uint64 rawTime) public {
        uint128 amount = uint128(bound(rawAmount, 1, type(uint96).max));
        uint128 migrateAmount = uint128(bound(rawPartial, 1, amount));
        uint256 unlock = uint256(rawTime) + 100;
        TokenWrapper source = factory.deployWrapper(IERC20(address(underlying)), unlock);
        TokenWrapper destination = factory.deployWrapper(IERC20(address(underlying)), unlock + 100);
        underlying.approve(address(periphery), amount);
        periphery.wrap(source, amount);
        source.approve(address(periphery), amount);
        vm.warp(unlock - 1);
        periphery.migrate(source, destination, address(0x1234), migrateAmount);
        assertEq(source.totalSupply(), amount - migrateAmount);
        assertEq(source.balanceOf(address(this)), amount - migrateAmount);
        assertEq(destination.totalSupply(), migrateAmount);
        assertEq(destination.balanceOf(address(0x1234)), migrateAmount);
        assertEq(underlying.balanceOf(address(core)), amount);
        vm.prank(address(0x1234));
        destination.approve(address(periphery), migrateAmount);
        vm.warp(unlock);
        vm.prank(address(0x1234));
        vm.expectRevert(TokenWrapper.TooEarly.selector);
        periphery.unwrap(destination, migrateAmount);
        vm.warp(unlock + 100);
        vm.prank(address(0x1234));
        periphery.unwrap(destination, address(this), migrateAmount);
        periphery.unwrap(source, amount - migrateAmount);
        assertEq(underlying.balanceOf(address(core)), 0);
    }

    function testMigrationRejectsInvalidDestinations() public {
        TokenWrapper source = factory.deployWrapper(IERC20(address(underlying)), 100);
        TokenWrapper earlier = factory.deployWrapper(IERC20(address(underlying)), 99);
        TokenWrapper different = factory.deployWrapper(IERC20(address(token0)), 200);
        TokenWrapperFactory otherFactory = new TokenWrapperFactory(core);
        TokenWrapper foreign = otherFactory.deployWrapper(IERC20(address(underlying)), 200);
        TokenWrapper[5] memory invalid = [source, earlier, different, foreign, TokenWrapper(address(0xdead))];
        for (uint256 i; i < invalid.length; i++) {
            vm.expectRevert(TokenWrapperFactory.InvalidMigration.selector);
            periphery.migrate(source, invalid[i], address(this), 1);
        }
        assertEq(source.totalSupply(), 0);
    }

    function testMigrationUnpaidInputRollsBack() public {
        TokenWrapper source = factory.deployWrapper(IERC20(address(underlying)), 100);
        TokenWrapper destination = factory.deployWrapper(IERC20(address(underlying)), 200);
        underlying.approve(address(periphery), 10);
        periphery.wrap(source, 10);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        periphery.migrate(source, destination, address(this), 10);
        assertEq(source.totalSupply(), 10);
        assertEq(source.balanceOf(address(this)), 10);
        assertEq(destination.totalSupply(), 0);
        assertEq(destination.balanceOf(address(this)), 0);
        assertEq(underlying.balanceOf(address(core)), 10);
    }

    /// forge-config: default.isolate = true
    function testMigrateGas() public {
        TokenWrapper source = factory.deployWrapper(IERC20(address(underlying)), 100);
        TokenWrapper destination = factory.deployWrapper(IERC20(address(underlying)), 200);
        underlying.approve(address(periphery), 10);
        periphery.wrap(source, 10);
        source.approve(address(periphery), 10);
        coolAllContracts();
        vm.cool(address(source));
        vm.cool(address(destination));
        periphery.migrate(source, destination, address(this), 5);
        vm.snapshotGasLastCall("migrate");
    }

    /// forge-config: default.isolate = true
    function testUnwrapGas() public {
        TokenWrapper wrapper = factory.deployWrapper(IERC20(address(underlying)), 0);

        underlying.approve(address(periphery), 1);
        periphery.wrap(wrapper, 1);
        wrapper.approve(address(periphery), 1);
        assertEq(wrapper.allowance(address(this), address(periphery)), 1);

        coolAllContracts();
        vm.cool(address(wrapper));

        periphery.unwrap(wrapper, 1);
        vm.snapshotGasLastCall("unwrap");
    }
}
