// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {StableswapLPTokenWrapper} from "./StableswapLPTokenWrapper.sol";
import {IStableswapLPPositions} from "../interfaces/IStableswapLPPositions.sol";

/// @title StableswapLPTokenWrapperFactory
/// @notice Factory for creating ERC20 wrappers around ERC6909 LP tokens
/// @dev Uses CREATE2 for deterministic addresses
/// @author Bogdan Sivochkin
contract StableswapLPTokenWrapperFactory {
    /// @notice The StableswapLPPositions contract
    IStableswapLPPositions public immutable positions;

    /// @notice Mapping from poolId to wrapper address
    mapping(uint256 => address) public wrappers;

    /// @notice Emitted when a wrapper is created
    event WrapperCreated(uint256 indexed poolId, address wrapper);

    /// @notice Constructs the wrapper factory
    /// @param _positions The StableswapLPPositions contract
    constructor(IStableswapLPPositions _positions) {
        positions = _positions;
    }

    /// @notice Get or create a wrapper for a pool
    /// @param poolId The pool ID (ERC6909 token ID)
    /// @return wrapper The wrapper contract address
    function getOrCreateWrapper(uint256 poolId) external returns (address wrapper) {
        wrapper = wrappers[poolId];

        if (wrapper == address(0)) {
            // Deploy wrapper via CREATE2 for deterministic address
            bytes32 salt = bytes32(poolId);
            wrapper = address(
                new StableswapLPTokenWrapper{salt: salt}(positions, poolId)
            );
            wrappers[poolId] = wrapper;

            emit WrapperCreated(poolId, wrapper);
        }
    }

    /// @notice Predict the wrapper address for a pool
    /// @param poolId The pool ID
    /// @return The predicted wrapper address
    function predictWrapperAddress(uint256 poolId) external view returns (address) {
        bytes32 salt = bytes32(poolId);
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(
                    abi.encodePacked(
                        type(StableswapLPTokenWrapper).creationCode,
                        abi.encode(positions, poolId)
                    )
                )
            )
        );
        return address(uint160(uint256(hash)));
    }
}
