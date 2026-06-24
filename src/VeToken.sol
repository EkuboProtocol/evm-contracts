// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC721} from "solady/tokens/ERC721.sol";
import {Base64} from "solady/utils/Base64.sol";
import {DateTimeLib} from "solady/utils/DateTimeLib.sol";
import {LibString} from "solady/utils/LibString.sol";

import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {Ve33, VE33_MAX_STAKE_DURATION} from "./extensions/Ve33.sol";
import {ICore} from "./interfaces/ICore.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {Ve33Lib} from "./libraries/Ve33Lib.sol";
import {PoolKey} from "./types/poolKey.sol";
import {StakeId, createStakeId} from "./types/stakeId.sol";

/// @notice ERC721 representation over Ve33 stake accounting.
/// @dev The canonical stake is owned by this wrapper in Ve33. ERC721 ownership controls the wrapper.
contract VeToken is ERC721, BaseLocker, UsesCore {
    using FlashAccountantLib for *;
    using Ve33Lib for Ve33;

    uint256 private constant CALL_TYPE_STAKE = 0;
    uint256 private constant CALL_TYPE_UNSTAKE = 1;
    uint256 private constant CALL_TYPE_CLAIM_POOL_FEES = 2;

    /// @notice The Ve33 extension that owns the canonical stake, vote, and fee accounting.
    Ve33 public immutable ve33;

    /// @notice The token staked for voting power.
    address public immutable stakeToken;

    string private _name;
    string private _symbol;
    string private _stakeTokenName;
    string private _stakeTokenSymbol;
    uint8 private immutable _stakeTokenDecimals;

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
    constructor(ICore core, Ve33 _ve33) BaseLocker(core) UsesCore(core) {
        ve33 = _ve33;
        stakeToken = _ve33.stakeToken();
        _stakeTokenName = IERC20(stakeToken).name();
        _stakeTokenSymbol = IERC20(stakeToken).symbol();
        _stakeTokenDecimals = IERC20(stakeToken).decimals();
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
        string memory amountString = _formatTokenAmount(amount);
        string memory unlockDate = _formatDate(endTime);
        string memory description = string.concat(
            "Vote-escrowed ",
            _stakeTokenName,
            " stake. Amount: ",
            amountString,
            " ",
            _stakeTokenSymbol,
            ". Unlock date: ",
            unlockDate,
            ". Stake token: ",
            LibString.toHexStringChecksummed(stakeToken),
            "."
        );
        string memory image =
            string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(_tokenSvg(id, amountString, unlockDate))));

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
        amount = ve33.stakeAmount(address(this), stakeId(id));
    }

    /// @notice Creates a Ve33 stake and mints an ERC721 token that controls it.
    /// @dev The minted token id is used as the Ve33 stake salt. Stake token settlement happens in the Core lock.
    /// @param amount The amount of stake token to stake.
    /// @param end The stake end timestamp.
    /// @return veId The minted ERC721 token id.
    function createStake(uint128 amount, uint64 end) external returns (uint256 veId) {
        veId = nextVeId;
        unchecked {
            nextVeId = veId + 1;
        }
        _mintAndSetExtraDataUnchecked(msg.sender, veId, end);

        lock(abi.encode(CALL_TYPE_STAKE, msg.sender, stakeId(veId), amount));
    }

    /// @notice Adds stake token to an existing represented stake.
    /// @dev The caller must own or be approved for `veId`. Stake token settlement happens in the Core lock.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param amount The amount of stake token to add.
    function increaseStakeAmount(uint256 veId, uint128 amount) external authorizedForStake(veId) {
        lock(abi.encode(CALL_TYPE_STAKE, msg.sender, stakeId(veId), amount));
    }

    /// @notice Moves an existing represented stake to a later end timestamp.
    /// @dev The caller must own or be approved for `veId`. Extending clears votes in Ve33.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param end The new stake end timestamp.
    function extendStake(uint256 veId, uint64 end) external authorizedForStake(veId) {
        uint64 currentEnd = _stakeEndTime(veId);
        if (end <= currentEnd) revert InvalidStake();

        StakeId currentStakeId = createStakeId(_stakeSalt(veId), currentEnd);
        uint128 amount = ve33.stakeAmount(address(this), currentStakeId);
        ve33.moveStake(currentStakeId, createStakeId(_stakeSalt(veId), end), amount);
        _setExtraData(veId, end);
    }

    /// @notice Splits part of a represented stake into a newly minted ERC721 with the same end timestamp.
    /// @dev The caller must own or be approved for `veId`. The source stake keeps its vote with reduced weight.
    /// @param veId The ERC721 token id and source Ve33 stake salt.
    /// @param amount The amount of stake token to move into the new ERC721.
    /// @return splitVeId The newly minted ERC721 token id.
    function splitStake(uint256 veId, uint128 amount) external authorizedForStake(veId) returns (uint256 splitVeId) {
        uint64 end = _stakeEndTime(veId);
        StakeId fromStakeId = createStakeId(_stakeSalt(veId), end);
        uint128 currentAmount = ve33.stakeAmount(address(this), fromStakeId);
        if (amount == 0 || amount >= currentAmount) revert InvalidStake();

        splitVeId = nextVeId;
        unchecked {
            nextVeId = splitVeId + 1;
        }
        _mintAndSetExtraDataUnchecked(ownerOf(veId), splitVeId, end);

        ve33.splitStake(fromStakeId, createStakeId(_stakeSalt(splitVeId), end), amount);
    }

    /// @notice Merges one represented stake into another represented stake.
    /// @dev The caller must own or be approved for both tokens. The destination end becomes the greater end time.
    /// @param fromVeId The ERC721 token id whose entire stake is moved and then burned.
    /// @param toVeId The ERC721 token id receiving the stake.
    /// @return nextAmount Destination stake amount after the merge.
    function mergeStakes(uint256 fromVeId, uint256 toVeId)
        external
        authorizedForStake(fromVeId)
        authorizedForStake(toVeId)
        returns (uint128 nextAmount)
    {
        if (fromVeId == toVeId) revert InvalidStake();

        uint64 fromEnd = _stakeEndTime(fromVeId);
        uint64 toEnd = _stakeEndTime(toVeId);
        uint64 mergedEnd = fromEnd > toEnd ? fromEnd : toEnd;

        StakeId fromStakeId = createStakeId(_stakeSalt(fromVeId), fromEnd);
        StakeId currentToStakeId = createStakeId(_stakeSalt(toVeId), toEnd);
        StakeId mergedToStakeId = createStakeId(_stakeSalt(toVeId), mergedEnd);
        uint128 amount = ve33.stakeAmount(address(this), fromStakeId);
        if (amount == 0) return ve33.stakeAmount(address(this), currentToStakeId);

        if (toEnd != mergedEnd) {
            uint128 toAmount = ve33.stakeAmount(address(this), currentToStakeId);
            if (toAmount != 0) ve33.moveStake(currentToStakeId, mergedToStakeId, toAmount);
            _setExtraData(toVeId, mergedEnd);
        }

        nextAmount = ve33.moveStake(fromStakeId, mergedToStakeId, amount);

        _burn(fromVeId);
        _setExtraData(fromVeId, 0);
    }

    /// @notice Unstakes an expired represented stake and burns its ERC721 token.
    /// @dev The caller must own or be approved for `veId`; unstaked tokens are withdrawn to the current ERC721 owner.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    function withdrawStake(uint256 veId) external authorizedForStake(veId) {
        address owner = ownerOf(veId);
        lock(abi.encode(CALL_TYPE_UNSTAKE, stakeId(veId), owner));

        _burn(veId);
        _setExtraData(veId, 0);
    }

    /// @notice Returns the current voting power of a represented stake.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @return The stake voting power at the current timestamp.
    function votingPower(uint256 veId) public view returns (uint256) {
        return ve33.votingPower(address(this), stakeId(veId));
    }

    /// @notice Returns the Ve33 stake id represented by an ERC721 token.
    /// @dev The Ve33 stake owner is always this contract, and the salt is `bytes24(veId)`.
    /// @param veId The ERC721 token id.
    /// @return The canonical Ve33 stake id.
    function stakeId(uint256 veId) public view returns (StakeId) {
        return createStakeId(_stakeSalt(veId), _stakeEndTime(veId));
    }

    /// @notice Votes a represented stake on one pool with an explicit swap fee.
    /// @dev The caller must own or be approved for `veId`.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param poolKey The pool to vote on.
    /// @param swapFee The selected swap fee for the pool.
    function vote(uint256 veId, PoolKey calldata poolKey, uint64 swapFee) external authorizedForStake(veId) {
        ve33.vote(stakeId(veId), poolKey, swapFee);
    }

    /// @notice Clears a represented stake's active pool vote.
    /// @dev The caller must own or be approved for `veId`.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    function clearVote(uint256 veId) external authorizedForStake(veId) {
        ve33.clearVote(stakeId(veId));
    }

    /// @notice Claims pool fees earned by a represented stake to its current ERC721 owner.
    /// @dev Permissionless; the recipient is always `ownerOf(veId)`.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param poolKey The pool whose voter fees should be claimed.
    /// @return amount0 The amount of token0 withdrawn to the owner.
    /// @return amount1 The amount of token1 withdrawn to the owner.
    function claimPoolFees(uint256 veId, PoolKey calldata poolKey) external returns (uint128 amount0, uint128 amount1) {
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
            (, address owner, StakeId id, uint128 amount) = abi.decode(data, (uint256, address, StakeId, uint128));
            uint128 nextAmount = Ve33Lib.stake(CORE, ve33, id, amount);
            result = abi.encode(nextAmount);
            if (amount != 0) ACCOUNTANT.payFrom(owner, stakeToken, amount);
        } else if (callType == CALL_TYPE_UNSTAKE) {
            (, StakeId id, address recipient) = abi.decode(data, (uint256, StakeId, address));
            uint128 unstaked = Ve33Lib.unstake(CORE, ve33, id);
            result = abi.encode(unstaked);
            ACCOUNTANT.withdraw(stakeToken, recipient, unstaked);
        } else if (callType == CALL_TYPE_CLAIM_POOL_FEES) {
            (, uint256 veId, address recipient, PoolKey memory poolKey) =
                abi.decode(data, (uint256, uint256, address, PoolKey));
            (uint128 amount0, uint128 amount1) = Ve33Lib.claimPoolFees(CORE, ve33, stakeId(veId), poolKey);
            result = abi.encode(amount0, amount1);
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

    /// @notice Converts an ERC721 id into the stake salt used by Ve33.
    function _stakeSalt(uint256 veId) private pure returns (bytes24 salt) {
        if (veId > type(uint192).max) revert InvalidStake();
        assembly ("memory-safe") {
            salt := shl(64, veId)
        }
    }

    /// @notice Builds the SVG image embedded in ERC721 metadata.
    /// @param id The ERC721 token id.
    /// @param amountString The current staked token amount formatted with stake-token decimals.
    /// @param unlockDate The stake end timestamp formatted as an English date.
    /// @return The raw SVG string.
    function _tokenSvg(uint256 id, string memory amountString, string memory unlockDate)
        private
        view
        returns (string memory)
    {
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
            LibString.escapeHTML(amountString),
            "</text>",
            "<text x=\"56\" y=\"304\" fill=\"#101114\" font-family=\"monospace\" font-size=\"18\">Unlock date</text>",
            "<text x=\"56\" y=\"332\" fill=\"#101114\" font-family=\"monospace\" font-size=\"22\">",
            LibString.escapeHTML(unlockDate),
            "</text>",
            "<text x=\"56\" y=\"390\" fill=\"#101114\" font-family=\"monospace\" font-size=\"14\">",
            LibString.escapeHTML(tokenAddress),
            "</text>",
            "</svg>"
        );
    }

    /// @notice Formats a stake-token amount using token decimals, trimming trailing fractional zeros.
    /// @param amount Raw stake-token amount.
    /// @return Decimal-adjusted amount string.
    function _formatTokenAmount(uint256 amount) private view returns (string memory) {
        uint256 decimals = _stakeTokenDecimals;
        string memory digitsString = LibString.toString(amount);
        if (decimals == 0) return digitsString;

        bytes memory digits = bytes(digitsString);
        if (amount == 0) return "0";

        if (digits.length > decimals) {
            uint256 wholeLength = digits.length - decimals;
            uint256 wholeFractionalLength = decimals;
            while (wholeFractionalLength != 0 && digits[wholeLength + wholeFractionalLength - 1] == bytes1("0")) {
                unchecked {
                    --wholeFractionalLength;
                }
            }
            if (wholeFractionalLength == 0) return LibString.slice(digitsString, 0, wholeLength);

            bytes memory wholeResult = new bytes(wholeLength + 1 + wholeFractionalLength);
            for (uint256 i; i < wholeLength;) {
                wholeResult[i] = digits[i];
                unchecked {
                    ++i;
                }
            }
            wholeResult[wholeLength] = bytes1(".");
            for (uint256 i; i < wholeFractionalLength;) {
                wholeResult[wholeLength + 1 + i] = digits[wholeLength + i];
                unchecked {
                    ++i;
                }
            }
            return string(wholeResult);
        }

        uint256 leadingZeros = decimals - digits.length;
        uint256 fractionalLength = digits.length;
        while (fractionalLength != 0 && digits[fractionalLength - 1] == bytes1("0")) {
            unchecked {
                --fractionalLength;
            }
        }
        bytes memory result = new bytes(2 + leadingZeros + fractionalLength);
        result[0] = bytes1("0");
        result[1] = bytes1(".");
        for (uint256 i; i < leadingZeros;) {
            result[2 + i] = bytes1("0");
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < fractionalLength;) {
            result[2 + leadingZeros + i] = digits[i];
            unchecked {
                ++i;
            }
        }
        return string(result);
    }

    /// @notice Formats a timestamp as an English UTC date.
    /// @param timestamp Unix timestamp.
    /// @return Date string like "Jan 1, 2030".
    function _formatDate(uint256 timestamp) private pure returns (string memory) {
        (uint256 year, uint256 month, uint256 day) = DateTimeLib.timestampToDate(timestamp);
        return string.concat(_monthName(month), " ", LibString.toString(day), ", ", LibString.toString(year));
    }

    /// @notice Returns the English abbreviated month name for a 1-indexed month.
    /// @param month Month number.
    /// @return Month abbreviation.
    function _monthName(uint256 month) private pure returns (string memory) {
        if (month == 1) return "Jan";
        if (month == 2) return "Feb";
        if (month == 3) return "Mar";
        if (month == 4) return "Apr";
        if (month == 5) return "May";
        if (month == 6) return "Jun";
        if (month == 7) return "Jul";
        if (month == 8) return "Aug";
        if (month == 9) return "Sep";
        if (month == 10) return "Oct";
        if (month == 11) return "Nov";
        return "Dec";
    }
}
