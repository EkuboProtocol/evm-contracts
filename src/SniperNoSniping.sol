// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {LibString} from "solady/utils/LibString.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {Orders} from "./Orders.sol";
import {SqrtRatio, toSqrtRatio} from "./types/sqrtRatio.sol";
import {sqrtRatioToTick, tickToSqrtRatio} from "./math/ticks.sol";
import {OrderKey} from "./extensions/TWAMM.sol";
import {NATIVE_TOKEN_ADDRESS, MIN_TICK, MAX_TICK} from "./math/constants.sol";
import {Positions} from "./Positions.sol";
import {Router} from "./Router.sol";
import {PoolKey, toConfig} from "./types/poolKey.sol";
import {Bounds} from "./types/positionKey.sol";

interface IPermanentAllowanceAddressProvider {
    /// @dev Returns whether the spender has a permanent allowance
    function hasPermanentAllowance(address spender) external pure returns (bool);
}

contract SNOSToken is ERC20 {
    address private immutable router;
    address private immutable positions;
    address private immutable orders;

    bytes32 private immutable _name;
    bytes32 private immutable constantNameHash;
    bytes32 private immutable _symbol;

    /// @dev The balance slot of `owner` is given by:
    /// ```
    ///     mstore(0x0c, _BALANCE_SLOT_SEED)
    ///     mstore(0x00, owner)
    ///     let balanceSlot := keccak256(0x0c, 0x20)
    /// ```
    uint256 private constant _BALANCE_SLOT_SEED = 0x87a211a2;

    /// @dev The allowance slot of (`owner`, `spender`) is given by:
    /// ```
    ///     mstore(0x20, spender)
    ///     mstore(0x0c, _ALLOWANCE_SLOT_SEED)
    ///     mstore(0x00, owner)
    ///     let allowanceSlot := keccak256(0x0c, 0x34)
    /// ```
    uint256 private constant _ALLOWANCE_SLOT_SEED = 0x7f5e9f20;

    /// @dev `keccak256(bytes("Transfer(address,address,uint256)"))`.
    uint256 private constant _TRANSFER_EVENT_SIGNATURE =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

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

        constantNameHash = keccak256(bytes(LibString.unpackOne(_name)));

        _mint(msg.sender, totalSupply);
    }

    function allowance(address owner, address spender) public view override returns (uint256 result) {
        if (spender == router || spender == positions || spender == orders) return type(uint256).max;
        result = super.allowance(owner, spender);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address _router = router;
        address _positions = positions;
        address _orders = orders;

        assembly ("memory-safe") {
            let from_ := shl(96, from)
            if iszero(
                or(
                    or(or(eq(caller(), _PERMIT2), eq(caller(), _router)), eq(caller(), _positions)),
                    eq(caller(), _orders)
                )
            ) {
                // Compute the allowance slot and load its value.
                mstore(0x20, caller())
                mstore(0x0c, or(from_, _ALLOWANCE_SLOT_SEED))
                let allowanceSlot := keccak256(0x0c, 0x34)
                let allowance_ := sload(allowanceSlot)
                // If the allowance is not the maximum uint256 value.
                if not(allowance_) {
                    // Revert if the amount to be transferred exceeds the allowance.
                    if gt(amount, allowance_) {
                        mstore(0x00, 0x13be252b) // `InsufficientAllowance()`.
                        revert(0x1c, 0x04)
                    }
                    // Subtract and store the updated allowance.
                    sstore(allowanceSlot, sub(allowance_, amount))
                }
            }
            // Compute the balance slot and load its value.
            mstore(0x0c, or(from_, _BALANCE_SLOT_SEED))
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            // Revert if insufficient balance.
            if gt(amount, fromBalance) {
                mstore(0x00, 0xf4d678b8) // `InsufficientBalance()`.
                revert(0x1c, 0x04)
            }
            // Subtract and store the updated balance.
            sstore(fromBalanceSlot, sub(fromBalance, amount))
            // Compute the balance slot of `to`.
            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            // Add and store the updated balance of `to`.
            // Will not overflow because the sum of all user balances
            // cannot exceed the maximum uint256 value.
            sstore(toBalanceSlot, add(sload(toBalanceSlot), amount))
            // Emit the {Transfer} event.
            mstore(0x20, amount)
            log3(0x20, 0x20, _TRANSFER_EVENT_SIGNATURE, shr(96, from_), shr(96, mload(0x0c)))
        }

        return true;
    }

    /// @dev Returns the name of the token.
    function name() public view override returns (string memory) {
        return LibString.unpackOne(_name);
    }

    /// @dev Returns the symbol of the token.
    function symbol() public view override returns (string memory) {
        return LibString.unpackOne(_symbol);
    }

    function _constantNameHash() internal view override returns (bytes32 result) {
        result = constantNameHash;
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
    uint80 public immutable tokenTotalSupply;

    /// @dev The fee of the pools that are used by this contract
    uint64 public immutable fee;

    /// @dev The tick spacing of the pool that is created post-graduation
    uint32 public immutable tickSpacing;

    /// @dev The ID of the order that is used for all sale NFTs
    uint256 public immutable orderId;
    /// @dev The ID of the position that is used for all positions created by this contract
    uint256 public immutable positionId;

    /// @dev The min/max usable tick, based on tick spacing
    int32 public immutable minUsableTick;
    int32 public immutable maxUsableTick;

    error StartTimeTooSoon();
    error SaleStillOngoing();
    error NoProceeds();

    struct TokenInfo {
        uint64 endTime;
        address creator;
        int32 saleEndTick;
    }

    mapping(SNOSToken => TokenInfo) public tokenInfos;

    constructor(
        Router _router,
        Positions _positions,
        Orders _orders,
        uint32 _orderDuration,
        uint32 _minLeadTime,
        uint80 _tokenTotalSupply,
        uint64 _fee,
        uint32 _tickSpacing
    ) {
        router = _router;
        positions = _positions;
        orders = _orders;

        orderDuration = _orderDuration;
        minLeadTime = _minLeadTime;
        tokenTotalSupply = _tokenTotalSupply;
        fee = _fee;
        tickSpacing = _tickSpacing;

        orderId = orders.mint();
        positionId = positions.mint();

        minUsableTick = (MIN_TICK / int32(_tickSpacing)) * int32(_tickSpacing);
        maxUsableTick = (MAX_TICK / int32(_tickSpacing)) * int32(_tickSpacing);
    }

    event Launched(address token, address owner, uint256 startTime, uint256 endTime);

    function launch(bytes32 salt, bytes32 symbol, bytes32 name, uint256 startTime) external returns (SNOSToken token) {
        if (startTime < block.timestamp + minLeadTime) {
            revert StartTimeTooSoon();
        }

        token = new SNOSToken{salt: keccak256(abi.encode(msg.sender, salt))}(
            address(router), address(positions), address(orders), symbol, name, tokenTotalSupply
        );

        positions.maybeInitializePool(
            PoolKey({token0: address(0), token1: address(token), config: toConfig(fee, 0, address(orders.twamm()))}), 0
        );

        uint256 endTime = startTime + orderDuration;
        require(endTime < type(uint64).max);

        orders.increaseSellAmount(
            orderId,
            OrderKey({
                sellToken: address(token),
                buyToken: NATIVE_TOKEN_ADDRESS,
                fee: fee,
                startTime: startTime,
                endTime: endTime
            }),
            tokenTotalSupply,
            type(uint112).max
        );

        tokenInfos[token] = TokenInfo({endTime: uint64(endTime), creator: msg.sender, saleEndTick: 0});

        emit Launched(address(token), msg.sender, startTime, endTime);
    }

    function graduate(SNOSToken token) external returns (uint256 proceeds) {
        TokenInfo memory tokenInfo = tokenInfos[token];

        if (block.timestamp < tokenInfo.endTime) {
            revert SaleStillOngoing();
        }

        proceeds = orders.collectProceeds(
            orderId,
            OrderKey({
                sellToken: address(token),
                buyToken: NATIVE_TOKEN_ADDRESS,
                fee: fee,
                startTime: tokenInfo.endTime - orderDuration,
                endTime: tokenInfo.endTime
            })
        );

        // This will also trigger if graduate has already been called
        if (proceeds == 0) {
            revert NoProceeds();
        }

        PoolKey memory graduationPool =
            PoolKey({token0: address(0), token1: address(token), config: toConfig(fee, tickSpacing, address(0))});

        // computes the number of tokens that people received per eth, rounded down
        SqrtRatio sqrtSaleRatio =
            toSqrtRatio(FixedPointMathLib.sqrt((uint256(tokenTotalSupply) << 176) / proceeds) << 40, false);

        int32 saleTick = sqrtRatioToTick(sqrtSaleRatio);
        // todo: round towards negative infinity
        saleTick -= saleTick % int32(tickSpacing);

        (bool didInitialize, SqrtRatio sqrtRatioCurrent) = positions.maybeInitializePool(graduationPool, saleTick);

        uint256 purchasedTokens;

        // someone already created the graduation pool, buy up all the way to that price
        if (!didInitialize) {
            SqrtRatio targetRatio = tickToSqrtRatio(saleTick);
            // if the price is lower than average sale price, i.e. eth is too expensive in terms of tokens, we need to buy any leftover
            if (sqrtRatioCurrent > targetRatio) {
                (int128 delta0, int128 delta1) = router.swap(
                    graduationPool, false, int128(int256(uint256(proceeds))), targetRatio, 0, 0, address(this)
                );

                proceeds -= uint256(int256(delta0));
                purchasedTokens += uint256(-int256(delta1));
            }
        }

        positions.deposit{value: proceeds}(
            positionId, graduationPool, Bounds(saleTick - int32(tickSpacing), saleTick), uint128(proceeds), 0, 0
        );

        if (purchasedTokens > 0) {
            positions.deposit(
                positionId,
                graduationPool,
                Bounds(saleTick, (MAX_TICK / int32(tickSpacing)) * int32(tickSpacing)),
                0,
                uint128(purchasedTokens),
                0
            );
        }
    }

    receive() external payable {}
}
