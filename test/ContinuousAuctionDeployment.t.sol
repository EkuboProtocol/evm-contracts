// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {DeployContinuousAuction} from "../script/DeployContinuousAuction.s.sol";
import {DETERMINISTIC_DEPLOYER} from "../script/DeployAll.s.sol";
import {ICore, IExtension} from "../src/interfaces/ICore.sol";
import {ExtensionCallPointsLib} from "../src/libraries/ExtensionCallPointsLib.sol";
import {Locker} from "../src/types/locker.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {createConcentratedPoolConfig} from "../src/types/poolConfig.sol";
import {ContinuousAuction, continuousAuctionCallPoints} from "../src/extensions/ContinuousAuction.sol";
import {AuctionPositions} from "../src/AuctionPositions.sol";

contract AuctionDeploymentHarness is DeployContinuousAuction {
    function deploy(ICore core, address token, address owner, bytes32 salt)
        external
        returns (ContinuousAuction auction, AuctionPositions positions)
    {
        return _deploy(core, token, owner, salt, address(0), address(0));
    }
}

contract AuctionTestCreate2Factory {
    fallback() external payable {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(ptr, 32, sub(calldatasize(), 32))
            let deployed := create2(callvalue(), ptr, sub(calldatasize(), 32), calldataload(0))
            if iszero(deployed) { revert(0, 0) }
            mstore(ptr, deployed)
            return(ptr, 32)
        }
    }
}

contract ContinuousAuctionDeploymentTest is FullTest {
    using ExtensionCallPointsLib for IExtension;

    /// @dev V12 8386/291869: Yul AND is bitwise; the iszero result masks the shifted flag with 1.
    function test_audit291869_callbackBitsAreIndividuallyMasked() public pure {
        IExtension extension = IExtension(address(uint160(0x51) << 152));
        Locker locker = Locker.wrap(bytes32(uint256(uint160(address(0x1234)))));
        assertTrue(extension.shouldCallBeforeInitializePool(locker.addr()));
        assertFalse(extension.shouldCallAfterInitializePool(locker.addr()));
        assertTrue(extension.shouldCallBeforeSwap(locker));
        assertFalse(extension.shouldCallAfterSwap(locker));
        assertTrue(extension.shouldCallBeforeUpdatePosition(locker));
        assertFalse(extension.shouldCallAfterUpdatePosition(locker));
        assertFalse(extension.shouldCallBeforeCollectFees(locker));
        assertFalse(extension.shouldCallAfterCollectFees(locker));
    }

    function test_deterministicDeploymentAndReuse() public {
        AuctionTestCreate2Factory factory = new AuctionTestCreate2Factory();
        vm.etch(DETERMINISTIC_DEPLOYER, address(factory).code);
        AuctionDeploymentHarness deployer = new AuctionDeploymentHarness();
        bytes32 salt = keccak256("ContinuousAuction launch");
        (ContinuousAuction auction, AuctionPositions manager) = deployer.deploy(core, address(0), owner, salt);
        assertEq(uint8(uint160(address(auction)) >> 152), continuousAuctionCallPoints().toUint8());
        assertEq(auction.bidToken(), address(0));
        assertEq(address(manager.auction()), address(auction));
        assertEq(manager.owner(), owner);
        assertLe(address(auction).code.length, 24576);
        assertLe(address(manager).code.length, 24576);
        PoolKey memory key = PoolKey({
            token0: address(token0),
            token1: address(token1),
            config: createConcentratedPoolConfig(0, 16, address(auction))
        });
        auction.createPool(key, 0, 1 << 56, 0, 3600, 500);
        (uint256 id, uint128 liquidity) = createPosition(key, -1600, 1600, 1e18, 1e18);
        positions.collectFees(id, key, -1600, 1600);
        positions.withdraw(id, key, -1600, 1600, liquidity);
        (ContinuousAuction again, AuctionPositions againManager) = deployer.deploy(core, address(0), owner, salt);
        assertEq(address(again), address(auction));
        assertEq(address(againManager), address(manager));
    }
}
