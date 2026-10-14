// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {IFlashAccountant} from "../../src/interfaces/IFlashAccountant.sol";
import {IZeroSeedLaunch} from "../../src/interfaces/extensions/IZeroSeedLaunch.sol";
import {ZeroSeedLaunch, zeroSeedLaunchCallPoints} from "../../src/extensions/ZeroSeedLaunch.sol";
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
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {computeFee, amountBeforeFee} from "../../src/math/fee.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {ZeroSeedLaunchBase, DecimalsToken} from "./ZeroSeedLaunch.t.sol";

// Adversarial tests and negative controls ported from the EKU-1521 review of 39ca191, adapted to the
// constructor-bound quote token. Local fixtures only.

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

    function _createWith(address quote, address who)
        internal
        returns (IZeroSeedLaunch.Installation memory inst, IZeroSeedLaunch.LaunchParameters memory p)
    {
        p = _parameters(quote, ASK_18_18, REQUESTED_SUPPLY, DURATION);
        _bind(p, who);
        vm.prank(who);
        inst = launch.create(p);
        MintableERC20(inst.token).approve(address(swapper), type(uint256).max);
    }

    /// @dev Second extension instance at another callpoint-valid address bound to `quote`.
    function _secondLaunch(address quote) internal returns (ZeroSeedLaunch second) {
        address target = address(uint160(_launchTarget()) | 0xbad);
        deployCodeTo("ZeroSeedLaunch.sol:ZeroSeedLaunch", abi.encode(CORE, quote), target);
        second = ZeroSeedLaunch(target);
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
                ERC20(inst.poolKey.token0).balanceOf(CORE),
                ERC20(inst.poolKey.token1).balanceOf(CORE),
                PoolState.unwrap(ICore(CORE).poolState(inst.poolKey.toPoolId()))
            )
        );
    }
}

