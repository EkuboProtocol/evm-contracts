// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {Core} from "../src/Core.sol";
import {TestToken} from "./TestToken.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolConfig, createPoolConfig} from "../src/types/poolConfig.sol";
import {PoolId} from "../src/types/poolId.sol";
import {Position} from "../src/types/position.sol";
import {PositionId, createPositionId} from "../src/types/positionId.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";

contract PositionExtraDataTest is Test, BaseLocker {
    using CoreLib for *;

    Core public core;
    TestToken public token0;
    TestToken public token1;
    PoolKey public poolKey;
    PoolId public poolId;

    constructor() BaseLocker(Core(address(0))) {}

    function setUp() public {
        core = new Core();
        CORE = core;

        token0 = new TestToken(address(this));
        token1 = new TestToken(address(this));

        // Ensure token0 < token1
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        // Create pool key
        poolKey =
            PoolKey({token0: address(token0), token1: address(token1), config: createPoolConfig(3000, 60, address(0))});

        poolId = poolKey.toPoolId();

        // Initialize pool
        core.initializePool(poolKey, 0);
    }

    function handleLockData(uint256, bytes memory) internal override returns (bytes memory) {
        // Not used in this test
        return "";
    }

    function test_setExtraData_roundtrip() public {
        PositionId positionId = createPositionId({_salt: bytes24(0), _tickLower: -60, _tickUpper: 60});

        // Create a position by calling core directly
        lock(
            abi.encode(
                bytes1(0x01), // custom call type for this test
                poolKey,
                positionId,
                int128(1000e18)
            )
        );

        // Set extraData
        bytes16 extraData = bytes16(uint128(0x123456789abcdef));
        lock(abi.encode(bytes1(0x02), poolId, positionId, extraData));

        // Read position via CoreLib
        Position memory position = core.poolPositions(poolId, address(this), positionId);

        // Verify extraData was set correctly
        assertEq(position.extraData, extraData, "extraData should match");
        assertGt(position.liquidity, 0, "liquidity should be nonzero");
    }

    function test_setExtraData_reverts_if_liquidity_zero() public {
        PositionId positionId = createPositionId({_salt: bytes24(0), _tickLower: -60, _tickUpper: 60});

        // Try to set extraData on a position that doesn't exist (liquidity = 0)
        bytes16 extraData = bytes16(uint128(0x123));

        vm.expectRevert();
        lock(abi.encode(bytes1(0x02), poolId, positionId, extraData));
    }

    function handleLockData(uint256, bytes memory data) internal returns (bytes memory) {
        bytes1 callType = data[0];

        if (callType == 0x01) {
            // Create position
            (, PoolKey memory _poolKey, PositionId _positionId, int128 liquidityDelta) =
                abi.decode(data, (bytes1, PoolKey, PositionId, int128));

            core.updatePosition(_poolKey, _positionId, liquidityDelta);

            // Pay for the position
            uint128 amount0 = 1000e18;
            uint128 amount1 = 1000e18;
            token0.transfer(address(core), amount0);
            token1.transfer(address(core), amount1);
        } else if (callType == 0x02) {
            // Set extraData
            (, PoolId _poolId, PositionId _positionId, bytes16 _extraData) =
                abi.decode(data, (bytes1, PoolId, PositionId, bytes16));

            core.setPositionExtraData(_poolId, _positionId, _extraData);
        }

        return "";
    }
}
