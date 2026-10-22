// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {IZeroSeedLaunch} from "./extensions/IZeroSeedLaunch.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";

/// @title Zero-seed launch periphery interface
/// @notice Owner-of-record for launches created through it: creates launches by forwarding to the extension, keeps
/// the transferable owner of each, and claims and pays out creator fees. Swaps do not go through this contract; any
/// locker swaps by forwarding to the extension directly.
/// @dev From the extension's view this contract is the controller of every launch it creates. The extension salt is
/// `keccak256(abi.encode(owner, salt))`, so two owners never share a token address, and the launch token is
/// `CREATE2(extension, keccak256(abi.encode(periphery, keccak256(abi.encode(owner, salt)))), initCodeHash)`.
interface IZeroSeedLaunchPeriphery {
    error OwnerOnly();
    error InvalidOwner();
    error InvalidRecipient();

    /// @notice Emitted at creation (from the zero address) and on every transfer.
    event LaunchOwnerChanged(PoolId indexed poolId, address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when the whole fee ledger of a launch is paid to `recipient`.
    event LaunchFeesClaimed(
        PoolId indexed poolId, address indexed owner, address indexed recipient, uint128 amount0, uint128 amount1
    );

    /// @notice Creates the launch token, pool and locked position atomically; `msg.sender` becomes the owner.
    /// `parameters.salt` is namespaced by `msg.sender` before it reaches the extension.
    function create(IZeroSeedLaunch.LaunchParameters memory parameters)
        external
        returns (IZeroSeedLaunch.Installation memory installation);

    /// @notice `IZeroSeedLaunch.previewInstallation` for a launch `owner` would create here with `parameters`.
    function previewInstallation(address owner, IZeroSeedLaunch.LaunchParameters memory parameters)
        external
        view
        returns (IZeroSeedLaunch.Installation memory installation);

    /// @notice Sends the whole creator fee ledger of a launch to `recipient`, both assets or nothing. Owner only.
    /// `recipient` must not be zero, Core, the extension, this contract or either pool token.
    function claimFees(PoolKey memory poolKey, address recipient) external returns (uint128 amount0, uint128 amount1);

    /// @notice Hands the launch, including its unclaimed and future fees, to `newOwner`. Owner only.
    function transferLaunch(PoolId poolId, address newOwner) external;

    function launchOwner(PoolId poolId) external view returns (address);

    function LAUNCH() external view returns (IZeroSeedLaunch);
}
