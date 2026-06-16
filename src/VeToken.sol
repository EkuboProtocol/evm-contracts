// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ERC721} from "solady/tokens/ERC721.sol";

/// @notice Packed vote-escrow lock state.
/// @dev Bits 0..63 store the lock end timestamp. Bits 64..191 store the locked amount.
type Lock is bytes32;

using {lockAmount, lockEnd} for Lock global;

/// @notice Creates a packed lock value.
/// @param amount Amount of stake token locked.
/// @param end Timestamp when the lock can be withdrawn.
/// @return lock Packed lock value.
function createLockValue(uint128 amount, uint64 end) pure returns (Lock lock) {
    assembly ("memory-safe") {
        lock := or(shl(64, amount), end)
    }
}

/// @notice Returns the amount stored in a packed lock.
function lockAmount(Lock lock) pure returns (uint128 amount) {
    assembly ("memory-safe") {
        amount := shr(64, lock)
    }
}

/// @notice Returns the end timestamp stored in a packed lock.
function lockEnd(Lock lock) pure returns (uint64 end) {
    assembly ("memory-safe") {
        end := and(lock, 0xffffffffffffffff)
    }
}

/// @notice Optional observer notified before an existing lock changes.
interface IVeTokenObserver {
    /// @notice Called before a lock's amount, end timestamp, or existence changes.
    /// @param veId The ve NFT id whose lock is about to change.
    /// @param currentLock The current lock state before mutation.
    function beforeLockUpdate(uint256 veId, Lock currentLock) external;
}

/// @notice Vote-escrow NFT backed by linear-decaying stake-token locks.
contract VeToken is ERC721 {
    /// @notice Maximum lock duration used for linear voting-power decay.
    uint256 public constant MAX_LOCK_DURATION = 4 * 365 days;

    /// @notice Token escrowed by locks and used to compute voting power.
    address public immutable stakeToken;

    /// @notice Observer notified before existing locks are updated, if nonzero.
    IVeTokenObserver public immutable lockObserver;

    /// @notice Packed lock state by ve NFT id.
    mapping(uint256 => Lock) public locks;

    /// @notice Next ve NFT id to mint.
    uint256 public nextVeId = 1;

    /// @notice Emitted when a new lock NFT is minted.
    event LockCreated(uint256 indexed veId, address indexed owner, uint128 amount, uint64 end);

    /// @notice Emitted when a lock's amount is increased.
    event LockAmountIncreased(uint256 indexed veId, uint128 amount);

    /// @notice Emitted when a lock's end timestamp is extended.
    event LockExtended(uint256 indexed veId, uint64 end);

    /// @notice Emitted when a lock is withdrawn and its NFT is burned.
    event LockWithdrawn(uint256 indexed veId, address indexed owner, uint128 amount);

    /// @notice Thrown when a requested lock operation violates amount or timing constraints.
    error InvalidLock();

    /// @notice Thrown when a caller is not owner or approved for a ve NFT.
    error NotAuthorizedForToken(address caller, uint256 id);

    /// @notice Creates the vote-escrow NFT contract.
    /// @param _stakeToken Token escrowed by locks.
    /// @param _lockObserver Optional observer notified before existing locks change.
    constructor(address _stakeToken, IVeTokenObserver _lockObserver) {
        stakeToken = _stakeToken;
        lockObserver = _lockObserver;
    }

    /// @notice Returns the NFT collection name.
    function name() public pure override returns (string memory) {
        return "Vote Escrow";
    }

    /// @notice Returns the NFT collection symbol.
    function symbol() public pure override returns (string memory) {
        return "ve";
    }

    /// @notice Returns token metadata URI.
    /// @dev Empty by default so derived contracts can generate metadata onchain.
    function tokenURI(uint256) public pure virtual override returns (string memory) {
        return "";
    }

    /// @notice Returns whether `account` owns or is approved for `id`.
    function isAuthorizedForNft(address account, uint256 id) public view returns (bool) {
        return _isApprovedOrOwner(account, id);
    }

    modifier authorizedForNft(uint256 id) {
        if (!isAuthorizedForNft(msg.sender, id)) revert NotAuthorizedForToken(msg.sender, id);
        _;
    }

    /// @notice Creates a new lock and mints its ve NFT to the caller.
    /// @param amount Amount of stake token to escrow.
    /// @param end Lock expiry timestamp. Must be in the future and no more than four years away.
    /// @return veId Minted ve NFT id.
    function createLock(uint128 amount, uint64 end) external returns (uint256 veId) {
        if (amount == 0 || end <= block.timestamp || end > block.timestamp + MAX_LOCK_DURATION) revert InvalidLock();

        veId = nextVeId++;
        locks[veId] = createLockValue(amount, end);
        _mint(msg.sender, veId);

        SafeTransferLib.safeTransferFrom(stakeToken, msg.sender, address(this), amount);

        emit LockCreated(veId, msg.sender, amount, end);
    }

    /// @notice Increases the amount escrowed in an active lock.
    /// @param veId The ve NFT id to update.
    /// @param amount Additional stake token amount to escrow.
    function increaseLockAmount(uint256 veId, uint128 amount) external authorizedForNft(veId) {
        Lock currentLock = locks[veId];
        uint64 currentEnd = currentLock.lockEnd();
        if (amount == 0 || currentEnd <= block.timestamp) revert InvalidLock();

        _notifyBeforeLockUpdate(veId, currentLock);
        locks[veId] = createLockValue(currentLock.lockAmount() + amount, currentEnd);
        SafeTransferLib.safeTransferFrom(stakeToken, msg.sender, address(this), amount);

        emit LockAmountIncreased(veId, amount);
    }

    /// @notice Extends an active lock.
    /// @param veId The ve NFT id to update.
    /// @param end New lock expiry timestamp.
    function extendLock(uint256 veId, uint64 end) external authorizedForNft(veId) {
        Lock currentLock = locks[veId];
        uint128 amount = currentLock.lockAmount();
        uint64 currentEnd = currentLock.lockEnd();
        if (amount == 0 || end <= currentEnd || end > block.timestamp + MAX_LOCK_DURATION) {
            revert InvalidLock();
        }

        _notifyBeforeLockUpdate(veId, currentLock);
        locks[veId] = createLockValue(amount, end);

        emit LockExtended(veId, end);
    }

    /// @notice Withdraws an expired lock, burns its ve NFT, and returns stake token.
    /// @param veId The ve NFT id to withdraw.
    function withdrawLock(uint256 veId) external authorizedForNft(veId) {
        Lock currentLock = locks[veId];
        uint128 amount = currentLock.lockAmount();
        if (amount == 0 || block.timestamp < currentLock.lockEnd()) revert InvalidLock();

        _notifyBeforeLockUpdate(veId, currentLock);
        locks[veId] = Lock.wrap(0);
        _burn(veId);
        SafeTransferLib.safeTransfer(stakeToken, msg.sender, amount);

        emit LockWithdrawn(veId, msg.sender, amount);
    }

    /// @notice Returns current linearly decayed voting power for a ve NFT.
    /// @param veId The ve NFT id to query.
    function votingPower(uint256 veId) public view returns (uint256) {
        Lock currentLock = locks[veId];
        uint64 end = currentLock.lockEnd();
        if (block.timestamp >= end) return 0;

        unchecked {
            return (uint256(currentLock.lockAmount()) * (end - block.timestamp)) / MAX_LOCK_DURATION;
        }
    }

    function _notifyBeforeLockUpdate(uint256 veId, Lock currentLock) private {
        if (address(lockObserver) != address(0)) lockObserver.beforeLockUpdate(veId, currentLock);
    }
}
