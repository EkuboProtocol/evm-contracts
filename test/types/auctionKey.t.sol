// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {AuctionKey} from "../../src/types/auctionKey.sol";
import {AuctionConfig, createAuctionConfig} from "../../src/types/auctionConfig.sol";

contract AuctionKeyTest is Test {
    function test_sellToken_whenIsSellingToken1False(
        address token0,
        address token1,
        uint32 creatorFee,
        uint24 minBoostDuration,
        uint64 graduationPoolFee,
        uint32 graduationPoolTickSpacing,
        uint64 startTime,
        uint32 auctionDuration
    ) public pure {
        vm.assume(token0 != token1);
        AuctionConfig config = createAuctionConfig({
            _creatorFee: creatorFee,
            _isSellingToken1: false,
            _minBoostDuration: minBoostDuration,
            _graduationPoolFee: graduationPoolFee,
            _graduationPoolTickSpacing: graduationPoolTickSpacing,
            _startTime: startTime,
            _auctionDuration: auctionDuration
        });
        AuctionKey memory key = AuctionKey({token0: token0, token1: token1, config: config});

        assertEq(key.sellToken(), token0);
        assertEq(key.buyToken(), token1);
    }

    function test_sellToken_whenIsSellingToken1True(
        address token0,
        address token1,
        uint32 creatorFee,
        uint24 minBoostDuration,
        uint64 graduationPoolFee,
        uint32 graduationPoolTickSpacing,
        uint64 startTime,
        uint32 auctionDuration
    ) public pure {
        vm.assume(token0 != token1);
        AuctionConfig config = createAuctionConfig({
            _creatorFee: creatorFee,
            _isSellingToken1: true,
            _minBoostDuration: minBoostDuration,
            _graduationPoolFee: graduationPoolFee,
            _graduationPoolTickSpacing: graduationPoolTickSpacing,
            _startTime: startTime,
            _auctionDuration: auctionDuration
        });
        AuctionKey memory key = AuctionKey({token0: token0, token1: token1, config: config});

        assertEq(key.sellToken(), token1);
        assertEq(key.buyToken(), token0);
    }

    function test_toAuctionId_changesWithToken0(AuctionKey memory auctionKey) public pure {
        bytes32 id = auctionKey.toAuctionId();
        unchecked {
            auctionKey.token0 = address(uint160(auctionKey.token0) + 1);
        }
        assertNotEq(auctionKey.toAuctionId(), id);
    }

    function test_toAuctionId_changesWithToken1(AuctionKey memory auctionKey) public pure {
        bytes32 id = auctionKey.toAuctionId();
        unchecked {
            auctionKey.token1 = address(uint160(auctionKey.token1) + 1);
        }
        assertNotEq(auctionKey.toAuctionId(), id);
    }

    function test_toAuctionId_changesWithIsSellingToken1(AuctionKey memory auctionKey) public pure {
        bytes32 id = auctionKey.toAuctionId();
        auctionKey.config = createAuctionConfig({
            _creatorFee: auctionKey.config.creatorFee(),
            _isSellingToken1: !auctionKey.config.isSellingToken1(),
            _minBoostDuration: auctionKey.config.minBoostDuration(),
            _graduationPoolFee: auctionKey.config.graduationPoolFee(),
            _graduationPoolTickSpacing: auctionKey.config.graduationPoolTickSpacing(),
            _startTime: auctionKey.config.startTime(),
            _auctionDuration: auctionKey.config.auctionDuration()
        });
        assertNotEq(auctionKey.toAuctionId(), id);
    }

    function test_toAuctionId_changesWithCreatorFee(AuctionKey memory auctionKey) public pure {
        bytes32 id = auctionKey.toAuctionId();
        unchecked {
            auctionKey.config = createAuctionConfig({
                _creatorFee: auctionKey.config.creatorFee() + 1,
                _isSellingToken1: auctionKey.config.isSellingToken1(),
                _minBoostDuration: auctionKey.config.minBoostDuration(),
                _graduationPoolFee: auctionKey.config.graduationPoolFee(),
                _graduationPoolTickSpacing: auctionKey.config.graduationPoolTickSpacing(),
                _startTime: auctionKey.config.startTime(),
                _auctionDuration: auctionKey.config.auctionDuration()
            });
        }
        assertNotEq(auctionKey.toAuctionId(), id);
    }

    function test_toAuctionId_changesWithMinBoostDuration(AuctionKey memory auctionKey) public pure {
        bytes32 id = auctionKey.toAuctionId();
        unchecked {
            auctionKey.config = createAuctionConfig({
                _creatorFee: auctionKey.config.creatorFee(),
                _isSellingToken1: auctionKey.config.isSellingToken1(),
                _minBoostDuration: auctionKey.config.minBoostDuration() + 1,
                _graduationPoolFee: auctionKey.config.graduationPoolFee(),
                _graduationPoolTickSpacing: auctionKey.config.graduationPoolTickSpacing(),
                _startTime: auctionKey.config.startTime(),
                _auctionDuration: auctionKey.config.auctionDuration()
            });
        }
        assertNotEq(auctionKey.toAuctionId(), id);
    }

    function test_toAuctionId_changesWithGraduationPoolFee(AuctionKey memory auctionKey) public pure {
        bytes32 id = auctionKey.toAuctionId();
        unchecked {
            auctionKey.config = createAuctionConfig({
                _creatorFee: auctionKey.config.creatorFee(),
                _isSellingToken1: auctionKey.config.isSellingToken1(),
                _minBoostDuration: auctionKey.config.minBoostDuration(),
                _graduationPoolFee: auctionKey.config.graduationPoolFee() + 1,
                _graduationPoolTickSpacing: auctionKey.config.graduationPoolTickSpacing(),
                _startTime: auctionKey.config.startTime(),
                _auctionDuration: auctionKey.config.auctionDuration()
            });
        }
        assertNotEq(auctionKey.toAuctionId(), id);
    }

    function test_toAuctionId_changesWithGraduationPoolTickSpacing(AuctionKey memory auctionKey) public pure {
        bytes32 id = auctionKey.toAuctionId();
        unchecked {
            auctionKey.config = createAuctionConfig({
                _creatorFee: auctionKey.config.creatorFee(),
                _isSellingToken1: auctionKey.config.isSellingToken1(),
                _minBoostDuration: auctionKey.config.minBoostDuration(),
                _graduationPoolFee: auctionKey.config.graduationPoolFee(),
                _graduationPoolTickSpacing: auctionKey.config.graduationPoolTickSpacing() + 1,
                _startTime: auctionKey.config.startTime(),
                _auctionDuration: auctionKey.config.auctionDuration()
            });
        }
        assertNotEq(auctionKey.toAuctionId(), id);
    }

    function test_toAuctionId_changesWithStartTime(AuctionKey memory auctionKey) public pure {
        bytes32 id = auctionKey.toAuctionId();
        unchecked {
            auctionKey.config = createAuctionConfig({
                _creatorFee: auctionKey.config.creatorFee(),
                _isSellingToken1: auctionKey.config.isSellingToken1(),
                _minBoostDuration: auctionKey.config.minBoostDuration(),
                _graduationPoolFee: auctionKey.config.graduationPoolFee(),
                _graduationPoolTickSpacing: auctionKey.config.graduationPoolTickSpacing(),
                _startTime: auctionKey.config.startTime() + 1,
                _auctionDuration: auctionKey.config.auctionDuration()
            });
        }
        assertNotEq(auctionKey.toAuctionId(), id);
    }

    function test_toAuctionId_changesWithAuctionDuration(AuctionKey memory auctionKey) public pure {
        bytes32 id = auctionKey.toAuctionId();
        unchecked {
            auctionKey.config = createAuctionConfig({
                _creatorFee: auctionKey.config.creatorFee(),
                _isSellingToken1: auctionKey.config.isSellingToken1(),
                _minBoostDuration: auctionKey.config.minBoostDuration(),
                _graduationPoolFee: auctionKey.config.graduationPoolFee(),
                _graduationPoolTickSpacing: auctionKey.config.graduationPoolTickSpacing(),
                _startTime: auctionKey.config.startTime(),
                _auctionDuration: auctionKey.config.auctionDuration() + 1
            });
        }
        assertNotEq(auctionKey.toAuctionId(), id);
    }

    function check_toAuctionId_aligns_with_eq(AuctionKey memory k0, AuctionKey memory k1) public pure {
        bytes32 k0Id = k0.toAuctionId();
        bytes32 k1Id = k1.toAuctionId();

        assertEq(
            k0.token0 == k1.token0 && k0.token1 == k1.token1
                && AuctionConfig.unwrap(k0.config) == AuctionConfig.unwrap(k1.config),
            k0Id == k1Id
        );
    }

    function test_toAuctionId_hash_matches_abi_encode(AuctionKey memory key) public pure {
        assertEq(key.toAuctionId(), keccak256(abi.encode(key)));
    }
}
