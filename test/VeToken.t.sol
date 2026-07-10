// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

import {FullTest} from "./FullTest.sol";
import {TestToken} from "./TestToken.sol";
import {Router} from "../src/Router.sol";
import {VeToken} from "../src/VeToken.sol";
import {VeTokenMetadata} from "../src/VeTokenMetadata.sol";
import {Ve33, VE33_STAKE_TOKEN_SAVED_BALANCE_ID, ve33CallPoints} from "../src/extensions/Ve33.sol";
import {IVe33} from "../src/interfaces/extensions/IVe33.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {Ve33Lib} from "../src/libraries/Ve33Lib.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {createConcentratedPoolConfig} from "../src/types/poolConfig.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {StakeId} from "../src/types/stakeId.sol";
import {createSwapParameters} from "../src/types/swapParameters.sol";

contract ZeroStakeTokenVe33 {
    function stakeToken() external pure returns (address) {
        return address(0);
    }
}

contract ReenteringFeeToken is TestToken {
    VeToken internal veToken;
    uint256 internal tokenId;
    address internal transferRecipient;
    bool internal armed;

    constructor(address recipient) TestToken(recipient) {}

    function arm(VeToken _veToken, uint256 _tokenId, address _transferRecipient) external {
        veToken = _veToken;
        tokenId = _tokenId;
        transferRecipient = _transferRecipient;
        armed = true;
    }

    function _afterTokenTransfer(address, address, uint256) internal override {
        if (!armed) return;

        armed = false;
        veToken.transferFrom(veToken.ownerOf(tokenId), transferRecipient, tokenId);
    }
}

contract ReenteringNativeRecipient {
    VeToken internal veToken;
    uint256 internal tokenId;
    address internal transferRecipient;
    bool internal armed;

    function arm(VeToken _veToken, uint256 _tokenId, address _transferRecipient) external {
        veToken = _veToken;
        tokenId = _tokenId;
        transferRecipient = _transferRecipient;
        armed = true;
    }

    receive() external payable {
        if (!armed) return;

        armed = false;
        veToken.transferFrom(veToken.ownerOf(tokenId), transferRecipient, tokenId);
    }
}

