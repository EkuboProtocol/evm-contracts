// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";

import {FullTest} from "./FullTest.sol";
import {TestToken} from "./TestToken.sol";
import {VeToken} from "../src/VeToken.sol";
import {Ve33, ve33CallPoints} from "../src/extensions/Ve33.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {Ve33Lib} from "../src/libraries/Ve33Lib.sol";

contract VeTokenTest is FullTest {
    using CoreLib for *;
    using Ve33Lib for Ve33;

    TestToken internal stakeToken;
    Ve33 internal ve33;
    VeToken internal veToken;

    function setUp() public override {
        super.setUp();

        stakeToken = new TestToken(address(this));
        address deployAddress = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("Ve33.sol", abi.encode(core, address(stakeToken)), deployAddress);
        ve33 = Ve33(payable(deployAddress));
        veToken = new VeToken(core, ve33);
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

    function _readSnapshotBytes(string memory path) internal view returns (bytes memory) {
        bytes memory data = bytes(vm.readFile(path));
        if (data.length != 0 && data[data.length - 1] == 0x0a) {
            bytes memory trimmed = new bytes(data.length - 1);
            for (uint256 i = 0; i < trimmed.length; i++) {
                trimmed[i] = data[i];
            }
            data = trimmed;
        }
        return data;
    }

    function _assertSnapshotEq(bytes memory actual, string memory path) internal view {
        bytes memory expected = _readSnapshotBytes(path);
        assertEq(actual.length, expected.length, string.concat(path, " length"));
        for (uint256 i = 0; i < actual.length; i++) {
            assertEq(uint8(actual[i]), uint8(expected[i]), string.concat(path, " byte ", vm.toString(i)));
        }
    }

    function test_gas_createStake() public {
        coolAllContracts();
        veToken.createStake(1e18, uint64(block.timestamp + veToken.MAX_STAKE_DURATION()));
        vm.snapshotGasLastCall("VeToken#createStake");
    }

    function test_gas_stakes() public {
        uint256 veId = veToken.createStake(1e18, uint64(block.timestamp + veToken.MAX_STAKE_DURATION()));

        coolAllContracts();
        veToken.stakes(veId);
        vm.snapshotGasLastCall("VeToken#stakes");
    }

    function test_gas_stakeKey() public {
        uint256 veId = veToken.createStake(1e18, uint64(block.timestamp + veToken.MAX_STAKE_DURATION()));

        coolAllContracts();
        veToken.stakeKey(veId);
        vm.snapshotGasLastCall("VeToken#stakeKey");
    }

    function test_gas_votingPower() public {
        uint256 veId = veToken.createStake(1e18, uint64(block.timestamp + veToken.MAX_STAKE_DURATION()));

        coolAllContracts();
        veToken.votingPower(veId);
        vm.snapshotGasLastCall("VeToken#votingPower");
    }

    function test_gas_tokenURI() public {
        uint256 veId = veToken.createStake(1e18, uint64(block.timestamp + veToken.MAX_STAKE_DURATION()));

        coolAllContracts();
        veToken.tokenURI(veId);
        vm.snapshotGasLastCall("VeToken#tokenURI gas");
    }

    function test_gas_increaseStakeAmount() public {
        uint256 veId = veToken.createStake(1e18, uint64(block.timestamp + veToken.MAX_STAKE_DURATION()));

        coolAllContracts();
        veToken.increaseStakeAmount(veId, 1e18);
        vm.snapshotGasLastCall("VeToken#increaseStakeAmount");
    }

    function test_gas_extendStake() public {
        uint256 veId = veToken.createStake(1e18, uint64(block.timestamp + 1 weeks));

        coolAllContracts();
        veToken.extendStake(veId, uint64(block.timestamp + 2 weeks));
        vm.snapshotGasLastCall("VeToken#extendStake");
    }

    function test_gas_withdrawStake() public {
        uint64 end = uint64(block.timestamp + 1);
        uint256 veId = veToken.createStake(1e18, end);
        vm.warp(end);

        coolAllContracts();
        veToken.withdrawStake(veId);
        vm.snapshotGasLastCall("VeToken#withdrawStake");
    }

    function test_gas_transferFrom() public {
        uint256 veId = veToken.createStake(1e18, uint64(block.timestamp + veToken.MAX_STAKE_DURATION()));

        coolAllContracts();
        veToken.transferFrom(address(this), address(1234), veId);
        vm.snapshotGasLastCall("VeToken#transferFrom");
    }

    function test_constructorAndMetadata() public view {
        assertEq(veToken.name(), "Vote Escrow TestToken");
        assertEq(veToken.symbol(), "veTT");
        assertEq(veToken.stakeToken(), address(stakeToken));
        assertEq(address(veToken.ve33()), address(ve33));
        assertTrue(veToken.supportsInterface(0x80ac58cd));
        assertTrue(veToken.supportsInterface(0x5b5e139f));
    }

    function test_tokenURI_returnsErc721JsonMetadata() public {
        uint256 veId = veToken.createStake(1e18, uint64(block.timestamp + veToken.MAX_STAKE_DURATION()));
        string memory uri = veToken.tokenURI(veId);
        string memory prefix = "data:application/json;base64,";
        assertTrue(LibString.startsWith(uri, prefix));

        string memory json = string(Base64.decode(LibString.slice(uri, bytes(prefix).length)));
        string memory imagePrefix = "\"image\":\"data:image/svg+xml;base64,";
        uint256 imageStart = LibString.indexOf(json, imagePrefix) + bytes(imagePrefix).length;
        uint256 imageEnd = LibString.indexOf(json, "\"", imageStart);
        string memory svg = string(Base64.decode(LibString.slice(json, imageStart, imageEnd)));
        _assertSnapshotEq(bytes(json), "snapshots/VeTokenTokenURI.json");
        _assertSnapshotEq(bytes(svg), "snapshots/VeTokenTokenURI.svg");
        assertTrue(LibString.contains(json, "\"name\":\"veTT #1\""));
        assertTrue(LibString.contains(json, "\"description\":\"Vote-escrowed TestToken stake."));
        assertTrue(LibString.contains(json, "\"image\":\"data:image/svg+xml;base64,"));
        assertTrue(LibString.startsWith(svg, "<svg xmlns=\"http://www.w3.org/2000/svg\""));
        assertTrue(LibString.contains(svg, "viewBox=\"0 0 480 480\""));
        assertTrue(LibString.endsWith(svg, "</svg>"));
    }

    function test_stakeLifecycleAndInvalidStakePaths() public {
        uint256 maxStakeDuration = veToken.MAX_STAKE_DURATION();

        vm.expectRevert(Ve33.InvalidStake.selector);
        veToken.createStake(0, uint64(block.timestamp + 1));
        vm.expectRevert(Ve33.InvalidStake.selector);
        veToken.createStake(1, uint64(block.timestamp));
        vm.expectRevert(Ve33.InvalidStake.selector);
        veToken.createStake(1, uint64(block.timestamp + maxStakeDuration + 1));

        uint64 end = uint64(block.timestamp + maxStakeDuration);
        uint256 veId = veToken.createStake(1e18, end);
        assertEq(veToken.ownerOf(veId), address(this));
        assertEq(veToken.balanceOf(address(this)), 1);
        bytes32 salt = bytes32(veId);
        bytes32 stakeId = keccak256(abi.encode(address(veToken), salt, end));
        (uint128 saved,) = core.savedBalances(address(ve33), address(stakeToken), address(type(uint160).max), stakeId);
        assertEq(saved, 1e18);
        assertEq(ve33.stakeAmount(address(veToken), salt, end), 1e18);
        assertEq(ve33.stakeAmount(address(this), salt, end), 0);

        (uint128 amount, uint64 stakeEndTime) = veToken.stakes(veId);
        assertEq(amount, 1e18);
        assertEq(stakeEndTime, end);
        assertEq(veToken.votingPower(veId), 1e18);

        vm.expectRevert(Ve33.InvalidStake.selector);
        veToken.increaseStakeAmount(veId, 0);
        veToken.increaseStakeAmount(veId, 2e18);

        (amount, stakeEndTime) = veToken.stakes(veId);
        assertEq(amount, 3e18);
        assertEq(stakeEndTime, end);

        vm.expectRevert(VeToken.InvalidStake.selector);
        veToken.extendStake(veId, end);
        vm.warp(10);
        uint64 extendedEnd = uint64(block.timestamp + maxStakeDuration);
        veToken.extendStake(veId, extendedEnd);

        (amount, stakeEndTime) = veToken.stakes(veId);
        assertEq(amount, 3e18);
        assertEq(stakeEndTime, extendedEnd);
        bytes32 extendedStakeId = keccak256(abi.encode(address(veToken), salt, extendedEnd));
        (saved,) = core.savedBalances(address(ve33), address(stakeToken), address(type(uint160).max), stakeId);
        assertEq(saved, 0);
        (saved,) = core.savedBalances(address(ve33), address(stakeToken), address(type(uint160).max), extendedStakeId);
        assertEq(saved, 3e18);

        vm.expectRevert(Ve33.InvalidStake.selector);
        veToken.withdrawStake(veId);
        vm.warp(extendedEnd);
        assertEq(veToken.votingPower(veId), 0);
        uint256 balanceBefore = stakeToken.balanceOf(address(this));
        veToken.withdrawStake(veId);

        assertEq(stakeToken.balanceOf(address(this)), balanceBefore + 3e18);
        (saved,) = core.savedBalances(address(ve33), address(stakeToken), address(type(uint160).max), extendedStakeId);
        assertEq(saved, 0);
        assertEq(veToken.balanceOf(address(this)), 0);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        veToken.ownerOf(veId);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        veToken.tokenURI(veId);
    }

    function test_erc721TransferMovesStakeControl() public {
        uint256 veId = veToken.createStake(1e18, uint64(block.timestamp + veToken.MAX_STAKE_DURATION()));
        address operator = address(1234);

        veToken.transferFrom(address(this), operator, veId);
        assertEq(veToken.ownerOf(veId), operator);
        assertEq(veToken.balanceOf(address(this)), 0);
        assertEq(veToken.balanceOf(operator), 1);
        assertEq(_stakeAmount(veId), 1e18);
        assertEq(ve33.stakeAmount(address(veToken), bytes32(veId), _stakeEnd(veId)), 1e18);

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
        uint256 veId = veToken.createStake(1e18, uint64(block.timestamp + veToken.MAX_STAKE_DURATION()));
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

    function test_approvedWithdrawSendsStakeToCurrentOwner() public {
        uint256 veId = veToken.createStake(1e18, uint64(block.timestamp + veToken.MAX_STAKE_DURATION()));
        address operator = address(1234);
        veToken.approve(operator, veId);
        vm.warp(_stakeEnd(veId));

        uint256 ownerBalanceBefore = stakeToken.balanceOf(address(this));
        uint256 operatorBalanceBefore = stakeToken.balanceOf(operator);
        vm.prank(operator);
        veToken.withdrawStake(veId);

        assertEq(stakeToken.balanceOf(address(this)), ownerBalanceBefore + 1e18);
        assertEq(stakeToken.balanceOf(operator), operatorBalanceBefore);
        vm.expectRevert(ERC721.TokenDoesNotExist.selector);
        veToken.ownerOf(veId);
    }
}
