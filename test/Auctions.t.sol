// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseOrdersTest} from "./Orders.t.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {getNextLaunchTime, Auctions, auctionsCallPoints} from "../src/extensions/Auctions.sol";
import {isTimeValid} from "../src/math/time.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";

contract AuctionsForwarder is BaseLocker {
    using FlashAccountantLib for *;

    Auctions private immutable auctions;

    constructor(ICore core, Auctions _auctions) BaseLocker(core) {
        auctions = _auctions;
    }

    function launch(address token, address creator)
        external
        returns (address launchedToken, uint256 startTime, uint256 endTime)
    {
        return abi.decode(lock(abi.encode(token, creator)), (address, uint256, uint256));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (address token, address creator) = abi.decode(data, (address, address));
        return ACCOUNTANT.forward(address(auctions), abi.encode(token, creator));
    }
}

contract AuctionsTest is BaseOrdersTest {
    using CoreLib for *;

    Auctions auctions;
    AuctionsForwarder forwarder;

    function setUp() public virtual override {
        BaseOrdersTest.setUp();
        address deployAddress = address(uint160(auctionsCallPoints().toUint8()) << 152);
        uint256 orderDurationMagnitude = 4;
        uint128 tokenTotalSupply = 69_420_000e18;
        uint64 poolFee = uint64((uint256(1) << 64) / 100);
        uint32 tickSpacing = 1000;
        deployCodeTo(
            "Auctions.sol",
            abi.encode(core, twamm, orderDurationMagnitude, tokenTotalSupply, poolFee, tickSpacing),
            deployAddress
        );
        auctions = Auctions(deployAddress);
        forwarder = new AuctionsForwarder(core, auctions);
    }

    function test_get_next_launch_time_invariants(uint256 orderDurationMagnitude, uint256 time) public {
        uint32 orderDuration = uint32(16) ** uint32(bound(orderDurationMagnitude, 2, 6));
        uint32 minLeadTime = orderDuration / 2;

        time = bound(time, 0, type(uint64).max - type(uint32).max);

        vm.warp(time);

        (uint64 startTime, uint64 endTime) = getNextLaunchTime(orderDuration, minLeadTime);

        assertNotEq(startTime, 0);
        assertNotEq(endTime, 0);
        assertGt(endTime, startTime);

        assertGe(startTime, time + minLeadTime);
        assertLe(startTime, time + minLeadTime + orderDuration);
        assertEq(endTime - startTime, orderDuration, "order duration is exact");
        assertTrue(isTimeValid(time, startTime), "start time is valid");
        assertTrue(isTimeValid(time, endTime), "end time is valid");
    }

    function test_launch_gas() public {
        token1.approve(address(auctions), auctions.TOKEN_TOTAL_SUPPLY());
        forwarder.launch(address(token1), address(this));
        vm.snapshotGasLastCall("Auctions#launch");
    }
}