contract VeTokenTest is FullTest {
    using CoreLib for *;
    using Ve33Lib for Ve33;

    TestToken internal stakeToken;
    Ve33 internal ve33;
    VeTokenMetadata internal metadata;
    VeToken internal veToken;

    function setUp() public override {
        super.setUp();

        stakeToken = new TestToken(address(this));
        address deployAddress = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("Ve33.sol:Ve33", abi.encode(core, address(stakeToken)), deployAddress);
        ve33 = Ve33(payable(deployAddress));
        router = new Router(core, address(0), address(ve33));
        metadata = new VeTokenMetadata("TestToken", "TT", 18, address(stakeToken));
        veToken = new VeToken(core, ve33, metadata, "Vote Escrow TestToken", "veTT");
        stakeToken.approve(address(veToken), type(uint256).max);
    }

    function coolAllContracts() internal override {
        FullTest.coolAllContracts();
        vm.cool(address(ve33));
        vm.cool(address(veToken));
        vm.cool(address(stakeToken));
    }

    function _stakeAmount(uint256 veId) internal view returns (uint128 amount) {
        (amount,) = veToken.stakes(veId);
    }

    function _stakeEnd(uint256 veId) internal view returns (uint64 endTime) {
        (, endTime) = veToken.stakes(veId);
    }

    function _stakeTokenSavedBalance() internal view returns (uint128 saved) {
        (saved,) = core.savedBalances(
            address(ve33), address(stakeToken), address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID
        );
    }

    function _createVotedPoolWithFees() internal returns (uint256 veId, PoolKey memory poolKey) {
        poolKey = createPool(address(token0), address(token1), 0, createConcentratedPoolConfig(0, 64, address(ve33)));
        createPosition(poolKey, -64, 64, 1e18, 1e18);

        veId = veToken.stakeForDuration(1e18, 1 weeks);
        veToken.vote(veId, poolKey, uint64(1 << 62));

        token0.approve(address(router), type(uint256).max);
        router.swapAllowPartialFill(
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: int128(100_000), _isToken1: false, _skipAhead: 0
            }),
            address(this)
        );
    }

    function test_gas_stake() public {
        coolAllContracts();
        veToken.stake(1e18, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()));
        vm.snapshotGasLastCall("VeToken#stake");
    }

    function test_gas_stakes() public {
        uint256 veId = veToken.stake(1e18, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()));

        coolAllContracts();
        veToken.stakes(veId);
        vm.snapshotGasLastCall("VeToken#stakes");
    }

    function test_gas_stakeId() public {
        uint256 veId = veToken.stake(1e18, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()));

        coolAllContracts();
        veToken.stakeId(veId);
        vm.snapshotGasLastCall("VeToken#stakeId");
    }

    function test_gas_votingPower() public {
        uint256 veId = veToken.stake(1e18, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()));

        coolAllContracts();
        veToken.votingPower(veId);
        vm.snapshotGasLastCall("VeToken#votingPower");
    }

    function test_gas_tokenURI() public {
        vm.warp(1);
        uint256 veId =
            veToken.stake(1e18, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()), bytes32("tokenURI gas"));

        coolAllContracts();
        veToken.tokenURI(veId);
        vm.snapshotGasLastCall("VeToken#tokenURI gas");
    }

    function test_gas_increaseStakeAmount() public {
        uint256 veId = veToken.stake(1e18, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()));

        coolAllContracts();
        veToken.increaseStakeAmount(veId, 1e18);
        vm.snapshotGasLastCall("VeToken#increaseStakeAmount");
    }

    function test_gas_extendStake() public {
        uint256 veId = veToken.stake(1e18, uint64(vm.getBlockTimestamp() + 1 weeks));

        coolAllContracts();
        veToken.extendStake(veId, uint64(vm.getBlockTimestamp() + 2 weeks));
        vm.snapshotGasLastCall("VeToken#extendStake");
    }

    function test_gas_splitStake() public {
        uint256 veId = veToken.stake(2e18, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()));

        coolAllContracts();
        veToken.splitStake(veId, 1e18);
        vm.snapshotGasLastCall("VeToken#splitStake");
    }

    function test_gas_mergeStakes() public {
        uint64 toEnd = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        uint64 fromEnd = toEnd - 1;
        uint256 toVeId = veToken.stake(1e18, toEnd);
        uint256 fromVeId = veToken.stake(1e18, fromEnd);

        coolAllContracts();
        veToken.mergeStakes(fromVeId, toVeId);
        vm.snapshotGasLastCall("VeToken#mergeStakes");
    }

    function test_gas_withdrawStake() public {
        uint64 end = uint64(vm.getBlockTimestamp() + 1);
        uint256 veId = veToken.stake(1e18, end);
        vm.warp(end);

        coolAllContracts();
        veToken.withdrawStake(veId, address(this));
        vm.snapshotGasLastCall("VeToken#withdrawStake");
    }

    function test_gas_transferFrom() public {
        uint256 veId = veToken.stake(1e18, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()));

        coolAllContracts();
        veToken.transferFrom(address(this), address(1234), veId);
        vm.snapshotGasLastCall("VeToken#transferFrom");
    }

    function test_constructorAndMetadata() public view {
        assertEq(veToken.name(), "Vote Escrow TestToken");
        assertEq(veToken.symbol(), "veTT");
        assertEq(veToken.stakeToken(), address(stakeToken));
        assertEq(address(veToken.ve33()), address(ve33));
        assertEq(address(veToken.metadata()), address(metadata));
        assertTrue(veToken.supportsInterface(0x80ac58cd));
        assertTrue(veToken.supportsInterface(0x5b5e139f));
    }

    function test_constructor_revertsIfPackedStringTooLong() public {
        vm.expectRevert(VeToken.PackedStringTooLong.selector);
        new VeToken(core, ve33, metadata, "12345678901234567890123456789012", "veTT");
    }

    function test_constructor_acceptsNativeTokenAsStakeToken() public {
        ZeroStakeTokenVe33 zeroStakeTokenVe33 = new ZeroStakeTokenVe33();
        VeTokenMetadata nativeMetadata = new VeTokenMetadata("Ether", "ETH", 18, address(0));
        VeToken nativeVeToken =
            new VeToken(core, Ve33(payable(address(zeroStakeTokenVe33))), nativeMetadata, "Vote Escrow ETH", "veETH");
        assertEq(nativeVeToken.stakeToken(), address(0));
        assertEq(nativeVeToken.name(), "Vote Escrow ETH");
        assertEq(nativeVeToken.symbol(), "veETH");
    }

    function test_multicall_batchesStakeActionsAndReads() public {
        uint64 end = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        bytes32 salt = bytes32(uint256(1));
        uint256 veId = veToken.saltToId(address(this), salt);
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeWithSelector(bytes4(keccak256("stake(uint128,uint64,bytes32)")), 1e18, end, salt);
        calls[1] = abi.encodeCall(veToken.increaseStakeAmount, (veId, 2e18));
        calls[2] = abi.encodeCall(veToken.stakes, (veId));

        bytes[] memory results = veToken.multicall(calls);
        assertEq(results.length, 3);
        assertEq(abi.decode(results[0], (uint192)), veId);
        assertEq(results[1].length, 0);

        (uint128 amount, uint64 stakeEnd) = abi.decode(results[2], (uint128, uint64));
        assertEq(amount, 3e18);
        assertEq(stakeEnd, end);
        assertEq(veToken.ownerOf(veId), address(this));
        assertEq(_stakeTokenSavedBalance(), 3e18);
    }

    function test_multicall_acceptsValue() public {
        uint64 end = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        bytes32 salt = bytes32(uint256(1));
        uint256 veId = veToken.saltToId(address(this), salt);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(bytes4(keccak256("stake(uint128,uint64,bytes32)")), 1, end, salt);

        veToken.multicall{value: 1}(calls);
        assertEq(address(veToken).balance, 1);
        assertEq(_stakeAmount(veId), 1);
    }

    function test_tokenURI_returnsErc721JsonMetadata() public {
        vm.warp(1);
        bytes32 salt = bytes32(uint256(1));
        uint256 veId = veToken.stake(15e17, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()), salt);
        string memory uri = veToken.tokenURI(veId);
        string memory prefix = "data:application/json;base64,";
        assertTrue(LibString.startsWith(uri, prefix));

        string memory json = string(Base64.decode(LibString.slice(uri, bytes(prefix).length)));
        string memory imagePrefix = "\"image\":\"data:image/svg+xml;base64,";
        uint256 imageStart = LibString.indexOf(json, imagePrefix) + bytes(imagePrefix).length;
        uint256 imageEnd = LibString.indexOf(json, "\"", imageStart);
        string memory svg = string(Base64.decode(LibString.slice(json, imageStart, imageEnd)));
        assertTrue(LibString.contains(json, string.concat("\"name\":\"veTT #", vm.toString(veId), "\"")));
        assertTrue(LibString.contains(json, "Amount: 1.5 TT."));
        assertTrue(LibString.contains(json, "Unlock date: Dec 31, 1973."));
        assertTrue(LibString.contains(json, "\"image\":\"data:image/svg+xml;base64,"));
        assertTrue(LibString.startsWith(svg, "<svg xmlns=\"http://www.w3.org/2000/svg\""));
        assertFalse(LibString.contains(svg, string.concat("#", vm.toString(veId))));
        assertTrue(LibString.contains(svg, "Apple Color Emoji"));
        assertTrue(LibString.contains(svg, ">1.5</text>"));
        assertTrue(LibString.contains(svg, ">Dec 31, 1973</text>"));
        assertTrue(LibString.contains(svg, "viewBox=\"0 0 480 480\""));
        assertTrue(LibString.endsWith(svg, "</svg>"));
    }

    function test_stakeLifecycleAndInvalidStakePaths() public {
        uint256 maxStakeDuration = veToken.MAX_STAKE_DURATION();

        vm.expectRevert(VeToken.InvalidStakeAmount.selector);
        veToken.stake(0, uint64(vm.getBlockTimestamp() + 1));
        vm.expectRevert(IVe33.StakeEndNotInFuture.selector);
        veToken.stake(1, uint64(vm.getBlockTimestamp()));
        vm.expectRevert(IVe33.StakeDurationTooLong.selector);
        veToken.stake(1, uint64(vm.getBlockTimestamp() + maxStakeDuration + 1));

        uint64 end = uint64(vm.getBlockTimestamp() + maxStakeDuration);
        uint256 veId = veToken.stake(1e18, end);
        assertEq(veToken.ownerOf(veId), address(this));
        assertEq(veToken.balanceOf(address(this)), 1);
        assertEq(_stakeTokenSavedBalance(), 1e18);
        assertEq(ve33.stakeAmount(address(veToken), veToken.stakeId(veId)), 1e18);
        assertEq(ve33.stakeAmount(address(this), veToken.stakeId(veId)), 0);

        (uint128 amount, uint64 stakeEndTime) = veToken.stakes(veId);
        assertEq(amount, 1e18);
        assertEq(stakeEndTime, end);
        assertEq(veToken.votingPower(veId), 1e18);

        veToken.increaseStakeAmount(veId, 0);
        (amount, stakeEndTime) = veToken.stakes(veId);
        assertEq(amount, 1e18);
        assertEq(stakeEndTime, end);
        veToken.increaseStakeAmount(veId, 2e18);

        (amount, stakeEndTime) = veToken.stakes(veId);
        assertEq(amount, 3e18);
        assertEq(stakeEndTime, end);

        veToken.extendStake(veId, end);
        (amount, stakeEndTime) = veToken.stakes(veId);
        assertEq(amount, 3e18);
        assertEq(stakeEndTime, end);

        vm.expectRevert(IVe33.MoveStakeToEarlierEndTime.selector);
        veToken.extendStake(veId, end - 1);

        vm.warp(10);
        uint64 extendedEnd = uint64(vm.getBlockTimestamp() + maxStakeDuration);
        veToken.extendStake(veId, extendedEnd);

        (amount, stakeEndTime) = veToken.stakes(veId);
        assertEq(amount, 3e18);
        assertEq(stakeEndTime, extendedEnd);
        assertEq(_stakeTokenSavedBalance(), 3e18);

        vm.expectRevert(IVe33.StakeNotExpired.selector);
        veToken.withdrawStakeToSelf(veId);
        vm.warp(extendedEnd);
        assertEq(veToken.votingPower(veId), 0);
        uint256 balanceBefore = stakeToken.balanceOf(address(this));
        veToken.withdrawStakeToSelf(veId);

        assertEq(stakeToken.balanceOf(address(this)), balanceBefore + 3e18);
        assertEq(_stakeTokenSavedBalance(), 0);
        assertEq(veToken.balanceOf(address(this)), 1);
        assertEq(veToken.ownerOf(veId), address(this));
        (amount, stakeEndTime) = veToken.stakes(veId);
        assertEq(amount, 0);
        assertEq(stakeEndTime, extendedEnd);

        veToken.burn(veId);
        assertEq(veToken.balanceOf(address(this)), 0);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        veToken.ownerOf(veId);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        veToken.tokenURI(veId);
    }

    function test_stakeForDurationUsesRelativeEndTime() public {
        uint32 duration = 2 weeks;
        uint64 expectedEnd = uint64(vm.getBlockTimestamp() + duration);

        uint256 veId = veToken.stakeForDuration(1e18, duration);

        assertEq(veToken.ownerOf(veId), address(this));
        assertEq(_stakeAmount(veId), 1e18);
        assertEq(_stakeEnd(veId), expectedEnd);
        assertEq(_stakeTokenSavedBalance(), 1e18);
    }

    function test_explicitSaltCreatesUint192TokenIdAndStakeSalt() public {
        uint64 end = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        bytes32 salt = bytes32(uint256(0x1234));
        uint256 expectedVeId = veToken.saltToId(address(this), salt);

        uint256 veId = veToken.stake(2e18, end, salt);

        assertEq(veId, expectedVeId);
        assertLe(veId, type(uint192).max);
        assertEq(veToken.ownerOf(veId), address(this));
        assertEq(veToken.stakeId(veId).salt(), bytes24(uint192(veId)));

        bytes32 splitSalt = bytes32(uint256(0x5678));
        uint256 expectedSplitVeId = veToken.saltToId(address(this), splitSalt);
        uint256 splitVeId = veToken.splitStake(veId, 1e18, splitSalt);

        assertEq(splitVeId, expectedSplitVeId);
        assertLe(splitVeId, type(uint192).max);
        assertEq(veToken.ownerOf(splitVeId), address(this));
        assertEq(veToken.stakeId(splitVeId).salt(), bytes24(uint192(splitVeId)));
        assertEq(_stakeAmount(splitVeId), 1e18);
    }

    function test_stakeAndVoteUsesExplicitSalt() public {
        PoolKey memory poolKey =
            createPool(address(token0), address(token1), 0, createConcentratedPoolConfig(0, 64, address(ve33)));
        uint64 end = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        bytes32 salt = bytes32(uint256(0xBEEF));
        uint256 expectedVeId = veToken.saltToId(address(this), salt);
        uint64 swapFee = uint64(1 << 62);

        uint256 veId = veToken.stakeAndVote(1e18, end, salt, poolKey, swapFee);
        StakeId id = veToken.stakeId(veId);

        assertEq(veId, expectedVeId);
        assertLe(veId, type(uint192).max);
        assertEq(id.salt(), bytes24(uint192(veId)));
        assertEq(PoolId.unwrap(ve33.votedPool(address(veToken), id)), PoolId.unwrap(poolKey.toPoolId()));
        assertEq(ve33.vePoolVote(address(veToken), id).swapFee(), swapFee);
    }

    function test_stakeForDurationValidatesDuration() public {
        vm.expectRevert(IVe33.StakeEndNotInFuture.selector);
        veToken.stakeForDuration(1, 0);

        uint32 tooLongDuration = uint32(veToken.MAX_STAKE_DURATION() + 1);
        vm.expectRevert(IVe33.StakeDurationTooLong.selector);
        veToken.stakeForDuration(1, tooLongDuration);
    }

    function test_durationStakeActionsPreventUint64EndTimeOverflow() public {
        vm.warp(uint256(type(uint64).max) - 1);

        vm.expectRevert(VeToken.StakeEndOverflow.selector);
        veToken.stakeForDuration(1, 2);

        vm.expectRevert(VeToken.StakeEndOverflow.selector);
        veToken.stakeMaxDuration(1);

        uint256 veId = veToken.stakeForDuration(1, 1);
        assertEq(_stakeEnd(veId), type(uint64).max);

        vm.expectRevert(VeToken.StakeEndOverflow.selector);
        veToken.extendStakeForDuration(veId, 2);
    }

    function test_extendStakeForDurationUsesRelativeEndTime() public {
        uint256 veId = veToken.stakeForDuration(1e18, 1 weeks);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint32 duration = 3 weeks;
        uint64 expectedEnd = uint64(vm.getBlockTimestamp() + duration);

        veToken.extendStakeForDuration(veId, duration);

        assertEq(_stakeAmount(veId), 1e18);
        assertEq(_stakeEnd(veId), expectedEnd);
    }

    function test_maxDurationStakeActionsUseCurrentTimestamp() public {
        uint256 maxStakeDuration = veToken.MAX_STAKE_DURATION();
        uint64 createEnd = uint64(vm.getBlockTimestamp() + maxStakeDuration);

        uint256 veId = veToken.stakeMaxDuration(1e18);
        assertEq(_stakeEnd(veId), createEnd);

        vm.warp(vm.getBlockTimestamp() + 1 weeks);
        uint64 extendEnd = uint64(vm.getBlockTimestamp() + maxStakeDuration);

        veToken.extendStakeMaxDuration(veId);

        assertEq(_stakeAmount(veId), 1e18);
        assertEq(_stakeEnd(veId), extendEnd);
        assertGt(extendEnd, createEnd);
    }

    function test_claimPoolFeesAndExtendStakeForDurationClaimsAndUsesRelativeEndTime() public {
        (uint256 veId, PoolKey memory poolKey) = _createVotedPoolWithFees();
        address recipient = address(0xBEEF);

        uint256 recipientBalanceBefore = token1.balanceOf(recipient);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint32 duration = 3 weeks;
        uint64 expectedEnd = uint64(vm.getBlockTimestamp() + duration);

        (uint128 claimed0, uint128 claimed1) =
            veToken.claimPoolFeesAndExtendStakeForDuration(veId, duration, poolKey, recipient);

        assertEq(claimed0, 0);
        assertGt(claimed1, 0);
        assertEq(token1.balanceOf(recipient), recipientBalanceBefore + claimed1);
        assertEq(_stakeEnd(veId), expectedEnd);
        assertEq(PoolId.unwrap(ve33.votedPool(address(veToken), veToken.stakeId(veId))), 0);
        assertEq(ve33.poolTotalWeight(poolKey.toPoolId()), 0);
    }

    function test_claimPoolFeesAndExtendStakeToSelfMaxDurationClaimsAndUsesCurrentTimestamp() public {
        (uint256 veId, PoolKey memory poolKey) = _createVotedPoolWithFees();

        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint64 expectedEnd = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        uint256 balanceBefore = token1.balanceOf(address(this));

        (uint128 claimed0, uint128 claimed1) = veToken.claimPoolFeesAndExtendStakeToSelfMaxDuration(veId, poolKey);

        assertEq(claimed0, 0);
        assertGt(claimed1, 0);
        assertEq(token1.balanceOf(address(this)), balanceBefore + claimed1);
        assertEq(_stakeEnd(veId), expectedEnd);
        assertEq(PoolId.unwrap(ve33.votedPool(address(veToken), veToken.stakeId(veId))), 0);
        assertEq(ve33.poolTotalWeight(poolKey.toPoolId()), 0);
    }

    function test_claimPoolFeesAndExtendStakeDurationWrappersRevertPaths() public {
        uint256 veId = veToken.stakeForDuration(1e18, 1 weeks);
        PoolKey memory poolKey;
        address unauthorized = address(0xBAD);

        vm.expectRevert(abi.encodeWithSelector(VeToken.NotAuthorizedForToken.selector, unauthorized, veId));
        vm.prank(unauthorized);
        veToken.claimPoolFeesAndExtendStakeToSelfForDuration(veId, 1 weeks, poolKey);

        uint32 tooLongDuration = uint32(veToken.MAX_STAKE_DURATION() + 1);
        vm.expectRevert(IVe33.StakeDurationTooLong.selector);
        veToken.claimPoolFeesAndExtendStakeForDuration(veId, tooLongDuration, poolKey, address(this));

        vm.warp(uint256(type(uint64).max) - 1);
        vm.expectRevert(VeToken.StakeEndOverflow.selector);
        veToken.claimPoolFeesAndExtendStakeToSelfForDuration(veId, 2, poolKey);
    }

    function test_claimPoolFeesAndExtendStakeRechecksAuthorizationAfterErc20FeeTransfer() public {
        ReenteringFeeToken feeToken = new ReenteringFeeToken(address(this));
        PoolKey memory poolKey = address(feeToken) < address(token1)
            ? createPool(address(feeToken), address(token1), 0, createConcentratedPoolConfig(0, 64, address(ve33)))
            : createPool(address(token0), address(feeToken), 0, createConcentratedPoolConfig(0, 64, address(ve33)));
        createPosition(poolKey, -64, 64, 1e18, 1e18);

        uint64 end = uint64(vm.getBlockTimestamp() + 1 weeks);
        uint256 veId = veToken.stake(2e18, end);
        veToken.vote(veId, poolKey, uint64(1 << 62));

        TestToken(poolKey.token0).approve(address(router), type(uint256).max);
        TestToken(poolKey.token1).approve(address(router), type(uint256).max);
        router.swapAllowPartialFill(
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: int128(100_000), _isToken1: false, _skipAhead: 0
            }),
            address(this)
        );
        router.swapAllowPartialFill(
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: int128(100_000), _isToken1: true, _skipAhead: 0
            }),
            address(this)
        );

        address newOwner = address(0xBEEF);
        veToken.setApprovalForAll(address(feeToken), true);
        feeToken.arm(veToken, veId, newOwner);

        vm.expectRevert(abi.encodeWithSelector(VeToken.NotAuthorizedForToken.selector, address(this), veId));
        veToken.claimPoolFeesAndExtendStake(veId, end + 1 weeks, poolKey, address(this));

        assertEq(veToken.ownerOf(veId), address(this));
        assertEq(_stakeAmount(veId), 2e18);
        assertEq(_stakeEnd(veId), end);
    }

    function test_claimPoolFeesAndMergeStakesRechecksAuthorizationAfterErc20FeeTransfer() public {
        ReenteringFeeToken feeToken = new ReenteringFeeToken(address(this));
        PoolKey memory poolKey = address(feeToken) < address(token1)
            ? createPool(address(feeToken), address(token1), 0, createConcentratedPoolConfig(0, 64, address(ve33)))
            : createPool(address(token0), address(feeToken), 0, createConcentratedPoolConfig(0, 64, address(ve33)));
        createPosition(poolKey, -64, 64, 1e18, 1e18);

        uint64 fromEnd = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION() - 1 days);
        uint64 toEnd = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        uint256 fromVeId = veToken.stake(2e18, fromEnd);
        uint256 toVeId = veToken.stake(1e18, toEnd);
        veToken.vote(fromVeId, poolKey, uint64(1 << 62));

        TestToken(poolKey.token0).approve(address(router), type(uint256).max);
        TestToken(poolKey.token1).approve(address(router), type(uint256).max);
        router.swapAllowPartialFill(
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: int128(100_000), _isToken1: false, _skipAhead: 0
            }),
            address(this)
        );
        router.swapAllowPartialFill(
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: int128(100_000), _isToken1: true, _skipAhead: 0
            }),
            address(this)
        );

        address newOwner = address(0xBEEF);
        veToken.setApprovalForAll(address(feeToken), true);
        feeToken.arm(veToken, toVeId, newOwner);

        vm.expectRevert(abi.encodeWithSelector(VeToken.NotAuthorizedForToken.selector, address(this), toVeId));
        veToken.claimPoolFeesAndMergeStakes(fromVeId, toVeId, poolKey, address(this));

        assertEq(veToken.ownerOf(fromVeId), address(this));
        assertEq(veToken.ownerOf(toVeId), address(this));
        assertEq(_stakeAmount(fromVeId), 2e18);
        assertEq(_stakeAmount(toVeId), 1e18);
    }

    function test_claimPoolFeesAndMergeStakesRechecksAuthorizationAfterNativeFeeTransfer() public {
        PoolKey memory poolKey =
            createPool(NATIVE_TOKEN_ADDRESS, address(token1), 0, createConcentratedPoolConfig(0, 64, address(ve33)));
        createPosition(poolKey, -64, 64, 1e18, 1e18);

        uint64 fromEnd = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION() - 1 days);
        uint64 toEnd = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        uint256 fromVeId = veToken.stake(2e18, fromEnd);
        uint256 toVeId = veToken.stake(1e18, toEnd);
        veToken.vote(fromVeId, poolKey, uint64(1 << 62));

        token1.approve(address(router), type(uint256).max);
        router.swapAllowPartialFill(
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: int128(100_000), _isToken1: true, _skipAhead: 0
            }),
            address(this)
        );

        ReenteringNativeRecipient recipient = new ReenteringNativeRecipient();
        address newOwner = address(0xBEEF);
        veToken.setApprovalForAll(address(recipient), true);
        recipient.arm(veToken, toVeId, newOwner);

        vm.expectRevert(abi.encodeWithSelector(VeToken.NotAuthorizedForToken.selector, address(this), toVeId));
        veToken.claimPoolFeesAndMergeStakes(fromVeId, toVeId, poolKey, address(recipient));

        assertEq(veToken.ownerOf(fromVeId), address(this));
        assertEq(veToken.ownerOf(toVeId), address(this));
        assertEq(_stakeAmount(fromVeId), 2e18);
        assertEq(_stakeAmount(toVeId), 1e18);
        assertEq(address(recipient).balance, 0);
    }

    function test_splitAndMergeStakeLifecycle() public {
        uint64 end = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        uint256 veId = veToken.stake(4e18, end);

        vm.expectRevert(VeToken.InvalidStakeAmount.selector);
        veToken.splitStake(veId, 0);
        vm.expectRevert(VeToken.SplitAmountMustBeLessThanStakeAmount.selector);
        veToken.splitStake(veId, 4e18);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        veToken.ownerOf(2);

        uint256 splitVeId = veToken.splitStake(veId, 1e18, bytes32(uint256(2)));
        assertEq(veToken.ownerOf(splitVeId), address(this));
        assertEq(veToken.balanceOf(address(this)), 2);
        assertEq(_stakeAmount(veId), 3e18);
        assertEq(_stakeAmount(splitVeId), 1e18);
        assertEq(_stakeEnd(splitVeId), end);

        assertEq(_stakeTokenSavedBalance(), 4e18);

        assertEq(veToken.mergeStakes(veId, veId), 3e18);
        assertEq(_stakeAmount(veId), 3e18);

        // Merging a split stake (same end time) back into the source now succeeds.
        assertEq(veToken.mergeStakes(splitVeId, veId), 4e18);
        assertEq(_stakeAmount(veId), 4e18);
        assertEq(_stakeTokenSavedBalance(), 4e18);

        uint64 shortEnd = uint64(end - 1);
        uint256 shortVeId = veToken.stake(1e18, shortEnd);
        uint256 longVeId = veToken.stake(2e18, end);
        assertEq(_stakeTokenSavedBalance(), 7e18);

        vm.expectRevert(IVe33.MoveStakeToEarlierEndTime.selector);
        veToken.mergeStakes(longVeId, shortVeId);

        assertEq(_stakeAmount(shortVeId), 1e18);
        assertEq(_stakeAmount(longVeId), 2e18);

        assertEq(veToken.mergeStakes(shortVeId, longVeId), 3e18);
        assertEq(_stakeAmount(longVeId), 3e18);
        assertEq(_stakeEnd(longVeId), end);
        assertEq(_stakeTokenSavedBalance(), 7e18);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        veToken.ownerOf(shortVeId);
    }

    function test_withdrawStakeAndBurnCanBeMulticalled() public {
        uint64 end = uint64(vm.getBlockTimestamp() + 1);
        uint256 veId = veToken.stake(1e18, end);
        vm.warp(end);

        uint256 balanceBefore = stakeToken.balanceOf(address(this));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(veToken.withdrawStakeToSelf, (veId));
        calls[1] = abi.encodeCall(veToken.burn, (veId));

        veToken.multicall(calls);

        assertEq(stakeToken.balanceOf(address(this)), balanceBefore + 1e18);
        assertEq(veToken.balanceOf(address(this)), 0);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        veToken.ownerOf(veId);
    }

    function test_burnDoesNotRequireWithdrawnStake() public {
        uint64 end = uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION());
        uint256 veId = veToken.stake(1e18, end);
        StakeId id = veToken.stakeId(veId);

        veToken.burn(veId);

        assertEq(veToken.balanceOf(address(this)), 0);
        assertEq(ve33.stakeAmount(address(veToken), id), 1e18);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        veToken.ownerOf(veId);
    }

    function test_erc721TransferMovesStakeControl() public {
        uint256 veId = veToken.stake(1e18, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()));
        address operator = address(1234);

        veToken.transferFrom(address(this), operator, veId);
        assertEq(veToken.ownerOf(veId), operator);
        assertEq(veToken.balanceOf(address(this)), 0);
        assertEq(veToken.balanceOf(operator), 1);
        assertEq(_stakeAmount(veId), 1e18);
        assertEq(ve33.stakeAmount(address(veToken), veToken.stakeId(veId)), 1e18);

        vm.expectRevert(abi.encodeWithSelector(VeToken.NotAuthorizedForToken.selector, address(this), veId));
        veToken.increaseStakeAmount(veId, 1);

        stakeToken.transfer(operator, 1e18);
        vm.startPrank(operator);
        stakeToken.approve(address(veToken), type(uint256).max);
        veToken.increaseStakeAmount(veId, 1e18);
        vm.stopPrank();

        assertEq(_stakeAmount(veId), 2e18);
    }

    function test_erc721ApprovedAccountCanUpdateStake() public {
        uint256 veId = veToken.stake(1e18, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()));
        address operator = address(1234);
        stakeToken.transfer(operator, 1e18);

        vm.startPrank(operator);
        stakeToken.approve(address(veToken), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(VeToken.NotAuthorizedForToken.selector, operator, veId));
        veToken.increaseStakeAmount(veId, 1e18);
        vm.stopPrank();

        veToken.approve(operator, veId);
        assertEq(veToken.getApproved(veId), operator);
        vm.prank(operator);
        veToken.increaseStakeAmount(veId, 1e18);
        assertEq(_stakeAmount(veId), 2e18);

        veToken.setApprovalForAll(operator, true);
        assertTrue(veToken.isApprovedForAll(address(this), operator));
        stakeToken.transfer(operator, 1e18);
        vm.prank(operator);
        veToken.increaseStakeAmount(veId, 1e18);
        assertEq(_stakeAmount(veId), 3e18);
    }

    function test_approvedWithdrawCanSendStakeToExplicitRecipient() public {
        uint256 veId = veToken.stake(1e18, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()));
        address operator = address(1234);
        veToken.approve(operator, veId);
        vm.warp(_stakeEnd(veId));

        uint256 ownerBalanceBefore = stakeToken.balanceOf(address(this));
        uint256 operatorBalanceBefore = stakeToken.balanceOf(operator);
        vm.prank(operator);
        veToken.withdrawStake(veId, address(this));

        assertEq(stakeToken.balanceOf(address(this)), ownerBalanceBefore + 1e18);
        assertEq(stakeToken.balanceOf(operator), operatorBalanceBefore);
        assertEq(veToken.ownerOf(veId), address(this));
        assertEq(_stakeAmount(veId), 0);
        vm.prank(operator);
        veToken.burn(veId);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        veToken.ownerOf(veId);
    }

    function test_approvedWithdrawToSelfSendsStakeToCaller() public {
        uint256 veId = veToken.stake(1e18, uint64(vm.getBlockTimestamp() + veToken.MAX_STAKE_DURATION()));
        address operator = address(1234);
        veToken.approve(operator, veId);
        vm.warp(_stakeEnd(veId));

        uint256 ownerBalanceBefore = stakeToken.balanceOf(address(this));
        uint256 operatorBalanceBefore = stakeToken.balanceOf(operator);
        vm.prank(operator);
        veToken.withdrawStakeToSelf(veId);

        assertEq(stakeToken.balanceOf(address(this)), ownerBalanceBefore);
        assertEq(stakeToken.balanceOf(operator), operatorBalanceBefore + 1e18);
        assertEq(veToken.ownerOf(veId), address(this));
        assertEq(_stakeAmount(veId), 0);
        vm.prank(operator);
        veToken.burn(veId);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        veToken.ownerOf(veId);
    }
}