/// M-1: one constructor-bound quote. Every other quote is refused by create and preview in both orders.
contract ZeroSeedLaunchQuoteTest is AdversarialBase {
    using CoreLib for ICore;

    function test_constructor_refusesNativeAndCodeless() public {
        address target = address(uint160(_launchTarget()) | 0xbad);
        address[2] memory bad = [address(0), address(0xdead)];
        for (uint256 i; i < 2; i++) {
            vm.etch(target, abi.encodePacked(vm.getCode("ZeroSeedLaunch.sol:ZeroSeedLaunch"), abi.encode(CORE, bad[i])));
            (bool ok, bytes memory reason) = target.call("");
            assertFalse(ok, "constructor refuses");
            assertEq(bytes4(reason), IZeroSeedLaunch.UnsupportedQuoteToken.selector, "reason");
        }
        // Registration rolled back with the constructor: a valid deployment at the same address still works.
        assertEq(
            vm.load(CORE, StorageSlot.unwrap(CoreStorageLayout.isExtensionRegisteredSlot(target))),
            bytes32(0),
            "not registered"
        );
        ZeroSeedLaunch ok_ = _secondLaunch(QUOTE_HIGH);
        assertEq(ok_.quoteToken(), QUOTE_HIGH);
    }

    function test_quoteToken_isWethFixture() public {
        assertEq(launch.quoteToken(), QUOTE_HIGH, "bound quote");
        assertEq(QUOTE_HIGH.codehash, WETH9_CODEHASH, "real WETH9 runtime");
        assertEq(ERC20(QUOTE_HIGH).decimals(), 18);
        assertEq(ERC20(QUOTE_HIGH).symbol(), "WETH");
        assertEq(ERC20(QUOTE_HIGH).name(), "Wrapped Ether");
        bytes32 highHash = address(launch).codehash;
        console2.log("PIN|runtime|quoteHigh");
        console2.logBytes32(highHash);
        _quote(false, 18);
        assertEq(launch.quoteToken(), QUOTE_LOW);
        assertEq(QUOTE_LOW.codehash, WETH9_CODEHASH);
        assertTrue(highHash != address(launch).codehash, "quote immutable changes runtime");
        console2.log("PIN|runtime|quoteLow");
        console2.logBytes32(address(launch).codehash);
    }

    /// @dev Extension bound to WETH at one end of the address space, the unsupported quote at the other, so both
    /// launch-token orders are attempted with each unsupported quote.
    function test_unsupportedQuotes_refusedByCreateAndPreview_bothOrders() public {
        for (uint256 order; order < 2; order++) {
            uint256 snap = vm.snapshotState();
            bool wethHigh = order == 0;
            address weth = _quote(wethHigh, 18);
            address other = wethHigh ? QUOTE_LOW : QUOTE_HIGH;
            for (uint256 kind; kind < 4; kind++) {
                if (kind == 0) {
                    _evilAt(other); // hostile controller (tax / lie / block / hook)
                } else if (kind == 1) {
                    deployCodeTo("ZeroSeedLaunch.t.sol:DecimalsToken", abi.encode(address(this), 18), other);
                } else if (kind == 2) {
                    vm.etch(other, vm.parseBytes(vm.trim(vm.readFile(WETH9_FIXTURE)))); // same code, other address
                } else {
                    other = address(0); // native
                }
                IZeroSeedLaunch.LaunchParameters memory p = _parameters(other, ASK_18_18, REQUESTED_SUPPLY, DURATION);
                vm.expectRevert(IZeroSeedLaunch.UnsupportedQuoteToken.selector);
                launch.previewInstallation(creator, p);
                p.liquidity = 1e24;
                vm.prank(creator);
                vm.expectRevert(IZeroSeedLaunch.UnsupportedQuoteToken.selector);
                launch.create(p);
            }
            // The bound quote still works in the same state.
            (IZeroSeedLaunch.Installation memory inst,) = _createWith(weth, creator);
            assertEq(inst.poolKey.token0 == inst.token, wethHigh, "order");
            vm.revertToState(snap);
        }
    }

    /// @dev Integration refusal: no pool for an unsupported quote can exist under this extension, so routing,
    /// lying settlement and forwarded swaps all fail with no state change.
    function test_unsupportedQuote_integrationRefusal() public {
        (IZeroSeedLaunch.Installation memory wethLaunch,) = _createWith(QUOTE_HIGH, creator);
        bytes32 before = _ledgerAndPrincipal(wethLaunch);
        EvilQuote evil = _evilAt(QUOTE_LOW);
        PoolKey memory key = PoolKey({token0: QUOTE_LOW, token1: wethLaunch.token, config: wethLaunch.poolKey.config});
        vm.expectRevert(IZeroSeedLaunch.InitializeThroughCreateOnly.selector);
        ICore(CORE).initializePool(key, 0);
        vm.warp(START);
        vm.expectRevert(IZeroSeedLaunch.UnknownLaunch.selector);
        swapper.forwardSwap(key, createSwapParameters(SqrtRatio.wrap(0), 1e18, false, 0));
        LyingPayer attacker = new LyingPayer(ICore(CORE));
        vm.expectRevert(IZeroSeedLaunch.UnknownLaunch.selector);
        attacker.drain(key, createSwapParameters(SqrtRatio.wrap(0), -1e24, true, 0), address(evil), wethLaunch.token);
        assertEq(_ledgerAndPrincipal(wethLaunch), before, "WETH launch untouched");
    }

    /// @dev Negative control for the constructor trust boundary: an instance deliberately deployed with a hostile
    /// quote is exactly as unsafe as 39ca191 was for that quote. The restriction is only as good as the constructor
    /// input; it is not a screen of the token. The WETH-bound instance on the same Core is unaffected.
    function test_constructorTrust_hostileInstanceStillDrainable() public {
        (IZeroSeedLaunch.Installation memory wethLaunch,) = _createWith(QUOTE_HIGH, creator);
        bytes32 before = _ledgerAndPrincipal(wethLaunch);
        EvilQuote evil = _evilAt(QUOTE_LOW);
        ZeroSeedLaunch hostile = _secondLaunch(address(evil));
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(address(evil), ASK_18_18, REQUESTED_SUPPLY, DURATION);
        IZeroSeedLaunch.Installation memory preview = hostile.previewInstallation(creator, p);
        p.liquidity = preview.liquidity;
        p.supply = preview.installedSupply;
        vm.prank(creator);
        IZeroSeedLaunch.Installation memory inst = hostile.create(p);
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
        console2.log("VEC|adversarial|hostileConstructorDrain|got=", got, "fakePaid=", owed);
        assertEq(_ledgerAndPrincipal(wethLaunch), before, "WETH launch untouched");
    }

    /// @dev I-4 rerun next to the WETH deployment: a hostile-callback quote steals the in-flight payment snapshot in
    /// a nested lock, the outer settlement reverts, nothing is taken, and the WETH launch is unaffected.
    function test_settlementSnapshotTheft_failsClosed_wethLaunchUnaffected() public {
        (IZeroSeedLaunch.Installation memory wethLaunch,) = _createWith(QUOTE_HIGH, creator);
        EvilQuote evil = _evilAt(QUOTE_LOW);
        ZeroSeedLaunch hostile = _secondLaunch(address(evil));
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(address(evil), ASK_18_18, REQUESTED_SUPPLY, DURATION);
        IZeroSeedLaunch.Installation memory preview = hostile.previewInstallation(creator, p);
        p.liquidity = preview.liquidity;
        p.supply = preview.installedSupply;
        vm.prank(creator);
        IZeroSeedLaunch.Installation memory inst = hostile.create(p);
        SnapshotThief thief = new SnapshotThief(ICore(CORE), address(evil));
        evil.setHook(address(thief));
        vm.warp(START);
        thief.arm();
        bytes32 hostileBefore = PoolState.unwrap(ICore(CORE).poolState(inst.poolKey.toPoolId()));
        vm.expectRevert(); // outer DebtsNotZeroed: the stolen credit is the outer payment
        _buy(inst.poolKey, inst.token, 10e18, false);
        assertEq(evil.balanceOf(address(thief)), 0, "nothing stolen");
        assertEq(PoolState.unwrap(ICore(CORE).poolState(inst.poolKey.toPoolId())), hostileBefore);
        // The WETH launch trades normally afterwards and keeps its ledger.
        PoolBalanceUpdate u = _buy(wethLaunch.poolKey, wethLaunch.token, 1e18, false);
        assertGt(uint128(-u.delta0()), 0, "WETH launch trades");
        _assertLedger(wethLaunch, QUOTE_HIGH, 1e18, 0, MAX_DUST);
    }
}

