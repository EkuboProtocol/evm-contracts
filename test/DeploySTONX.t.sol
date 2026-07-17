// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {DeploySTONX} from "../script/DeploySTONX.s.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {Ve33, ve33CallPoints} from "../src/extensions/Ve33.sol";
import {Ve33Positions} from "../src/Ve33Positions.sol";
import {PoolKey} from "../src/types/poolKey.sol";

contract DeploySTONXHarness is DeploySTONX {
    function seedLiquidity(MintableERC20 stonx, Ve33 ve33, Ve33Positions positions, address usdg, address governance)
        external
        returns (uint256 positionId)
    {
        positionId = _seedLiquidity(stonx, ve33, positions, usdg, address(this), governance);
    }

    function stonxPoolKey(address stonx, address usdg, address ve33) external pure returns (PoolKey memory) {
        return _stonxPoolKey(stonx, usdg, ve33);
    }
}

contract DeploySTONXTest is FullTest {
    uint128 private constant STONX_AMOUNT = 333_333e18;
    uint128 private constant USDG_AMOUNT = 333_333e6;

    DeploySTONXHarness private deployer;
    MintableERC20 private stonx;
    Ve33 private ve33;
    Ve33Positions private ve33Positions;

    function setUp() public override {
        super.setUp();

        deployer = new DeploySTONXHarness();
        stonx = new MintableERC20(address(this), "Ekubo Stock Liquidity Token", "STONX");
        address ve33Address = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("Ve33.sol:Ve33", abi.encode(core, stonx), ve33Address);
        ve33 = Ve33(payable(ve33Address));
        ve33Positions = new Ve33Positions(core, ve33, address(this));

        stonx.mint(address(deployer), STONX_AMOUNT);
    }

    function test_seedLiquidityWhenSTONXIsToken0() public {
        _testSeedLiquidity(address(type(uint160).max - 1));
    }

    function test_seedLiquidityWhenSTONXIsToken1() public {
        _testSeedLiquidity(address(0x10000));
    }

    function _testSeedLiquidity(address usdgAddress) private {
        deployCodeTo("MintableERC20.sol:MintableERC20", abi.encode(address(this), "USDG", "USDG"), usdgAddress);
        MintableERC20 usdg = MintableERC20(usdgAddress);
        usdg.mint(address(deployer), USDG_AMOUNT);

        uint256 positionId = deployer.seedLiquidity(stonx, ve33, ve33Positions, usdgAddress, owner);
        PoolKey memory poolKey = deployer.stonxPoolKey(address(stonx), usdgAddress, address(ve33));
        (uint128 liquidity,,) = ve33Positions.getPositionLiquidity(positionId, poolKey, -88_722_432, 88_722_432);

        assertEq(ve33Positions.ownerOf(positionId), owner);
        assertEq(usdg.balanceOf(address(deployer)), 0);
        assertLe(stonx.balanceOf(address(deployer)), STONX_AMOUNT);
        assertGt(liquidity, 0);
    }
}
