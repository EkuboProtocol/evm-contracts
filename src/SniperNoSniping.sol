// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {LibString} from "solady/utils/LibString.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Orders} from "./Orders.sol";
import {OrderKey} from "./extensions/TWAMM.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {Positions} from "./Positions.sol";
import {Router} from "./Router.sol";

interface IPermanentAllowanceAddressProvider {
    /// @dev Returns whether the spender has a permanent allowance
    function hasPermanentAllowance(address spender) external pure returns (bool);
}

contract SNOSToken is ERC20 {
    address private immutable router;
    address private immutable positions;
    address private immutable orders;

    bytes32 private immutable _name;
    bytes32 private immutable _symbol;

    constructor(
        address _router,
        address _positions,
        address _orders,
        bytes32 __symbol,
        bytes32 __name,
        uint256 totalSupply
    ) {
        router = _router;
        positions = _positions;
        orders = _orders;

        _name = __name;
        _symbol = __symbol;

        _mint(msg.sender, totalSupply);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal override {
        // These SNOS tokens can be traded without any approval via these privileged contracts
        if (spender == router || spender == positions || spender == orders) return;

        super._spendAllowance(owner, spender, amount);
    }

    /// @dev Returns the name of the token.
    function name() public view override returns (string memory) {
        return LibString.unpackOne(_name);
    }

    /// @dev Returns the symbol of the token.
    function symbol() public view override returns (string memory) {
        return LibString.unpackOne(_symbol);
    }
}

/// @author Moody Salem <moody@ekubo.org>
/// @title Sniper No Sniping
/// @notice Launchpad for creating fair launches using Ekubo Protocol's TWAMM implementation
contract SniperNoSniping {
    Router private immutable router;
    Orders private immutable orders;
    Positions private immutable positions;

    /// @dev The duration of the sale for any newly created tokens
    uint32 public immutable orderDuration;
    /// @dev The minimum amount of time in the future that the order must start
    uint32 public immutable minLeadTime;

    /// @dev The total supply that all tokens are created with.
    uint112 public immutable tokenTotalSupply;

    /// @dev The fee of the pools that are used by this contract
    uint64 public immutable fee;

    error StartTimeTooSoon();

    struct TokenInfo {
        uint256 orderId;
    }

    mapping(SNOSToken => TokenInfo) public tokenInfo;

    constructor(
        Router _router,
        Positions _positions,
        Orders _orders,
        uint32 _orderDuration,
        uint32 _minLeadTime,
        uint112 _tokenTotalSupply
    ) {
        router = _router;
        positions = _positions;
        orders = _orders;

        orderDuration = _orderDuration;
        minLeadTime = _minLeadTime;
        tokenTotalSupply = _tokenTotalSupply;
    }

    function launch(address owner, bytes32 symbol, bytes32 name, uint256 startTime)
        external
        returns (SNOSToken token)
    {
        if (startTime < block.timestamp + minLeadTime) {
            revert StartTimeTooSoon();
        }

        token = new SNOSToken{salt: keccak256(abi.encode(msg.sender, symbol))}(
            address(router), address(positions), address(orders), symbol, name, tokenTotalSupply
        );

        (uint256 orderId,) = orders.mintAndIncreaseSellAmount(
            OrderKey({
                sellToken: address(token),
                buyToken: NATIVE_TOKEN_ADDRESS,
                fee: fee,
                startTime: startTime,
                endTime: startTime + orderDuration
            }),
            tokenTotalSupply,
            type(uint112).max
        );

        tokenInfo[token] = TokenInfo({orderId: orderId});
    }
}
