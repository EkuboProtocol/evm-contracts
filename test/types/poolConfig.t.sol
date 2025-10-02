// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {PoolConfig, createPoolConfig} from "../../src/types/poolConfig.sol";

contract PoolConfigTest is Test {
    function test_conversionToAndFrom(PoolConfig config) public pure {
        assertEq(
            PoolConfig.unwrap(
                createPoolConfig({
                    _fee: config.fee(),
                    _tickSpacing: config.tickSpacing(),
                    _extension: config.extension()
                })
            ),
            PoolConfig.unwrap(config)
        );
    }

    function test_conversionFromAndTo(uint64 fee, uint32 tickSpacing, address extension) public pure {
        PoolConfig config = createPoolConfig({_fee: fee, _tickSpacing: tickSpacing, _extension: extension});
        assertEq(config.fee(), fee);
        assertEq(config.tickSpacing(), tickSpacing);
        assertEq(config.extension(), extension);
    }

    function test_conversionFromAndToDirtyBits(bytes32 feeDirty, bytes32 tickSpacingDirty, bytes32 extensionDirty)
        public
        pure
    {
        uint64 fee;
        uint32 tickSpacing;
        address extension;

        assembly ("memory-safe") {
            fee := feeDirty
            tickSpacing := tickSpacingDirty
            extension := extensionDirty
        }

        PoolConfig config = createPoolConfig({_fee: fee, _tickSpacing: tickSpacing, _extension: extension});
        assertEq(config.fee(), fee, "fee");
        assertEq(config.tickSpacing(), tickSpacing, "tickSpacing");
        assertEq(config.extension(), extension, "extension");
    }
}