/// L-1 / L-2: recipient sinks refused, claim is atomic over both assets.
contract ZeroSeedLaunchClaimTest is AdversarialBase {
    using CoreLib for ICore;

    function _withFees(bool tokenIs0) internal returns (IZeroSeedLaunch.Installation memory inst) {
        (inst,) = _create(tokenIs0, 18, DURATION);
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
            address[5] memory sinks = [address(0), CORE, address(launch), inst.poolKey.token0, inst.poolKey.token1];
            for (uint256 k; k < sinks.length; k++) {
                vm.prank(creator);
                vm.expectRevert(IZeroSeedLaunch.InvalidRecipient.selector);
                launch.claimFees(inst.poolKey, sinks[k]);
                assertEq(_ledgerAndPrincipal(inst), before, "ledger, principal and Core balances unchanged");
            }
            // Valid alternatives: the creator itself, an EOA and a contract that is not a sink.
            address[3] memory ok = [creator, feeRecipient, address(swapper)];
            (uint128 f0, uint128 f1) = launch.creatorFees(inst.poolKey);
            vm.prank(creator);
            (uint128 c0, uint128 c1) = launch.claimFees(inst.poolKey, ok[0]);
            assertEq(c0, f0);
            assertEq(c1, f1);
            _buy(inst.poolKey, inst.token, 1e18, false);
            vm.prank(creator);
            (c0, c1) = launch.claimFees(inst.poolKey, ok[1]);
            assertGt(uint256(c0) + c1, 0);
            assertEq(ERC20(inst.token).balanceOf(ok[1]), inst.poolKey.token0 == inst.token ? c0 : c1);
            _buy(inst.poolKey, inst.token, 1e18, false);
            vm.prank(creator);
            launch.claimFees(inst.poolKey, ok[2]);
            vm.revertToState(snap);
        }
    }

    /// @dev Fault injection: the quote transfer to the recipient fails. Both ledgers, principal and Core balances
    /// roll back; a retry to another recipient pays both assets in full.
    function test_claim_atomicRollback_bothOrders() public {
        for (uint256 i; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            IZeroSeedLaunch.Installation memory inst = _withFees(i == 0);
            (uint128 f0, uint128 f1) = launch.creatorFees(inst.poolKey);
            bool tokenIs0 = inst.poolKey.token0 == inst.token;
            address quote = tokenIs0 ? inst.poolKey.token1 : inst.poolKey.token0;
            uint128 quoteFee = tokenIs0 ? f1 : f0;
            bytes32 before = _ledgerAndPrincipal(inst);
            vm.mockCallRevert(quote, abi.encodeCall(ERC20.transfer, (feeRecipient, quoteFee)), "refused");
            vm.prank(creator);
            vm.expectRevert();
            launch.claimFees(inst.poolKey, feeRecipient);
            assertEq(_ledgerAndPrincipal(inst), before, "both ledgers rolled back");
            assertEq(ERC20(inst.token).balanceOf(feeRecipient), 0, "no token side paid");
            vm.clearMockedCalls();
            address retry = makeAddr("retry");
            vm.prank(creator);
            (uint128 c0, uint128 c1) = launch.claimFees(inst.poolKey, retry);
            assertEq(c0, f0);
            assertEq(c1, f1);
            assertEq(ERC20(inst.poolKey.token0).balanceOf(retry), f0);
            assertEq(ERC20(inst.poolKey.token1).balanceOf(retry), f1);
            vm.revertToState(snap);
        }
    }

    /// @dev WETH9 has no transfer hook, so a creator contract cannot re-enter during the claim. The ledger is still
    /// cleared before the transfers (checked through a hostile-callback instance).
    function test_reentrantClaim_noDoubleSpend_hostileInstance() public {
        EvilQuote evil = _evilAt(QUOTE_LOW);
        ZeroSeedLaunch hostile = _secondLaunch(address(evil));
        ReentrantCreator rc = new ReentrantCreator(hostile);
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(address(evil), ASK_18_18, REQUESTED_SUPPLY, DURATION);
        IZeroSeedLaunch.Installation memory preview = hostile.previewInstallation(address(rc), p);
        p.liquidity = preview.liquidity;
        p.supply = preview.installedSupply;
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
        assertEq(rc.second0() + rc.second1(), 0, "re-entrant claim gets nothing");
        assertEq(rc.viewDuring0() + rc.viewDuring1(), 0, "ledger cleared before transfer");
        assertEq(evil.balanceOf(address(rc)), inst.poolKey.token0 == address(evil) ? f0 : f1, "quote paid once");
    }
}

