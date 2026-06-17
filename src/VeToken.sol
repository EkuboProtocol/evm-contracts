// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

import {BaseLocker} from "./base/BaseLocker.sol";
import {
    Ve33,
    VE33_CLAIM_POOL_FEES,
    VE33_MAX_STAKE_DURATION,
    VE33_MOVE_STAKE,
    VE33_STAKE,
    VE33_UNSTAKE
} from "./extensions/Ve33.sol";
import {ICore} from "./interfaces/ICore.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {Ve33Lib} from "./libraries/Ve33Lib.sol";
import {defaultFeeForStableswapAmplification, defaultFeeForTickSpacing} from "./math/tickSpacingFee.sol";
import {PoolKey} from "./types/poolKey.sol";

/// @notice ERC721 representation over Ve33 stake accounting.
/// @dev The canonical stake is owned by this wrapper in Ve33. ERC721 ownership controls the wrapper.
contract VeToken is ERC721, BaseLocker {
    using FlashAccountantLib for *;
    using Ve33Lib for Ve33;

    uint256 private constant CALL_TYPE_STAKE = 0;
    uint256 private constant CALL_TYPE_UNSTAKE = 1;
    uint256 private constant CALL_TYPE_MOVE_STAKE = 2;
    uint256 private constant CALL_TYPE_CLAIM_POOL_FEES = 3;

    /// @notice The Ve33 extension that owns the canonical stake, vote, and fee accounting.
    Ve33 public immutable ve33;

    /// @notice The token staked for voting power.
    address public immutable stakeToken;

    string private _name;
    string private _symbol;
    string private _stakeTokenName;
    string private _stakeTokenSymbol;

    /// @notice The next ERC721 token id to mint.
    /// @dev Token ids start at 1 and are used directly as Ve33 stake salts.
    uint256 public nextVeId = 1;

    /// @notice Thrown when a stake update is invalid for this wrapper.
    error InvalidStake();

    /// @notice Thrown when a caller is not the ERC721 owner or approved account for a represented stake.
    /// @param caller The unauthorized caller.
    /// @param id The ERC721 token id.
    error NotAuthorizedForToken(address caller, uint256 id);

    /// @notice Creates the ERC721 stake wrapper.
    /// @param core The Ekubo Core contract used for lock and token settlement.
    /// @param _ve33 The Ve33 extension containing canonical vote-escrow accounting.
    constructor(ICore core, Ve33 _ve33) BaseLocker(core) {
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
    ///      The image is an embedded SVG generated from the current Ve33 stake amount, stake end, and stake token.
    function tokenURI(uint256 id) public view override returns (string memory) {
        (uint128 amount, uint64 endTime) = stakes(id);
        string memory idString = LibString.toString(id);
        string memory tokenName = string.concat(_symbol, " #", idString);
        string memory description = string.concat(
            "Vote-escrowed ",
            _stakeTokenName,
            " stake. Amount: ",
            LibString.toString(amount),
            " ",
            _stakeTokenSymbol,
            ". Unlock time: ",
            LibString.toString(endTime),
            ". Stake token: ",
            LibString.toHexStringChecksummed(stakeToken),
            "."
        );
        string memory image =
            string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(_tokenSvg(id, amount, endTime))));

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

    /// @notice Returns the maximum stake duration accepted by Ve33.
    /// @return The maximum stake duration in seconds.
    function MAX_STAKE_DURATION() external pure returns (uint256) {
        return VE33_MAX_STAKE_DURATION;
    }

    /// @notice Returns whether `account` may manage the represented stake.
    /// @dev Uses Solady ERC721 ownership and approval checks. Reverts if `id` does not exist.
    /// @param account The account to check.
    /// @param id The ERC721 token id.
    /// @return True if the account owns the token or is approved for it.
    function isAuthorizedForNft(address account, uint256 id) public view returns (bool) {
        return _isApprovedOrOwner(account, id);
    }

    /// @notice Requires the caller to own or be approved for a represented stake.
    /// @param id The ERC721 token id.
    modifier authorizedForStake(uint256 id) {
        if (!isAuthorizedForNft(msg.sender, id)) revert NotAuthorizedForToken(msg.sender, id);
        _;
    }

    /// @notice Returns the current represented stake state.
    /// @dev The stake end is stored in ERC721 extraData. The amount is fetched from Ve33 exposed storage.
    /// @param id The ERC721 token id, also used as the Ve33 stake salt.
    /// @return amount The current staked token amount.
    /// @return endTime The stake end timestamp.
    function stakes(uint256 id) public view returns (uint128 amount, uint64 endTime) {
        endTime = _stakeEndTime(id);
        amount = ve33.stakeAmount(address(this), bytes32(id), endTime);
    }

    /// @notice Creates a Ve33 stake and mints an ERC721 token that controls it.
    /// @dev The minted token id is used as the Ve33 stake salt. Stake token settlement happens in the Core lock.
    /// @param amount The amount of stake token to stake.
    /// @param end The stake end timestamp.
    /// @return veId The minted ERC721 token id.
    function createStake(uint128 amount, uint64 end) external returns (uint256 veId) {
        veId = nextVeId++;
        _mintAndSetExtraDataUnchecked(msg.sender, veId, end);

        lock(abi.encode(CALL_TYPE_STAKE, msg.sender, bytes32(veId), end, amount));
    }

    /// @notice Adds stake token to an existing represented stake.
    /// @dev The caller must own or be approved for `veId`. Stake token settlement happens in the Core lock.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param amount The amount of stake token to add.
    function increaseStakeAmount(uint256 veId, uint128 amount) external authorizedForStake(veId) {
        lock(abi.encode(CALL_TYPE_STAKE, msg.sender, bytes32(veId), _stakeEndTime(veId), amount));
    }

    /// @notice Moves an existing represented stake to a later end timestamp.
    /// @dev The caller must own or be approved for `veId`. Extending clears votes in Ve33.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param end The new stake end timestamp.
    function extendStake(uint256 veId, uint64 end) external authorizedForStake(veId) {
        uint64 currentEnd = _stakeEndTime(veId);
        if (end <= currentEnd) revert InvalidStake();

        bytes32 salt = bytes32(veId);
        uint128 amount = ve33.stakeAmount(address(this), salt, currentEnd);
        lock(abi.encode(CALL_TYPE_MOVE_STAKE, salt, currentEnd, salt, end, amount));
        _setExtraData(veId, end);
    }

    /// @notice Unstakes an expired represented stake and burns its ERC721 token.
    /// @dev The caller must own or be approved for `veId`; unstaked tokens are withdrawn to the current ERC721 owner.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    function withdrawStake(uint256 veId) external authorizedForStake(veId) {
        address owner = ownerOf(veId);
        bytes32 salt = bytes32(veId);
        uint64 endTime = _stakeEndTime(veId);
        uint128 amount = ve33.stakeAmount(address(this), salt, endTime);
        lock(abi.encode(CALL_TYPE_UNSTAKE, salt, endTime, amount, owner));

        _burn(veId);
        _setExtraData(veId, 0);
    }

    /// @notice Returns the current voting power of a represented stake.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @return The stake voting power at the current timestamp.
    function votingPower(uint256 veId) public view returns (uint256) {
        return ve33.votingPower(stakeKey(veId));
    }

    /// @notice Returns the Ve33 stake key represented by an ERC721 token.
    /// @dev The Ve33 stake owner is always this contract, and the salt is `bytes32(veId)`.
    /// @param veId The ERC721 token id.
    /// @return The canonical Ve33 stake key.
    function stakeKey(uint256 veId) public view returns (Ve33.StakeKey memory) {
        return Ve33.StakeKey({owner: address(this), salt: bytes32(veId), endTime: _stakeEndTime(veId)});
    }

    /// @notice Votes a represented stake on pools with explicit swap fees.
    /// @dev The caller must own or be approved for `veId`.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param poolKeys The pools to vote on.
    /// @param weights The vote weights for each pool.
    /// @param swapFees The selected swap fee for each pool.
    function vote(uint256 veId, PoolKey[] calldata poolKeys, uint256[] calldata weights, uint64[] calldata swapFees)
        external
        authorizedForStake(veId)
    {
        ve33.vote(stakeKey(veId), poolKeys, weights, swapFees);
    }

    /// @notice Votes a represented stake on pools using default fees derived from each pool config.
    /// @dev The caller must own or be approved for `veId`.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param poolKeys The pools to vote on.
    /// @param weights The vote weights for each pool.
    function voteWithDefaultFees(uint256 veId, PoolKey[] calldata poolKeys, uint256[] calldata weights)
        external
        authorizedForStake(veId)
    {
        uint64[] memory swapFees = new uint64[](poolKeys.length);
        for (uint256 i = 0; i < poolKeys.length; i++) {
            swapFees[i] = poolKeys[i].config.isStableswap()
                ? defaultFeeForStableswapAmplification(poolKeys[i].config.stableswapAmplification())
                : defaultFeeForTickSpacing(poolKeys[i].config.concentratedTickSpacing());
        }
        ve33.vote(stakeKey(veId), poolKeys, weights, swapFees);
    }

    /// @notice Claims pool fees earned by a represented stake to its current ERC721 owner.
    /// @dev Permissionless; the recipient is always `ownerOf(veId)`.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param poolKey The pool whose voter fees should be claimed.
    /// @return amount0 The amount of token0 withdrawn to the owner.
    /// @return amount1 The amount of token1 withdrawn to the owner.
    function claimPoolFees(uint256 veId, PoolKey memory poolKey) external returns (uint128 amount0, uint128 amount1) {
        address owner = ownerOf(veId);
        (amount0, amount1) =
            abi.decode(lock(abi.encode(CALL_TYPE_CLAIM_POOL_FEES, veId, owner, poolKey)), (uint128, uint128));
    }

    /// @notice Settles token-moving wrapper actions inside the Core lock.
    /// @dev Ve33 only updates saved balances. This handler pays stake on stake, withdraws stake on unstake,
    ///      and withdraws claimed pool fees to the current ERC721 owner selected before forwarding.
    /// @param data Encoded wrapper call type and arguments.
    /// @return result Encoded return data from the underlying Ve33 forward call.
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_STAKE) {
            (, address owner, bytes32 salt, uint64 endTime, uint128 amount) =
                abi.decode(data, (uint256, address, bytes32, uint64, uint128));
            result = ACCOUNTANT.forward(address(ve33), abi.encode(VE33_STAKE, salt, endTime, amount));
            uint128 staked = abi.decode(result, (uint128));
            if (staked != 0) ACCOUNTANT.payFrom(owner, stakeToken, staked);
        } else if (callType == CALL_TYPE_UNSTAKE) {
            (, bytes32 salt, uint64 endTime, uint128 amount, address recipient) =
                abi.decode(data, (uint256, bytes32, uint64, uint128, address));
            result = ACCOUNTANT.forward(address(ve33), abi.encode(VE33_UNSTAKE, salt, endTime, amount));
            uint128 unstaked = abi.decode(result, (uint128));
            if (unstaked != 0) ACCOUNTANT.withdraw(stakeToken, recipient, unstaked);
        } else if (callType == CALL_TYPE_MOVE_STAKE) {
            (, bytes32 fromSalt, uint64 fromEndTime, bytes32 toSalt, uint64 toEndTime, uint128 amount) =
                abi.decode(data, (uint256, bytes32, uint64, bytes32, uint64, uint128));
            result = ACCOUNTANT.forward(
                address(ve33), abi.encode(VE33_MOVE_STAKE, fromSalt, fromEndTime, toSalt, toEndTime, amount)
            );
        } else if (callType == CALL_TYPE_CLAIM_POOL_FEES) {
            (, uint256 veId, address recipient, PoolKey memory poolKey) =
                abi.decode(data, (uint256, uint256, address, PoolKey));
            result = ACCOUNTANT.forward(address(ve33), abi.encode(VE33_CLAIM_POOL_FEES, stakeKey(veId), poolKey));
            (uint128 amount0, uint128 amount1) = abi.decode(result, (uint128, uint128));
            ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, recipient, amount0, amount1);
        } else {
            revert();
        }
    }

    /// @notice Returns the stake end timestamp stored in ERC721 extraData.
    /// @param veId The ERC721 token id.
    /// @return The stake end timestamp.
    function _stakeEndTime(uint256 veId) private view returns (uint64) {
        if (!_exists(veId)) revert TokenDoesNotExist();
        return uint64(_getExtraData(veId));
    }

    /// @notice Builds the SVG image embedded in ERC721 metadata.
    /// @param id The ERC721 token id.
    /// @param amount The current staked token amount.
    /// @param endTime The stake end timestamp.
    /// @return The raw SVG string.
    function _tokenSvg(uint256 id, uint128 amount, uint64 endTime) private view returns (string memory) {
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
            LibString.toString(amount),
            "</text>",
            "<text x=\"56\" y=\"304\" fill=\"#101114\" font-family=\"monospace\" font-size=\"18\">Unlock time</text>",
            "<text x=\"56\" y=\"332\" fill=\"#101114\" font-family=\"monospace\" font-size=\"22\">",
            LibString.toString(endTime),
            "</text>",
            "<text x=\"56\" y=\"390\" fill=\"#101114\" font-family=\"monospace\" font-size=\"14\">",
            LibString.escapeHTML(tokenAddress),
            "</text>",
            "</svg>"
        );
    }
}