contract NativeVeTokenTest is FullTest {
    Ve33 internal nativeVe33;
    VeTokenMetadata internal nativeMetadata;
    VeToken internal nativeVeToken;

    function setUp() public override {
        super.setUp();

        address deployAddress = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("Ve33.sol:Ve33", abi.encode(core, NATIVE_TOKEN_ADDRESS), deployAddress);
        nativeVe33 = Ve33(payable(deployAddress));
        nativeMetadata = new VeTokenMetadata("Ether", "ETH", 18, NATIVE_TOKEN_ADDRESS);
        nativeVeToken = new VeToken(core, nativeVe33, nativeMetadata, "Vote Escrow ETH", "veETH");
    }

    function _stakeAmount(uint256 veId) internal view returns (uint128 amount) {
        (amount,) = nativeVeToken.stakes(veId);
    }

    function test_multicallBurnRechecksAuthorizationAfterNativeUnstakeTransfer() public {
        uint64 end = uint64(vm.getBlockTimestamp() + 1);
        uint256 veId = nativeVeToken.stake{value: 1e18}(1e18, end);
        vm.warp(end);

        ReenteringNativeRecipient recipient = new ReenteringNativeRecipient();
        address newOwner = address(0xBEEF);
        nativeVeToken.setApprovalForAll(address(recipient), true);
        recipient.arm(nativeVeToken, veId, newOwner);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(nativeVeToken.withdrawStake, (veId, address(recipient)));
        calls[1] = abi.encodeCall(nativeVeToken.burn, (veId));

        vm.expectRevert(abi.encodeWithSelector(VeToken.NotAuthorizedForToken.selector, address(this), veId));
        nativeVeToken.multicall(calls);

        assertEq(nativeVeToken.ownerOf(veId), address(this));
        assertEq(_stakeAmount(veId), 1e18);
        assertEq(address(recipient).balance, 0);
    }
}