/// @dev Creator contract whose quote-receipt hook re-enters claimFees.
contract ReentrantCreator is IQuoteHook {
    ZeroSeedLaunch immutable launch;
    PoolKey key;
    bool reentered;
    uint128 public second0;
    uint128 public second1;
    uint128 public viewDuring0;
    uint128 public viewDuring1;

    constructor(ZeroSeedLaunch l) {
        launch = l;
    }

    function createLaunch(IZeroSeedLaunch.LaunchParameters memory p)
        external
        returns (IZeroSeedLaunch.Installation memory inst)
    {
        inst = launch.create(p);
        key = inst.poolKey;
    }

    function claim() external returns (uint128, uint128) {
        return launch.claimFees(key, address(this));
    }

    function onQuoteTransfer(address, address to, uint256) external {
        if (to != address(this) || reentered) return;
        reentered = true;
        (viewDuring0, viewDuring1) = launch.creatorFees(key);
        (second0, second1) = launch.claimFees(key, address(this));
    }
}

/// L-4 and L-3: shared preview/create validation, collision refusal, start boundaries.
contract ZeroSeedLaunchPreviewStartTest is AdversarialBase {
    using CoreLib for ICore;

    function test_metadataBounds_sharedByPreviewAndCreate() public {
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(QUOTE_HIGH, ASK_18_18, REQUESTED_SUPPLY, DURATION);
        string memory len31 = "abcdefghijklmnopqrstuvwxyz01234";
        string memory len32 = "abcdefghijklmnopqrstuvwxyz012345";
        for (uint256 field; field < 2; field++) {
            IZeroSeedLaunch.LaunchParameters memory q = abi.decode(abi.encode(p), (IZeroSeedLaunch.LaunchParameters));
            if (field == 0) q.name = len32;
            else q.symbol = len32;
            vm.expectRevert(IZeroSeedLaunch.MetadataTooLong.selector);
            launch.previewInstallation(creator, q);
            q.liquidity = 1e24;
            vm.prank(creator);
            vm.expectRevert(IZeroSeedLaunch.MetadataTooLong.selector);
            launch.create(q);
        }
        p.name = len31;
        p.symbol = len31;
        _bind(p, creator);
        vm.prank(creator);
        IZeroSeedLaunch.Installation memory inst = launch.create(p);
        assertEq(MintableERC20(inst.token).name(), len31);
        assertEq(MintableERC20(inst.token).symbol(), len31);
        // The bound is in bytes, not characters: 11 three-byte characters (33 bytes) are refused.
        p.salt = bytes32(uint256(2));
        p.name = unicode"€€€€€€€€€€€";
        vm.expectRevert(IZeroSeedLaunch.MetadataTooLong.selector);
        launch.previewInstallation(creator, p);
    }

    function test_collision_refusedPredictably_otherSaltOrMetadataIndependent() public {
        (IZeroSeedLaunch.Installation memory first, IZeroSeedLaunch.LaunchParameters memory p) =
            _create(true, 18, DURATION);
        bytes memory exists = abi.encodeWithSelector(IZeroSeedLaunch.LaunchTokenExists.selector, first.token);
        vm.expectRevert(exists);
        launch.previewInstallation(creator, p);
        vm.prank(creator);
        vm.expectRevert(exists);
        launch.create(p);
        // Same salt, different metadata: different token address, accepted.
        IZeroSeedLaunch.LaunchParameters memory q = abi.decode(abi.encode(p), (IZeroSeedLaunch.LaunchParameters));
        q.symbol = "ZERO2";
        q.supply = REQUESTED_SUPPLY;
        _bind(q, creator);
        vm.prank(creator);
        IZeroSeedLaunch.Installation memory second = launch.create(q);
        assertTrue(second.token != first.token, "distinct token");
        // Different salt, same metadata: accepted.
        q = abi.decode(abi.encode(p), (IZeroSeedLaunch.LaunchParameters));
        q.salt = bytes32(uint256(99));
        q.supply = REQUESTED_SUPPLY;
        _bind(q, creator);
        vm.prank(creator);
        launch.create(q);
    }

    /// @dev Contract-side start boundaries at block time T. These are the only rules the contract enforces; it has
    /// no start-delay cap. Producer rules (margin, cap, expiry <= start) live in the vectors file.
    function test_startBoundaries() public {
        uint64 t = 5000;
        vm.warp(t);
        IZeroSeedLaunch.LaunchParameters memory p = _parameters(QUOTE_HIGH, ASK_18_18, REQUESTED_SUPPLY, DURATION);
        uint64[5] memory starts = [t - 1, t, t + 1, t + 86_400, type(uint64).max];
        for (uint256 i; i < starts.length; i++) {
            uint256 snap = vm.snapshotState();
            p.tradingStart = starts[i];
            p.supply = REQUESTED_SUPPLY;
            if (starts[i] < t) {
                vm.expectRevert(IZeroSeedLaunch.InvalidTradingStart.selector);
                launch.previewInstallation(creator, p);
                p.liquidity = 1e24;
                vm.prank(creator);
                vm.expectRevert(IZeroSeedLaunch.InvalidTradingStart.selector);
                launch.create(p);
                console2.log(string.concat("VEC|start|T=5000|start=", _ustr(starts[i]), "|create=InvalidTradingStart"));
                vm.revertToState(snap);
                continue;
            }
            _bind(p, creator);
            vm.prank(creator);
            IZeroSeedLaunch.Installation memory inst = launch.create(p);
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
        IZeroSeedLaunch.Installation memory planned = launch.previewInstallation(creator, p);
        vm.warp(t + 1);
        vm.prank(creator);
        vm.expectRevert(IZeroSeedLaunch.InvalidTradingStart.selector);
        launch.create(p);
        assertEq(planned.token.code.length, 0, "no token");
        assertFalse(ICore(CORE).poolState(planned.poolKey.toPoolId()).isInitialized(), "no pool");
    }
}

/// Fee sign/conservation per forwarded swap on the WETH fixture, from the emitted event and the Core ledger.
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
        (IZeroSeedLaunch.Installation memory inst,) = _create(tokenIs0, 18, DURATION);
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
            uint256 t0 = ERC20(key.token0).balanceOf(address(this));
            uint256 t1 = ERC20(key.token1).balanceOf(address(this));
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
            assertEq(int256(t0) - int256(ERC20(key.token0).balanceOf(address(this))), int256(u.delta0()), "user0");
            assertEq(int256(t1) - int256(ERC20(key.token1).balanceOf(address(this))), int256(u.delta1()), "user1");
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
            assertLe(uint256(p0) + n0, ERC20(key.token0).balanceOf(CORE), "Core0 >= principal+fee");
            assertLe(uint256(p1) + n1, ERC20(key.token1).balanceOf(CORE), "Core1 >= principal+fee");
        }
    }

    function test_dustTradesPayFee() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, DURATION);
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

/// Bypass, authority, minter and amount-extreme checks on the WETH fixture.
contract ZeroSeedLaunchBypassTest is AdversarialBase {
    using CoreLib for ICore;

    function test_bypass_zeroDeltaPositionAndAccumulateAndCollect() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, DURATION);
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
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, DURATION);
        vm.warp(START);
        PoolKey memory k = inst.poolKey;
        k.config = PoolConfig.wrap(bytes32((uint256(uint160(address(launch))) << 96) | 0x80000000 | uint256(200)));
        vm.expectRevert(IZeroSeedLaunch.UnknownLaunch.selector);
        swapper.forwardSwap(k, createSwapParameters(SqrtRatio.wrap(0), 1e18, true, 0));
    }

    function test_minterRenounced_noHandover_permit2Disclosed() public {
        (IZeroSeedLaunch.Installation memory inst,) = _create(true, 18, DURATION);
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
        assertEq(t.totalSupply(), inst.installedSupply);
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
        (IZeroSeedLaunch.Installation memory inst,) = _create(tokenIs0, 18, DURATION);
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
