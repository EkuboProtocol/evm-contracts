# V12 run 7806: verification and disposition

[Audit report](https://v12.sh/runs/7806), against `042418e50d3fe2486635447f51d7e60d7d23f5fe`, scoped to FreeLP and PoolKeyIndex.

All five findings were independently exercised using real Core/token/extension interactions in `test/FreeLPAudit.t.sol`. No mock Core receipts or balances substitute for settlement. Native account funding uses the test VM.

## 277790: native surplus — acknowledged, caller-managed refund policy

The report's cross-transaction surplus claim is expected behavior. Refunds are optional and the caller's responsibility: include `refundNativeToken` in the same atomic manager multicall when returning leftovers is worth the gas, or intentionally leave small leftovers. FreeLP is not a custody contract. Unassigned ETH remains permissionlessly spendable/refundable.

The separate callback case was reproduced even with `[createPosition, refundNativeToken]` in one multicall. The malicious token's payment callback refunded approximately 2 ETH to itself before the outer refund. A second reproduction minted an attacker-owned native-only position from the same surplus without contributing ETH.

Per explicit owner direction after the initial triage, `NativePaymentScope` has been removed and the original `PayableMulticallable` behavior restored. The shared-balance callback behavior is accepted rather than mitigated by per-caller isolation. This supersedes the earlier V12 comment that described isolation as a retained fix. There are no forced refunds or zero-ending-balance requirements. Deposit ownership/liquidity and combined-withdrawal overflow fixes are retained.

Behavior tests: `test_auditSharedNativeBalanceIsAvailableToCallbackRefund`, `test_auditSharedNativeBalanceIsAvailableToCallbackDeposit`, `test_auditNestedCallerCanDepositItsOwnNativeFunds`, `test_auditExplicitRefundReturnsNativeSurplus`, `test_auditUnassignedNativeBalanceRemainsPermissionlesslyRefundable`, `test_auditNativeDepositMayLeaveLeftoversWithoutRefund`.

## 277795: deposit callback mutations — fixed

Both approved-extension cases reproduced: removing the just-added liquidity while the original position remained open, and transferring the NFT during addition. The tests failed against the audited revision because neither operation reverted. This requires an approved callback actor; it is not an unapproved arbitrary withdrawal.

Deposit settlement now checks owner continuity and a lower bound of prior liquidity plus the requested addition after callbacks. Existing burn and signed-liquidity protections remain.

Regressions: `test_auditAddedLiquidityCannotBeWithdrawnDuringCallback`, `test_auditDepositCannotChangeOwnerDuringCallback`.

## 277792: fee-plus-principal overflow — fixed

Funded an extension fee accumulation near uint128.max for a real position. The combined withdrawal reverted with arithmetic panic against the audited code. The updated path computes and returns uint256 totals, splitting accountant payouts at uint128.max when necessary. Fee-only collection followed by principal withdrawal was already a recovery path, so the original condition was not a permanent freeze.

Regression: `test_auditCombinedFeeAndPrincipalAboveUint128`.

## 277789: full-array gas growth — acknowledged

Registered 128 initialized pools for one pair. With the same 50,000-gas read budget and cold index storage, full key-array materialization failed while the indexed getter succeeded. This demonstrates the scalability limitation, not a freeze of registry access or user funds.

Keep the existing bounded `pairPoolIdCount`, `pairPoolIds`, and `poolKeyById` API. The FreeLP UI already uses bounded, block-pinned reads. Whole-array getters are documented as convenience reads without an availability guarantee as the permissionless registry grows.

Regression: `test_auditWholePairReadCanExceedGasWhileIndexedReadsRemainAvailable`.

## 277791: withdrawal output bounds — acknowledged intentional API

A real swap moved the pool beyond the position range before withdrawal; the withdrawal correctly returned execution-price principal, including zero of one token. This verifies price-dependent proceeds, not an independently quantified profitable attack.

The minimal withdrawal ABI intentionally has no minimum-output arguments, as previously selected in review. The UI describes estimated receipts and does not offer unsupported withdrawal slippage controls. Keep this explicit tradeoff rather than reintroducing removed fields without a new design decision.

Regression: `test_auditWithdrawalUsesExecutionPriceWithoutOutputBounds`.
