// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ERC721} from "solady/tokens/ERC721.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {BaseLocker} from "./base/BaseLocker.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {Ve33} from "./extensions/Ve33.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IVe33, VE33_MAX_STAKE_DURATION} from "./interfaces/extensions/IVe33.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {Ve33Lib} from "./libraries/Ve33Lib.sol";
import {VeTokenMetadata} from "./libraries/VeTokenMetadata.sol";
import {isPowerOfFour} from "./math/isPowerOfFour.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PoolState} from "./types/poolState.sol";
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {StakeId, createStakeId} from "./types/stakeId.sol";

/// @notice ERC721 representation over Ve33 stake accounting.
/// @dev The canonical stake is owned by this wrapper in Ve33. ERC721 ownership controls the wrapper.
contract VeToken is ERC721, PayableMulticallable, BaseLocker, UsesCore {
    using CoreLib for *;
    using FlashAccountantLib for *;
    using Ve33Lib for Ve33;

    uint256 private constant CALL_TYPE_STAKE = 0;
    uint256 private constant CALL_TYPE_UNSTAKE = 1;
    uint256 private constant CALL_TYPE_CLAIM_POOL_FEES = 2;

    /// @notice The Ve33 extension that owns the canonical stake, vote, and fee accounting.
    Ve33 public immutable ve33;

    /// @notice The token staked for voting power.
    address public immutable stakeToken;

    bytes32 private immutable _name;
    bytes32 private immutable _symbol;
    bytes32 private immutable _stakeTokenName;
    bytes32 private immutable _stakeTokenSymbol;
    uint8 private immutable _stakeTokenDecimals;

    /// @notice Thrown when a token id cannot be represented as a Ve33 stake salt.
    /// @param veId The ERC721 token id.
    error StakeSaltOverflow(uint256 veId);

    /// @notice Thrown when a VeToken operation cannot be represented as a no-op with zero stake.
    error InvalidStakeAmount();

    /// @notice Thrown when splitting an amount that would leave no source stake.
    error SplitAmountMustBeLessThanStakeAmount();

    /// @notice Thrown when a caller is not the ERC721 owner or approved account for a represented stake.
    /// @param caller The unauthorized caller.
    /// @param id The ERC721 token id.
    error NotAuthorizedForToken(address caller, uint256 id);

    /// @notice Thrown when a constructor string cannot be packed into one bytes32 word.
    error PackedStringTooLong();

    /// @notice Thrown when a duration-based stake end cannot fit in uint64.
    error StakeEndOverflow();

    /// @notice Creates the ERC721 stake wrapper.
    /// @param core The Ekubo Core contract used for lock and token settlement.
    /// @param _ve33 The Ve33 extension containing canonical vote-escrow accounting.
    /// @param name_ The ERC721 collection name (e.g. "Vote Escrow ETH").
    /// @param symbol_ The ERC721 collection symbol (e.g. "veETH").
    /// @param stakeTokenName_ The display name of the staked token used in token metadata.
    /// @param stakeTokenSymbol_ The display symbol of the staked token used in token metadata.
    /// @param stakeTokenDecimals_ The decimals of the staked token used for amount formatting in metadata.
    constructor(
        ICore core,
        Ve33 _ve33,
        string memory name_,
        string memory symbol_,
        string memory stakeTokenName_,
        string memory stakeTokenSymbol_,
        uint8 stakeTokenDecimals_
    ) BaseLocker(core) UsesCore(core) {
        ve33 = _ve33;
        stakeToken = _ve33.stakeToken();
        _name = _packConstructorString(name_);
        _symbol = _packConstructorString(symbol_);
        _stakeTokenName = _packConstructorString(stakeTokenName_);
        _stakeTokenSymbol = _packConstructorString(stakeTokenSymbol_);
        _stakeTokenDecimals = stakeTokenDecimals_;
    }

    receive() external payable {}

    /// @inheritdoc ERC721
    function name() public view override returns (string memory) {
        return LibString.unpackOne(_name);
    }

    /// @inheritdoc ERC721
    function symbol() public view override returns (string memory) {
        return LibString.unpackOne(_symbol);
    }

    /// @inheritdoc ERC721
    /// @dev Returns a base64 JSON data URI with `name`, `description`, and `image` fields.
    ///      The image is an embedded SVG generated from the current Ve33 stake amount, stake end, and stake token.
    function tokenURI(uint256 id) public view override returns (string memory) {
        (uint128 amount, uint64 endTime) = stakes(id);
        return VeTokenMetadata.tokenURI(
            VeTokenMetadata.Params({
                id: id,
                amount: amount,
                unlockTime: endTime,
                veSymbol: LibString.unpackOne(_symbol),
                stakeTokenName: LibString.unpackOne(_stakeTokenName),
                stakeTokenSymbol: LibString.unpackOne(_stakeTokenSymbol),
                stakeTokenDecimals: _stakeTokenDecimals,
                stakeToken: stakeToken
            })
        );
    }

    function _packConstructorString(string memory value) private pure returns (bytes32 packed) {
        packed = LibString.packOne(value);
        if (packed == bytes32(0) && bytes(value).length != 0) revert PackedStringTooLong();
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

    /// @notice Converts a minter address and salt to a uint192 token id.
    /// @dev Mirrors the base nonfungible token salt pattern, truncated to fit in the Ve33 stake salt.
    /// @param minter The address creating the token id.
    /// @param salt Caller-provided salt for deterministic ID generation.
    /// @return veId The resulting ERC721 token id and Ve33 stake salt.
    function saltToId(address minter, bytes32 salt) public view returns (uint192 veId) {
        assembly ("memory-safe") {
            let free := mload(0x40)
            mstore(free, minter)
            mstore(add(free, 32), salt)
            mstore(add(free, 64), chainid())
            mstore(add(free, 96), address())

            veId := and(keccak256(free, 128), 0xffffffffffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// @notice Creates a Ve33 stake and mints an ERC721 token that controls it.
    /// @dev A pseudorandom uint192 token id is used as the Ve33 stake salt. Stake token settlement happens in the
    ///      Core lock.
    /// @param amount The amount of stake token to stake.
    /// @param end The stake end timestamp.
    /// @return veId The minted ERC721 token id.
    function createStake(uint128 amount, uint64 end) public payable returns (uint192 veId) {
        veId = createStake(amount, end, _randomSalt());
    }

    /// @notice Creates a Ve33 stake with an explicit salt and mints an ERC721 token that controls it.
    /// @dev The token id is `saltToId(msg.sender, salt)`, which is also used as the Ve33 stake salt. Stake token
    ///      settlement happens in the Core lock.
    /// @param amount The amount of stake token to stake.
    /// @param end The stake end timestamp.
    /// @param salt The salt for deterministic ID generation.
    /// @return veId The minted ERC721 token id.
    function createStake(uint128 amount, uint64 end, bytes32 salt) public payable returns (uint192 veId) {
        if (amount == 0) revert InvalidStakeAmount();

        veId = saltToId(msg.sender, salt);
        _mintAndSetExtraData(msg.sender, veId, end);

        lock(abi.encode(CALL_TYPE_STAKE, msg.sender, stakeId(veId), amount));
    }

    /// @notice Creates a Ve33 stake ending `duration` seconds from now and mints an ERC721 token that controls it.
    /// @dev A pseudorandom uint192 token id is used as the Ve33 stake salt. Stake token settlement happens in the
    ///      Core lock.
    /// @param amount The amount of stake token to stake.
    /// @param duration The stake duration in seconds.
    /// @return veId The minted ERC721 token id.
    function createStakeForDuration(uint128 amount, uint32 duration) external payable returns (uint192 veId) {
        veId = createStake(amount, _stakeEndFromDuration(duration));
    }

    /// @notice Creates a Ve33 stake with an explicit salt ending `duration` seconds from now.
    /// @dev The token id is `saltToId(msg.sender, salt)`, which is also used as the Ve33 stake salt.
    /// @param amount The amount of stake token to stake.
    /// @param duration The stake duration in seconds.
    /// @param salt The salt for deterministic ID generation.
    /// @return veId The minted ERC721 token id.
    function createStakeForDuration(uint128 amount, uint32 duration, bytes32 salt)
        external
        payable
        returns (uint192 veId)
    {
        veId = createStake(amount, _stakeEndFromDuration(duration), salt);
    }

    /// @notice Creates a Ve33 stake ending at the maximum duration from now.
    /// @dev A pseudorandom uint192 token id is used as the Ve33 stake salt. Stake token settlement happens in the
    ///      Core lock.
    /// @param amount The amount of stake token to stake.
    /// @return veId The minted ERC721 token id.
    function createStakeMaxDuration(uint128 amount) external payable returns (uint192 veId) {
        veId = createStake(amount, _maxStakeEnd());
    }

    /// @notice Creates a Ve33 stake with an explicit salt ending at the maximum duration from now.
    /// @dev The token id is `saltToId(msg.sender, salt)`, which is also used as the Ve33 stake salt.
    /// @param amount The amount of stake token to stake.
    /// @param salt The salt for deterministic ID generation.
    /// @return veId The minted ERC721 token id.
    function createStakeMaxDuration(uint128 amount, bytes32 salt) external payable returns (uint192 veId) {
        veId = createStake(amount, _maxStakeEnd(), salt);
    }

    /// @notice Creates a Ve33 stake with an explicit salt and immediately votes it on one pool.
    /// @dev Useful for multicalls and deterministic integrations that need to know the new ve id before voting.
    /// @param amount The amount of stake token to stake.
    /// @param end The stake end timestamp.
    /// @param salt The salt for deterministic ID generation.
    /// @param poolKey The pool to vote on.
    /// @param swapFee The selected swap fee for the pool.
    /// @return veId The minted ERC721 token id.
    function createStakeAndVote(uint128 amount, uint64 end, bytes32 salt, PoolKey calldata poolKey, uint64 swapFee)
        external
        payable
        returns (uint192 veId)
    {
        veId = createStake(amount, end, salt);
        ve33.vote(stakeId(veId), poolKey, swapFee);
    }

    /// @notice Adds stake token to an existing represented stake.
    /// @dev The caller must own or be approved for `veId`. Stake token settlement happens in the Core lock.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param amount The amount of stake token to add.
    function increaseStakeAmount(uint256 veId, uint128 amount) external payable authorizedForStake(veId) {
        if (amount == 0) return;

        lock(abi.encode(CALL_TYPE_STAKE, msg.sender, stakeId(veId), amount));
    }

    /// @notice Moves an existing represented stake to a later end timestamp.
    /// @dev The caller must own or be approved for `veId`. Extending clears votes in Ve33.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param end The new stake end timestamp.
    function extendStake(uint256 veId, uint64 end) public payable authorizedForStake(veId) {
        _extendStake(veId, end);
    }

    /// @notice Moves an existing represented stake to end `duration` seconds from now.
    /// @dev The caller must own or be approved for `veId`. Extending clears votes in Ve33.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param duration The new stake duration in seconds.
    function extendStakeForDuration(uint256 veId, uint32 duration) external payable {
        extendStake(veId, _stakeEndFromDuration(duration));
    }

    /// @notice Moves an existing represented stake to the maximum duration from now.
    /// @dev The caller must own or be approved for `veId`. Extending clears votes in Ve33.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    function extendStakeMaxDuration(uint256 veId) external payable {
        extendStake(veId, _maxStakeEnd());
    }

    /// @notice Claims pending voter fees, then moves a represented stake to a later end timestamp.
    /// @dev Useful before a vote-clearing extension because pending fees are discarded when votes are cleared.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param end The new stake end timestamp.
    /// @param poolKey The currently voted pool whose fees should be claimed before extending.
    /// @param recipient Account receiving the claimed fees.
    /// @return amount0 The amount of token0 withdrawn to `recipient`.
    /// @return amount1 The amount of token1 withdrawn to `recipient`.
    function claimPoolFeesAndExtendStake(uint256 veId, uint64 end, PoolKey calldata poolKey, address recipient)
        public
        payable
        authorizedForStake(veId)
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = _claimPoolFees(veId, poolKey, recipient);
        _extendStake(veId, end);
    }

    /// @notice Claims pending voter fees, then moves a represented stake to end `duration` seconds from now.
    /// @dev Useful before a vote-clearing extension because pending fees are discarded when votes are cleared.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param duration The new stake duration in seconds.
    /// @param poolKey The currently voted pool whose fees should be claimed before extending.
    /// @param recipient Account receiving the claimed fees.
    /// @return amount0 The amount of token0 withdrawn to `recipient`.
    /// @return amount1 The amount of token1 withdrawn to `recipient`.
    function claimPoolFeesAndExtendStakeForDuration(
        uint256 veId,
        uint32 duration,
        PoolKey calldata poolKey,
        address recipient
    ) external payable returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = claimPoolFeesAndExtendStake(veId, _stakeEndFromDuration(duration), poolKey, recipient);
    }

    /// @notice Claims pending voter fees, then moves a represented stake to the maximum duration from now.
    /// @dev Useful before a vote-clearing extension because pending fees are discarded when votes are cleared.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param poolKey The currently voted pool whose fees should be claimed before extending.
    /// @param recipient Account receiving the claimed fees.
    /// @return amount0 The amount of token0 withdrawn to `recipient`.
    /// @return amount1 The amount of token1 withdrawn to `recipient`.
    function claimPoolFeesAndExtendStakeMaxDuration(uint256 veId, PoolKey calldata poolKey, address recipient)
        external
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = claimPoolFeesAndExtendStake(veId, _maxStakeEnd(), poolKey, recipient);
    }

    /// @notice Claims pending voter fees to the caller, then moves a represented stake to a later end timestamp.
    function claimPoolFeesAndExtendStakeToSelf(uint256 veId, uint64 end, PoolKey calldata poolKey)
        public
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        if (!isAuthorizedForNft(msg.sender, veId)) revert NotAuthorizedForToken(msg.sender, veId);
        (amount0, amount1) = _claimPoolFees(veId, poolKey, msg.sender);
        _extendStake(veId, end);
    }

    /// @notice Claims pending voter fees to the caller, then moves a represented stake to end `duration` seconds from now.
    function claimPoolFeesAndExtendStakeToSelfForDuration(uint256 veId, uint32 duration, PoolKey calldata poolKey)
        external
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = claimPoolFeesAndExtendStakeToSelf(veId, _stakeEndFromDuration(duration), poolKey);
    }

    /// @notice Claims pending voter fees to the caller, then moves a represented stake to the maximum duration from now.
    function claimPoolFeesAndExtendStakeToSelfMaxDuration(uint256 veId, PoolKey calldata poolKey)
        external
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = claimPoolFeesAndExtendStakeToSelf(veId, _maxStakeEnd(), poolKey);
    }

    /// @notice Splits part of a represented stake into a newly minted ERC721 with the same end timestamp.
    /// @dev The caller must own or be approved for `veId`. The source stake keeps its vote with reduced weight.
    /// @param veId The ERC721 token id and source Ve33 stake salt.
    /// @param amount The amount of stake token to move into the new ERC721.
    /// @return splitVeId The newly minted ERC721 token id.
    function splitStake(uint256 veId, uint128 amount)
        external
        payable
        authorizedForStake(veId)
        returns (uint192 splitVeId)
    {
        splitVeId = _splitStake(veId, amount, _randomSalt());
    }

    /// @notice Splits part of a represented stake into a newly minted ERC721 with an explicit salt.
    /// @dev The new token id is `saltToId(msg.sender, salt)`, which is also used as the new Ve33 stake salt.
    /// @param veId The ERC721 token id and source Ve33 stake salt.
    /// @param amount The amount of stake token to move into the new ERC721.
    /// @param salt The salt for deterministic ID generation.
    /// @return splitVeId The newly minted ERC721 token id.
    function splitStake(uint256 veId, uint128 amount, bytes32 salt)
        external
        payable
        authorizedForStake(veId)
        returns (uint192 splitVeId)
    {
        splitVeId = _splitStake(veId, amount, salt);
    }

    function _splitStake(uint256 veId, uint128 amount, bytes32 salt) private returns (uint192 splitVeId) {
        if (amount == 0) revert InvalidStakeAmount();

        uint64 end = _stakeEndTime(veId);
        StakeId fromStakeId = createStakeId(_stakeSalt(veId), end);
        uint128 currentAmount = ve33.stakeAmount(address(this), fromStakeId);
        if (amount >= currentAmount) revert SplitAmountMustBeLessThanStakeAmount();

        splitVeId = saltToId(msg.sender, salt);
        _mintAndSetExtraData(ownerOf(veId), splitVeId, end);

        ve33.moveStake(fromStakeId, createStakeId(_stakeSalt(splitVeId), end), amount);
    }

    /// @notice Merges one represented stake into another represented stake.
    /// @dev The caller must own or be approved for both tokens. The destination stake id is kept unchanged, so `fromVeId`
    ///      must not end after `toVeId`.
    /// @param fromVeId The ERC721 token id whose entire stake is moved and then burned.
    /// @param toVeId The ERC721 token id receiving the stake.
    /// @return nextAmount Destination stake amount after the merge.
    function mergeStakes(uint256 fromVeId, uint256 toVeId)
        external
        payable
        authorizedForStake(fromVeId)
        authorizedForStake(toVeId)
        returns (uint128 nextAmount)
    {
        nextAmount = _mergeStakes(fromVeId, toVeId);
    }

    /// @notice Claims pending voter fees for the source stake, then merges it into another represented stake.
    /// @dev `fromVeId` is burned after its stake is moved, so claiming first preserves source-stake fees.
    /// @param fromVeId The ERC721 token id whose entire stake is moved and then burned.
    /// @param toVeId The ERC721 token id receiving the stake.
    /// @param poolKey The currently voted pool whose fees should be claimed before merging.
    /// @param recipient Account receiving the claimed fees.
    /// @return amount0 The amount of token0 withdrawn to `recipient`.
    /// @return amount1 The amount of token1 withdrawn to `recipient`.
    /// @return nextAmount Destination stake amount after the merge.
    function claimPoolFeesAndMergeStakes(uint256 fromVeId, uint256 toVeId, PoolKey calldata poolKey, address recipient)
        external
        payable
        authorizedForStake(fromVeId)
        authorizedForStake(toVeId)
        returns (uint128 amount0, uint128 amount1, uint128 nextAmount)
    {
        (amount0, amount1) = _claimPoolFees(fromVeId, poolKey, recipient);
        nextAmount = _mergeStakes(fromVeId, toVeId);
    }

    /// @notice Claims pending source-stake voter fees to the caller, then merges into another represented stake.
    function claimPoolFeesAndMergeStakesToSelf(uint256 fromVeId, uint256 toVeId, PoolKey calldata poolKey)
        external
        payable
        returns (uint128 amount0, uint128 amount1, uint128 nextAmount)
    {
        if (!isAuthorizedForNft(msg.sender, fromVeId)) revert NotAuthorizedForToken(msg.sender, fromVeId);
        if (!isAuthorizedForNft(msg.sender, toVeId)) revert NotAuthorizedForToken(msg.sender, toVeId);
        (amount0, amount1) = _claimPoolFees(fromVeId, poolKey, msg.sender);
        nextAmount = _mergeStakes(fromVeId, toVeId);
    }

    /// @notice Unstakes an expired represented stake and burns its ERC721 token.
    /// @dev The caller must own or be approved for `veId`; unstaked tokens are withdrawn to the current ERC721 owner.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    function withdrawStake(uint256 veId) external payable authorizedForStake(veId) {
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
    function vote(uint256 veId, PoolKey calldata poolKey, uint64 swapFee) external payable authorizedForStake(veId) {
        ve33.vote(stakeId(veId), poolKey, swapFee);
    }

    /// @notice Initializes a Ve33 pool if it has not been initialized yet.
    /// @dev Intended to be bundled before `vote` in a payable multicall.
    /// @param poolKey Pool to initialize.
    /// @param tick Initial tick if initialization is needed.
    /// @return initialized Whether this call initialized the pool.
    /// @return sqrtRatio Existing or newly initialized sqrt ratio.
    function maybeInitializePool(PoolKey memory poolKey, int32 tick)
        external
        payable
        returns (bool initialized, SqrtRatio sqrtRatio)
    {
        if (poolKey.config.fee() != 0) revert IVe33.FeeMustBeZero();
        if (poolKey.config.isConcentrated()) {
            uint32 tickSpacing = poolKey.config.concentratedTickSpacing();
            if (!isPowerOfFour(tickSpacing)) revert IVe33.TickSpacingMustBePowerOfFour();
        }
        if (poolKey.config.extension() != address(ve33)) revert IVe33.IncorrectPoolExtension();

        PoolState state = CORE.poolState(poolKey.toPoolId());
        if (state.isInitialized()) {
            sqrtRatio = state.sqrtRatio();
        } else {
            initialized = true;
            sqrtRatio = CORE.initializePool(poolKey, tick);
        }
    }

    /// @notice Clears a represented stake's active pool vote.
    /// @dev The caller must own or be approved for `veId`.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    function clearVote(uint256 veId) external payable authorizedForStake(veId) {
        ve33.clearVote(stakeId(veId));
    }

    /// @notice Claims pool fees earned by a represented stake.
    /// @dev The caller must own or be approved for `veId`.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param poolKey The pool whose voter fees should be claimed.
    /// @param recipient Account receiving the claimed fees.
    /// @return amount0 The amount of token0 withdrawn to `recipient`.
    /// @return amount1 The amount of token1 withdrawn to `recipient`.
    function claimPoolFees(uint256 veId, PoolKey calldata poolKey, address recipient)
        public
        payable
        authorizedForStake(veId)
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = _claimPoolFees(veId, poolKey, recipient);
    }

    /// @notice Claims pool fees earned by a represented stake to the caller.
    /// @dev The caller must own or be approved for `veId`.
    /// @param veId The ERC721 token id and Ve33 stake salt.
    /// @param poolKey The pool whose voter fees should be claimed.
    /// @return amount0 The amount of token0 withdrawn to the caller.
    /// @return amount1 The amount of token1 withdrawn to the caller.
    function claimPoolFeesToSelf(uint256 veId, PoolKey calldata poolKey)
        external
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = claimPoolFees(veId, poolKey, msg.sender);
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
            if (amount != 0) {
                if (stakeToken != NATIVE_TOKEN_ADDRESS) {
                    ACCOUNTANT.payFrom(owner, stakeToken, amount);
                } else {
                    SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount);
                }
            }
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

    /// @notice Mints a token and stores its represented stake end timestamp.
    function _mintAndSetExtraData(address owner, uint192 veId, uint64 end) private {
        _mint(owner, veId);
        _setExtraData(veId, end);
    }

    /// @notice Generates a pseudorandom salt for token id generation.
    function _randomSalt() private view returns (bytes32 salt) {
        assembly ("memory-safe") {
            mstore(0, prevrandao())
            mstore(32, gas())
            salt := keccak256(0, 64)
        }
    }

    /// @notice Converts an ERC721 id into the stake salt used by Ve33.
    function _stakeSalt(uint256 veId) private pure returns (bytes24 salt) {
        if (veId > type(uint192).max) revert StakeSaltOverflow(veId);
        assembly ("memory-safe") {
            salt := shl(64, veId)
        }
    }

    /// @notice Claims pending voter fees through the Core lock.
    function _claimPoolFees(uint256 veId, PoolKey calldata poolKey, address recipient)
        private
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = abi.decode(
            lock(abi.encode(CALL_TYPE_CLAIM_POOL_FEES, veId, recipient, poolKey)), (uint128, uint128)
        );
    }

    /// @notice Converts a duration into an absolute stake end timestamp.
    function _stakeEndFromDuration(uint32 duration) private view returns (uint64 end) {
        if (duration > VE33_MAX_STAKE_DURATION) revert IVe33.StakeDurationTooLong();

        uint256 endTime = block.timestamp + duration;
        if (endTime > type(uint64).max) revert StakeEndOverflow();
        end = uint64(endTime);
    }

    /// @notice Returns the maximum valid stake end timestamp from now.
    function _maxStakeEnd() private view returns (uint64) {
        return _stakeEndFromDuration(uint32(VE33_MAX_STAKE_DURATION));
    }

    /// @notice Shared implementation for stake extension.
    function _extendStake(uint256 veId, uint64 end) private {
        uint64 currentEnd = _stakeEndTime(veId);

        StakeId currentStakeId = createStakeId(_stakeSalt(veId), currentEnd);
        uint128 amount = ve33.stakeAmount(address(this), currentStakeId);
        ve33.moveStake(currentStakeId, createStakeId(_stakeSalt(veId), end), amount);
        _setExtraData(veId, end);
    }

    /// @notice Shared implementation for stake merge.
    function _mergeStakes(uint256 fromVeId, uint256 toVeId) private returns (uint128 nextAmount) {
        if (fromVeId == toVeId) return ve33.stakeAmount(address(this), stakeId(toVeId));

        uint64 fromEnd = _stakeEndTime(fromVeId);
        uint64 toEnd = _stakeEndTime(toVeId);

        StakeId fromStakeId = createStakeId(_stakeSalt(fromVeId), fromEnd);
        StakeId toStakeId = createStakeId(_stakeSalt(toVeId), toEnd);
        uint128 amount = ve33.stakeAmount(address(this), fromStakeId);
        if (amount == 0) return ve33.stakeAmount(address(this), toStakeId);

        nextAmount = ve33.moveStake(fromStakeId, toStakeId, amount);

        _burn(fromVeId);
        _setExtraData(fromVeId, 0);
    }
}
