// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "solady/tokens/ERC721.sol";

/// @dev Identical ERC721 mint/index bookkeeping in both instances; only the owner-array width differs.
contract OwnerPackingMintHarness is ERC721 {
    bool private immutable packed;
    uint64 private nextId = 1;
    mapping(uint256 => uint256) private ownerIndexes;
    mapping(address => uint64[]) private packedOwned;
    mapping(address => uint256[]) private fullOwned;

    constructor(bool usePacking) {
        packed = usePacking;
    }

    function name() public pure override returns (string memory) {
        return "Owner packing benchmark";
    }

    function symbol() public pure override returns (string memory) {
        return "BENCH";
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    function mint(address owner) external {
        _mint(owner, nextId++);
    }

    function _afterTokenTransfer(address, address to, uint256 id) internal override {
        ownerIndexes[id] = packed ? packedOwned[to].length : fullOwned[to].length;
        if (packed) packedOwned[to].push(uint64(id));
        else fullOwned[to].push(id);
    }

    function ownerDataSlot(address owner) external view returns (bytes32) {
        uint256 slot;
        if (packed) assembly { slot := packedOwned.slot } else assembly { slot := fullOwned.slot }
        return keccak256(abi.encode(keccak256(abi.encode(owner, slot))));
    }
}

contract FreeLPOwnerPackingTest is Test {
    function test_secondMintBySameOwnerReusesPackedSlot() public {
        OwnerPackingMintHarness packed = new OwnerPackingMintHarness(true);
        OwnerPackingMintHarness full = new OwnerPackingMintHarness(false);
        address owner = address(0xa11ce);
        packed.mint(owner);
        full.mint(owner);
        vm.cool(address(packed));
        vm.cool(address(full));

        uint256 packedGas = gasleft();
        packed.mint(owner);
        packedGas -= gasleft();
        vm.snapshotGasLastCall("FreeLPOwnerPacking", "second same-owner mint packed");
        uint256 fullGas = gasleft();
        full.mint(owner);
        fullGas -= gasleft();
        vm.snapshotGasLastCall("FreeLPOwnerPacking", "second same-owner mint full word");
        emit log_named_uint("packed second mint", packedGas);
        emit log_named_uint("full-word second mint", fullGas);
        assertGt(fullGas, packedGas + 10000);

        bytes32 packedSlot = packed.ownerDataSlot(owner);
        bytes32 fullSlot = full.ownerDataSlot(owner);
        assertEq(uint256(vm.load(address(packed), packedSlot)), 1 | (uint256(2) << 64));
        assertEq(vm.load(address(packed), bytes32(uint256(packedSlot) + 1)), bytes32(0));
        assertEq(uint256(vm.load(address(full), fullSlot)), 1);
        assertEq(uint256(vm.load(address(full), bytes32(uint256(fullSlot) + 1))), 2);
        assertEq(packed.balanceOf(owner), 2);
        assertEq(full.balanceOf(owner), 2);
    }
}
