// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

import {ICore} from "./interfaces/ICore.sol";
import {TokenWrapper} from "./TokenWrapper.sol";
import {BaseForwardee} from "./base/BaseForwardee.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {Locker} from "./types/locker.sol";

/// @title Token Wrapper Factory
/// @author Ekubo Protocol
/// @notice Immutable singleton for deploying wrappers and accounting for their backing in Core
contract TokenWrapperFactory is BaseForwardee {
    using FlashAccountantLib for *;

    /// @notice The original locker was not deployed by this factory
    error UnknownWrapper();
    /// @notice Migration must have a negative delta and extend maturity within the same underlying/factory
    error InvalidMigration();

    /// @notice Emitted whenever a wrapper is deployed; retained for indexing compatibility
    event TokenWrapperDeployed(IERC20 underlyingToken, uint256 unlockTime, TokenWrapper tokenWrapper);
    event Migrated(TokenWrapper indexed source, TokenWrapper indexed destination, uint128 amount);

    ICore public immutable CORE;

    /// @notice Only wrappers deployed by this singleton can access its backing buckets
    mapping(address wrapper => bool) public isWrapper;

    constructor(ICore _core) BaseForwardee(_core) {
        CORE = _core;
    }

    /// @notice Deploys and registers a wrapper with a deterministic CREATE2 address
    /// @param underlyingToken The token to be wrapped
    /// @param unlockTime Timestamp at which wrapped tokens can be redeemed
    /// @return tokenWrapper The deployed wrapper
    function deployWrapper(IERC20 underlyingToken, uint256 unlockTime) external returns (TokenWrapper tokenWrapper) {
        bytes32 salt = EfficientHashLib.hash(uint256(uint160(address(underlyingToken))), unlockTime);
        tokenWrapper = new TokenWrapper{salt: salt}(CORE, underlyingToken, unlockTime);
        isWrapper[address(tokenWrapper)] = true;
        emit TokenWrapperDeployed(underlyingToken, unlockTime, tokenWrapper);
    }

    /// @dev Called only by a registered wrapper through Core.forward. Migration moves backing
    /// between buckets without releasing underlying, and credits destination wrapper debt.
    function handleForwardData(Locker original, bytes memory data) internal override returns (bytes memory) {
        TokenWrapper source = TokenWrapper(original.addr());
        if (!isWrapper[address(source)]) revert UnknownWrapper();
        int256 delta = abi.decode(data, (int256));
        address underlying = address(source.UNDERLYING_TOKEN());

        TokenWrapper destination;
        if (data.length != 32) {
            (, destination) = abi.decode(data, (int256, TokenWrapper));
            if (
                delta >= 0 || !isWrapper[address(destination)] || address(destination.UNDERLYING_TOKEN()) != underlying
                    || destination.UNLOCK_TIME() <= source.UNLOCK_TIME()
            ) revert InvalidMigration();
        } else if (delta < 0 && block.timestamp < source.UNLOCK_TIME()) {
            revert TokenWrapper.TooEarly();
        }

        CORE.updateSavedBalances({
            token0: underlying,
            token1: address(type(uint160).max),
            salt: bytes32(uint256(uint160(address(source)))),
            delta0: delta,
            delta1: 0
        });

        if (address(destination) != address(0)) {
            CORE.updateSavedBalances({
                token0: underlying,
                token1: address(type(uint160).max),
                salt: bytes32(uint256(uint160(address(destination)))),
                delta0: -delta,
                delta1: 0
            });
            CORE.forward(address(destination), abi.encode(-delta));
            emit Migrated(source, destination, uint128(uint256(-delta)));
        }
        return bytes("");
    }
}
