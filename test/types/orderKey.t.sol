// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {OrderKey} from "../../src/types/orderKey.sol";
import {OrderId} from "../../src/types/orderId.sol";
import {OrderConfig, createOrderConfig} from "../../src/types/orderConfig.sol";
import {PoolKey} from "../../src/types/poolKey.sol";

contract OrderKeyTest is Test {
    // Test that buyToken returns the correct token based on isToken1
    function test_buyToken_whenIsToken1False(
        address token0,
        address token1,
        uint64 _fee,
        uint64 _startTime,
        uint64 _endTime
    ) public pure {
        vm.assume(token0 != token1);
        OrderKey memory ok =
            OrderKey({token0: token0, token1: token1, config: createOrderConfig(_fee, 0, false, _startTime, _endTime)});

        // When isToken1 is false, we're selling token0 and buying token1
        assertEq(ok.buyToken(), token1);
    }

    function test_buyToken_whenIsToken1True(
        address token0,
        address token1,
        uint64 _fee,
        uint64 _startTime,
        uint64 _endTime
    ) public pure {
        vm.assume(token0 != token1);
        OrderKey memory ok =
            OrderKey({token0: token0, token1: token1, config: createOrderConfig(_fee, 0, true, _startTime, _endTime)});

        // When isToken1 is true, we're selling token1 and buying token0
        assertEq(ok.buyToken(), token0);
    }

    // Test that sellToken returns the correct token based on isToken1
    function test_sellToken_whenIsToken1False(
        address token0,
        address token1,
        uint64 _fee,
        uint64 _startTime,
        uint64 _endTime
    ) public pure {
        vm.assume(token0 != token1);
        OrderKey memory ok =
            OrderKey({token0: token0, token1: token1, config: createOrderConfig(_fee, 0, false, _startTime, _endTime)});

        // When isToken1 is false, we're selling token0
        assertEq(ok.sellToken(), token0);
    }

    function test_sellToken_whenIsToken1True(
        address token0,
        address token1,
        uint64 _fee,
        uint64 _startTime,
        uint64 _endTime
    ) public pure {
        vm.assume(token0 != token1);
        OrderKey memory ok =
            OrderKey({token0: token0, token1: token1, config: createOrderConfig(_fee, 0, true, _startTime, _endTime)});

        // When isToken1 is true, we're selling token1
        assertEq(ok.sellToken(), token1);
    }

    // Test that fee extraction works correctly
    function test_fee(address token0, address token1, uint64 _fee, bool _isToken1, uint64 _startTime, uint64 _endTime)
        public
        pure
    {
        OrderKey memory ok = OrderKey({
            token0: token0,
            token1: token1,
            config: createOrderConfig(_fee, 0, _isToken1, _startTime, _endTime)
        });

        assertEq(ok.config.fee(), _fee);
    }

    // Test that isToken1 extraction works correctly
    function test_isToken1(
        address token0,
        address token1,
        uint64 _fee,
        bool _isToken1,
        uint64 _startTime,
        uint64 _endTime
    ) public pure {
        OrderKey memory ok = OrderKey({
            token0: token0,
            token1: token1,
            config: createOrderConfig(_fee, 0, _isToken1, _startTime, _endTime)
        });

        assertEq(ok.config.isToken1(), _isToken1);
    }

    // Test that startTime extraction works correctly
    function test_startTime(
        address token0,
        address token1,
        uint64 _fee,
        bool _isToken1,
        uint64 _startTime,
        uint64 _endTime
    ) public pure {
        OrderKey memory ok = OrderKey({
            token0: token0,
            token1: token1,
            config: createOrderConfig(_fee, 0, _isToken1, _startTime, _endTime)
        });

        assertEq(ok.config.startTime(), _startTime);
    }

    // Test that endTime extraction works correctly
    function test_endTime(
        address token0,
        address token1,
        uint64 _fee,
        bool _isToken1,
        uint64 _startTime,
        uint64 _endTime
    ) public pure {
        OrderKey memory ok = OrderKey({
            token0: token0,
            token1: token1,
            config: createOrderConfig(_fee, 0, _isToken1, _startTime, _endTime)
        });

        assertEq(ok.config.endTime(), _endTime);
    }

    // Test that toPoolKey creates a PoolKey with matching token0, token1, and fee
    function test_toPoolKey_tokensMatch(
        address token0,
        address token1,
        uint64 _fee,
        bool _isToken1,
        uint64 _startTime,
        uint64 _endTime,
        address twamm
    ) public pure {
        OrderKey memory ok = OrderKey({
            token0: token0,
            token1: token1,
            config: createOrderConfig(_fee, 0, _isToken1, _startTime, _endTime)
        });

        PoolKey memory pk = ok.toPoolKey(twamm);

        assertEq(pk.token0, token0);
        assertEq(pk.token1, token1);
        assertEq(pk.config.fee(), _fee);
        assertEq(pk.config.extension(), twamm);
    }

    // Test that toOrderId changes when token0 changes
    function test_toOrderId_changesWithToken0(OrderKey memory orderKey) public pure {
        OrderId id = orderKey.toOrderId();
        unchecked {
            orderKey.token0 = address(uint160(orderKey.token0) + 1);
        }
        assertNotEq(OrderId.unwrap(orderKey.toOrderId()), OrderId.unwrap(id));
    }

    // Test that toOrderId changes when token1 changes
    function test_toOrderId_changesWithToken1(OrderKey memory orderKey) public pure {
        OrderId id = orderKey.toOrderId();
        unchecked {
            orderKey.token1 = address(uint160(orderKey.token1) + 1);
        }
        assertNotEq(OrderId.unwrap(orderKey.toOrderId()), OrderId.unwrap(id));
    }

    // Test that toOrderId changes when fee changes
    function test_toOrderId_changesWithFee(OrderKey memory orderKey) public pure {
        OrderId id = orderKey.toOrderId();
        unchecked {
            orderKey.config = createOrderConfig(
                orderKey.config.fee() + 1,
                orderKey.config.poolTypeConfig(),
                orderKey.config.isToken1(),
                orderKey.config.startTime(),
                orderKey.config.endTime()
            );
        }
        assertNotEq(OrderId.unwrap(orderKey.toOrderId()), OrderId.unwrap(id));
    }

    // Test that toOrderId changes when isToken1 changes
    function test_toOrderId_changesWithIsToken1(OrderKey memory orderKey) public pure {
        OrderId id = orderKey.toOrderId();
        orderKey.config = createOrderConfig(
            orderKey.config.fee(),
            orderKey.config.poolTypeConfig(),
            !orderKey.config.isToken1(),
            orderKey.config.startTime(),
            orderKey.config.endTime()
        );
        assertNotEq(OrderId.unwrap(orderKey.toOrderId()), OrderId.unwrap(id));
    }

    // Test that toOrderId changes when startTime changes
    function test_toOrderId_changesWithStartTime(OrderKey memory orderKey) public pure {
        OrderId id = orderKey.toOrderId();
        unchecked {
            orderKey.config = createOrderConfig(
                orderKey.config.fee(),
                orderKey.config.poolTypeConfig(),
                orderKey.config.isToken1(),
                orderKey.config.startTime() + 1,
                orderKey.config.endTime()
            );
        }
        assertNotEq(OrderId.unwrap(orderKey.toOrderId()), OrderId.unwrap(id));
    }

    // Test that toOrderId changes when endTime changes
    function test_toOrderId_changesWithEndTime(OrderKey memory orderKey) public pure {
        OrderId id = orderKey.toOrderId();
        unchecked {
            orderKey.config = createOrderConfig(
                orderKey.config.fee(),
                orderKey.config.poolTypeConfig(),
                orderKey.config.isToken1(),
                orderKey.config.startTime(),
                orderKey.config.endTime() + 1
            );
        }
        assertNotEq(OrderId.unwrap(orderKey.toOrderId()), OrderId.unwrap(id));
    }

    // Test that toOrderId hash matches abi.encode (similar to poolKey test)
    function test_toOrderId_hash_matches_abi_encode(OrderKey memory ok) public pure {
        OrderId id = ok.toOrderId();
        assertEq(OrderId.unwrap(id), keccak256(abi.encode(ok)));
    }

    // Test that two identical OrderKeys produce the same toOrderId
    function test_toOrderId_aligns_with_eq(OrderKey memory ok0, OrderKey memory ok1) public pure {
        OrderId ok0Id = ok0.toOrderId();
        OrderId ok1Id = ok1.toOrderId();

        assertEq(
            ok0.token0 == ok1.token0 && ok0.token1 == ok1.token1
                && OrderConfig.unwrap(ok0.config) == OrderConfig.unwrap(ok1.config),
            OrderId.unwrap(ok0Id) == OrderId.unwrap(ok1Id)
        );
    }
}
