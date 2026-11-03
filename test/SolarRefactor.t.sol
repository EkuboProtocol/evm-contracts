// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {MEVCaptureV21} from "../src/extensions/MEVCaptureV21.sol";
import {ICore, PoolKey} from "../src/interfaces/ICore.sol";
import {PoolConfig} from "../src/types/poolConfig.sol";
import {PoolState} from "../src/types/poolState.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {SwapParameters, createSwapParameters} from "../src/types/swapParameters.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";

contract SolarSegmentHarness is MEVCaptureV21 {
    constructor(ICore core) MEVCaptureV21(core, 120, 4, 0, 16, 1 << 15, 2500, 3) {}

    function _registerInConstructor() internal pure override returns (bool) {
        return false;
    }

    function segment(PoolKey memory key, SwapParameters params, SqrtRatio limit, int128 amount, uint256 fee)
        external
        returns (PoolBalanceUpdate, PoolState)
    {
        return _coreSwap(key, params, limit, amount, fee);
    }
}

contract SolarRefactorTest is Test {
    SolarSegmentHarness segmentHarness;
    address constant MOCK_CORE = address(0x1234);

    function setUp() public {
        segmentHarness = new SolarSegmentHarness(ICore(payable(MOCK_CORE)));
    }

    function test_isZero(uint96 value) public pure {
        assertEq(SqrtRatio.wrap(value).isZero(), value == 0);
        assertTrue(SqrtRatio.wrap(0).isZero());
        assertFalse(SqrtRatio.wrap(type(uint96).max).isZero());
    }

    function test_segment_preserves_packed_fields(bytes32 rawParams, uint96 rawLimit, int128 amount, uint256 fee)
        public
    {
        SwapParameters params = SwapParameters.wrap(rawParams);
        SqrtRatio limit = SqrtRatio.wrap(rawLimit);
        PoolKey memory key = PoolKey(address(1), address(2), PoolConfig.wrap(bytes32(uint256(3))));
        SwapParameters expected =
            createSwapParameters(limit, amount, params.isToken1(), params.skipAhead(), uint16(fee));
        bytes memory callData = abi.encodeWithSelector(ICore.swap_6269342730.selector, key, expected);
        vm.mockCall(MOCK_CORE, callData, abi.encode(bytes32(uint256(4)), bytes32(uint256(5))));
        vm.expectCall(MOCK_CORE, callData, 1);
        (PoolBalanceUpdate delta, PoolState state) = segmentHarness.segment(key, params, limit, amount, fee);
        assertEq(PoolBalanceUpdate.unwrap(delta), bytes32(uint256(4)));
        assertEq(PoolState.unwrap(state), bytes32(uint256(5)));
    }
}
