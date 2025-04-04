// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ERC721} from "solady/tokens/ERC721.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {Permittable} from "./base/Permittable.sol";
import {SlippageChecker} from "./base/SlippageChecker.sol";
import {ITokenURIGenerator} from "./interfaces/ITokenURIGenerator.sol";
import {TWAMMLib} from "./libraries/TWAMMLib.sol";
import {TWAMM, orderKeyToPoolKey, OrderKey, UpdateSaleRateParams, CollectProceedsParams} from "./extensions/TWAMM.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title Ekubo Revenue Buybacks
/// @author Moody Salem <moody@ekubo.org>
/// @notice Directs Ekubo Core protocol revenue towards buybacks
contract RevenueBuybacks is UsesCore, Ownable {
    constructor(ICore core) UsesCore(core) {}
}
