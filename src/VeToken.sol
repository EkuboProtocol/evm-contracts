// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

import {BaseLocker} from "./base/BaseLocker.sol";
import {
    VE33,
    VE33_CLAIM_POOL_FEES,
    VE33_MAX_LOCK_DURATION,
    VE33_MOVE_LOCK,
    VE33_STAKE_LOCK,
    VE33_UNSTAKE_LOCK
} from "./extensions/VE33.sol";
import {ICore} from "./interfaces/ICore.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {defaultFeeForTickSpacing} from "./math/tickSpacingFee.sol";
import {PoolKey} from "./types/poolKey.sol";

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

/// @notice ERC721 representation over VE33 lock accounting.
/// @dev The canonical lock is owned by this wrapper in VE33. ERC721 ownership controls the wrapper.
contract VeToken is ERC721, BaseLocker {
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_STAKE_LOCK = 0;
    uint256 private constant CALL_TYPE_UNSTAKE_LOCK = 1;
    uint256 private constant CALL_TYPE_MOVE_LOCK = 2;
    uint256 private constant CALL_TYPE_CLAIM_POOL_FEES = 3;

    /// @notice The VE33 extension that owns the canonical lock, vote, and fee accounting.
    VE33 public immutable ve33;

    /// @notice The token locked for voting power.
    address public immutable stakeToken;

    string private _name;
    string private _symbol;
    string private _stakeTokenName;
    string private _stakeTokenSymbol;

    /// @notice The next ERC721 token id to mint.
    /// @dev Token ids start at 1 and are used directly as VE33 lock salts.
    uint256 public nextVeId = 1;

    /// @notice Emitted when a new VE33 lock is created and represented by an ERC721 token.
    /// @param veId The ERC721 token id and VE33 lock salt.
    /// @param owner The initial ERC721 owner.
    /// @param amount The amount of stake token requested for the initial lock.
    /// @param end The lock end timestamp.
    event LockCreated(uint256 indexed veId, address indexed owner, uint128 amount, uint64 end);

    /// @notice Emitted when stake is added to an existing represented lock.
    /// @param veId The ERC721 token id and VE33 lock salt.
    /// @param amount The additional amount of stake token requested.
    event LockAmountIncreased(uint256 indexed veId, uint128 amount);

    /// @notice Emitted when a represented lock is moved to a later end timestamp.
    /// @param veId The ERC721 token id and VE33 lock salt.
    /// @param end The new lock end timestamp.
    event LockExtended(uint256 indexed veId, uint64 end);

    /// @notice Emitted when an expired represented lock is unstaked and the ERC721 token is burned.
    /// @param veId The ERC721 token id and VE33 lock salt.
    /// @param owner The ERC721 owner receiving the unlocked stake token.
    /// @param amount The amount of stake token withdrawn.
    event LockUnstaked(uint256 indexed veId, address indexed owner, uint128 amount);

    /// @notice Thrown when a lock update is invalid for this wrapper.
    error InvalidLock();

    /// @notice Thrown when a caller is not the ERC721 owner or approved account for a represented lock.
    /// @param caller The unauthorized caller.
    /// @param id The ERC721 token id.
    error NotAuthorizedForToken(address caller, uint256 id);

    /// @notice Creates the ERC721 lock wrapper.
    /// @param core The Ekubo Core contract used for lock and token settlement.
    /// @param _ve33 The VE33 extension containing canonical vote-escrow accounting.
    constructor(ICore core, VE33 _ve33) BaseLocker(core) {
        ve33 = _ve33;
        stakeToken = _ve33.stakeToken();
        _stakeTokenName = IERC20(stakeToken).name();
        _stakeTokenSymbol = IERC20(stakeToken).symbol();
        _name = string.concat("Vote Escrow ", _stakeTokenName);
        _symbol = string.concat("ve", _stakeTokenSymbol);
    }

    receive() external payable {}

    /// @inheritdoc ERC721
    function name() public view override returns (string memory) {
        return _name;
    }

    /// @inheritdoc ERC721
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @inheritdoc ERC721
    /// @dev Returns a base64 JSON data URI with `name`, `description`, and `image` fields.
    ///      The image is an embedded SVG generated from the current VE33 lock amount, lock end, and stake token.
    function tokenURI(uint256 id) public view override returns (string memory) {
        Lock lock_ = locks(id);
        string memory idString = LibString.toString(id);
        string memory tokenName = string.concat(_symbol, " #", idString);
        string memory description = string.concat(
            "Vote-escrowed ",
            _stakeTokenName,
            " lock. Amount: ",
            LibString.toString(lock_.lockAmount()),
            " ",
            _stakeTokenSymbol,
            ". Unlock time: ",
            LibString.toString(lock_.lockEnd()),
            ". Stake token: ",
            LibString.toHexStringChecksummed(stakeToken),
            "."
        );
        string memory image = string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(_tokenSvg(id, lock_))));

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        "{\"name\":",
                        LibString.escapeJSON(tokenName, true),
                        ",\"description\":",
                        LibString.escapeJSON(description, true),
                        ",\"image\":",
                        LibString.escapeJSON(image, true),
                        "}"
                    )
                )
            )
        );
    }

    /// @notice Returns the maximum lock duration accepted by VE33.
    /// @return The maximum lock duration in seconds.
    function MAX_LOCK_DURATION() external pure returns (uint256) {
        return VE33_MAX_LOCK_DURATION;
    }

    /// @notice Returns whether `account` may manage the represented lock.
    /// @dev Uses Solady ERC721 ownership and approval checks. Reverts if `id` does not exist.
    /// @param account The account to check.
    /// @param id The ERC721 token id.
    /// @return True if the account owns the token or is approved for it.
    function isAuthorizedForNft(address account, uint256 id) public view returns (bool) {
        return _isApprovedOrOwner(account, id);
    }

    /// @notice Requires the caller to own or be approved for a represented lock.
    /// @param id The ERC721 token id.
    modifier authorizedForLock(uint256 id) {
        if (!isAuthorizedForNft(msg.sender, id)) revert NotAuthorizedForToken(msg.sender, id);
        _;
    }

    /// @notice Returns the current represented lock state.
    /// @dev The lock end is stored in ERC721 extraData. The amount is fetched from `VE33.lockAmounts`.
    /// @param id The ERC721 token id, also used as the VE33 lock salt.
    /// @return The packed lock amount and end timestamp.
    function locks(uint256 id) public view returns (Lock) {
        uint64 endTime = _lockEndTime(id);
        return createLockValue(ve33.lockAmounts(address(this), bytes32(id), endTime), endTime);
    }

    /// @notice Creates a VE33 lock and mints an ERC721 token that controls it.
    /// @dev The minted token id is used as the VE33 lock salt. Stake token settlement happens in the Core lock.
    /// @param amount The amount of stake token to lock.
    /// @param end The lock end timestamp.
    /// @return veId The minted ERC721 token id.
    function createLock(uint128 amount, uint64 end) external returns (uint256 veId) {
        veId = nextVeId++;
        _mintAndSetExtraDataUnchecked(msg.sender, veId, end);

        lock(abi.encode(CALL_TYPE_STAKE_LOCK, msg.sender, bytes32(veId), end, amount));

        emit LockCreated(veId, msg.sender, amount, end);
    }

    /// @notice Adds stake token to an existing represented lock.
    /// @dev The caller must own or be approved for `veId`. Stake token settlement happens in the Core lock.
    /// @param veId The ERC721 token id and VE33 lock salt.
    /// @param amount The amount of stake token to add.
    function increaseLockAmount(uint256 veId, uint128 amount) external authorizedForLock(veId) {
        lock(abi.encode(CALL_TYPE_STAKE_LOCK, msg.sender, bytes32(veId), _lockEndTime(veId), amount));

        emit LockAmountIncreased(veId, amount);
    }

    /// @notice Moves an existing represented lock to a later end timestamp.
    /// @dev The caller must own or be approved for `veId`. Extending clears votes in VE33.
    /// @param veId The ERC721 token id and VE33 lock salt.
    /// @param end The new lock end timestamp.
    function extendLock(uint256 veId, uint64 end) external authorizedForLock(veId) {
        uint64 currentEnd = _lockEndTime(veId);
        if (end <= currentEnd) revert InvalidLock();

        bytes32 salt = bytes32(veId);
        uint128 amount = ve33.lockAmounts(address(this), salt, currentEnd);
        lock(abi.encode(CALL_TYPE_MOVE_LOCK, salt, currentEnd, salt, end, amount));
        _setExtraData(veId, end);

        emit LockExtended(veId, end);
    }

    /// @notice Unstakes an expired represented lock and burns its ERC721 token.
    /// @dev The caller must own or be approved for `veId`; unlocked stake is withdrawn to the current ERC721 owner.
    /// @param veId The ERC721 token id and VE33 lock salt.
    function withdrawLock(uint256 veId) external authorizedForLock(veId) {
        address owner = ownerOf(veId);
        bytes32 salt = bytes32(veId);
        uint64 endTime = _lockEndTime(veId);
        uint128 amount = ve33.lockAmounts(address(this), salt, endTime);
        lock(abi.encode(CALL_TYPE_UNSTAKE_LOCK, salt, endTime, amount, owner));

        _burn(veId);
        _setExtraData(veId, 0);

        emit LockUnstaked(veId, owner, amount);
    }

    /// @notice Returns the current voting power of a represented lock.
    /// @param veId The ERC721 token id and VE33 lock salt.
    /// @return The lock voting power at the current timestamp.
    function votingPower(uint256 veId) public view returns (uint256) {
        return ve33.votingPower(lockKey(veId));
    }

    /// @notice Returns the VE33 lock key represented by an ERC721 token.
    /// @dev The VE33 lock owner is always this contract, and the salt is `bytes32(veId)`.
    /// @param veId The ERC721 token id.
    /// @return The canonical VE33 lock key.
    function lockKey(uint256 veId) public view returns (VE33.LockKey memory) {
        return VE33.LockKey({owner: address(this), salt: bytes32(veId), endTime: _lockEndTime(veId)});
    }

    /// @notice Votes a represented lock on pools with explicit swap fees.
    /// @dev The caller must own or be approved for `veId`.
    /// @param veId The ERC721 token id and VE33 lock salt.
    /// @param poolKeys The pools to vote on.
    /// @param weights The vote weights for each pool.
    /// @param swapFees The selected swap fee for each pool.
    function vote(uint256 veId, PoolKey[] calldata poolKeys, uint256[] calldata weights, uint64[] calldata swapFees)
        external
        authorizedForLock(veId)
    {
        ve33.vote(lockKey(veId), poolKeys, weights, swapFees);
    }

    /// @notice Votes a represented lock on pools using default fees derived from tick spacing.
    /// @dev The caller must own or be approved for `veId`.
    /// @param veId The ERC721 token id and VE33 lock salt.
    /// @param poolKeys The pools to vote on.
    /// @param weights The vote weights for each pool.
    /// @param tickSpacings The tick spacings used to derive default swap fees.
    function voteWithTickSpacing(
        uint256 veId,
        PoolKey[] calldata poolKeys,
        uint256[] calldata weights,
        uint32[] calldata tickSpacings
    ) external authorizedForLock(veId) {
        uint64[] memory swapFees = new uint64[](tickSpacings.length);
        for (uint256 i = 0; i < tickSpacings.length; i++) {
            swapFees[i] = defaultFeeForTickSpacing(tickSpacings[i]);
        }
        ve33.vote(lockKey(veId), poolKeys, weights, swapFees);
    }

    /// @notice Claims pool fees earned by a represented lock to its current ERC721 owner.
    /// @dev Permissionless; the recipient is always `ownerOf(veId)`.
    /// @param veId The ERC721 token id and VE33 lock salt.
    /// @param poolKey The pool whose voter fees should be claimed.
    /// @return amount0 The amount of token0 withdrawn to the owner.
    /// @return amount1 The amount of token1 withdrawn to the owner.
    function claimPoolFees(uint256 veId, PoolKey memory poolKey) external returns (uint128 amount0, uint128 amount1) {
        address owner = ownerOf(veId);
        (amount0, amount1) =
            abi.decode(lock(abi.encode(CALL_TYPE_CLAIM_POOL_FEES, veId, owner, poolKey)), (uint128, uint128));
    }

    /// @notice Settles token-moving wrapper actions inside the Core lock.
    /// @dev VE33 only updates saved balances. This handler pays stake on stake, withdraws stake on unstake,
    ///      and withdraws claimed pool fees to the current ERC721 owner selected before forwarding.
    /// @param data Encoded wrapper call type and arguments.
    /// @return result Encoded return data from the underlying VE33 forward call.
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_STAKE_LOCK) {
            (, address owner, bytes32 salt, uint64 endTime, uint128 amount) =
                abi.decode(data, (uint256, address, bytes32, uint64, uint128));
            result = ACCOUNTANT.forward(address(ve33), abi.encode(VE33_STAKE_LOCK, salt, endTime, amount));
            uint128 staked = abi.decode(result, (uint128));
            if (staked != 0) ACCOUNTANT.payFrom(owner, stakeToken, staked);
        } else if (callType == CALL_TYPE_UNSTAKE_LOCK) {
            (, bytes32 salt, uint64 endTime, uint128 amount, address recipient) =
                abi.decode(data, (uint256, bytes32, uint64, uint128, address));
            result = ACCOUNTANT.forward(address(ve33), abi.encode(VE33_UNSTAKE_LOCK, salt, endTime, amount));
            uint128 unstaked = abi.decode(result, (uint128));
            if (unstaked != 0) ACCOUNTANT.withdraw(stakeToken, recipient, unstaked);
        } else if (callType == CALL_TYPE_MOVE_LOCK) {
            (, bytes32 fromSalt, uint64 fromEndTime, bytes32 toSalt, uint64 toEndTime, uint128 amount) =
                abi.decode(data, (uint256, bytes32, uint64, bytes32, uint64, uint128));
            result = ACCOUNTANT.forward(
                address(ve33), abi.encode(VE33_MOVE_LOCK, fromSalt, fromEndTime, toSalt, toEndTime, amount)
            );
        } else if (callType == CALL_TYPE_CLAIM_POOL_FEES) {
            (, uint256 veId, address recipient, PoolKey memory poolKey) =
                abi.decode(data, (uint256, uint256, address, PoolKey));
            result = ACCOUNTANT.forward(address(ve33), abi.encode(VE33_CLAIM_POOL_FEES, lockKey(veId), poolKey));
            (uint128 amount0, uint128 amount1) = abi.decode(result, (uint128, uint128));
            ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, recipient, amount0, amount1);
        } else {
            revert();
        }
    }

    /// @notice Returns the lock end timestamp stored in ERC721 extraData.
    /// @param veId The ERC721 token id.
    /// @return The lock end timestamp.
    function _lockEndTime(uint256 veId) private view returns (uint64) {
        if (!_exists(veId)) revert TokenDoesNotExist();
        return uint64(_getExtraData(veId));
    }

    /// @notice Builds the SVG image embedded in ERC721 metadata.
    /// @param id The ERC721 token id.
    /// @param lock_ The current lock state.
    /// @return The raw SVG string.
    function _tokenSvg(uint256 id, Lock lock_) private view returns (string memory) {
        string memory tokenAddress = LibString.toHexStringChecksummed(stakeToken);
        return string.concat(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 480 480\">",
            "<rect width=\"480\" height=\"480\" fill=\"#101114\"/>",
            "<rect x=\"32\" y=\"32\" width=\"416\" height=\"416\" rx=\"18\" fill=\"#f6f1e8\"/>",
            "<text x=\"56\" y=\"96\" fill=\"#101114\" font-family=\"monospace\" font-size=\"28\" font-weight=\"700\">",
            LibString.escapeHTML(_symbol),
            " #",
            LibString.toString(id),
            "</text>",
            "<text x=\"56\" y=\"148\" fill=\"#101114\" font-family=\"monospace\" font-size=\"18\">Stake token</text>",
            "<text x=\"56\" y=\"176\" fill=\"#101114\" font-family=\"monospace\" font-size=\"24\">",
            LibString.escapeHTML(_stakeTokenSymbol),
            "</text>",
            "<text x=\"56\" y=\"226\" fill=\"#101114\" font-family=\"monospace\" font-size=\"18\">Amount</text>",
            "<text x=\"56\" y=\"254\" fill=\"#101114\" font-family=\"monospace\" font-size=\"22\">",
            LibString.toString(lock_.lockAmount()),
            "</text>",
            "<text x=\"56\" y=\"304\" fill=\"#101114\" font-family=\"monospace\" font-size=\"18\">Unlock time</text>",
            "<text x=\"56\" y=\"332\" fill=\"#101114\" font-family=\"monospace\" font-size=\"22\">",
            LibString.toString(lock_.lockEnd()),
            "</text>",
            "<text x=\"56\" y=\"390\" fill=\"#101114\" font-family=\"monospace\" font-size=\"14\">",
            LibString.escapeHTML(tokenAddress),
            "</text>",
            "</svg>"
        );
    }
}
