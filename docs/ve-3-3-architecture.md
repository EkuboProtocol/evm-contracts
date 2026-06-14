# ve(3,3) Architecture

This stack is made of three contracts:

- `VePositions`: a position manager for LPs that routes swap fees away from LPs and into a gauge.
- `VeGauge`: a vote-escrow NFT and gauge accounting contract that distributes routed pool fees to ve voters and directs emissions.
- `SingleTokenRewards`: a pool extension that streams one reward token to in-range liquidity positions.

## Fee Flow

LPs create and update positions through `VePositions`.

Before every deposit or withdrawal, `VePositions` calls `Core.collectFees` for the position. The collected swap fees are:

1. reduced by `SWAP_PROTOCOL_FEE_X64`, if configured;
2. withdrawn to `feeReceiver`;
3. reported to `feeReceiver` through `IVeGauge.notifyPoolFees(poolKey, amount0, amount1)`.

`collectFees` is permissionless. The recipient argument is ignored because swap fees always go to `feeReceiver`. Withdrawal principal still goes to the requested recipient, subject to the normal position NFT authorization check.

`VeGauge` only accepts `notifyPoolFees` calls from its immutable `positions` address. It accounts fees per pool using fee-growth-per-vote-weight accumulators. Voters claim fees for each pool they voted for.

## Voting And Locks

`VeGauge` mints ve NFTs backed by an immutable `stakeToken`.

Locks:

- have a maximum duration of 4 years;
- have linear voting power decay based on remaining lock time;
- can be increased or extended by the ve NFT owner;
- can be withdrawn after expiry.

Votes are split across pool ids by user-provided weights. Existing votes are cleared before new votes are installed, settling accrued pool fees first. Pool fee accounting is pool-local: fees earned by one pool are distributed only to ve NFTs voting for that pool.

## Emissions

Anyone can fund emissions by transferring `stakeToken` to `VeGauge`. Funding increases the global emission rate over one week.

Anyone can call `triggerPoolEmissions(poolKey)` for an individual voted pool. The gauge:

1. accrues global emissions and time-weighted vote seconds;
2. computes the pool share from its vote seconds since it was last triggered;
3. calls `SingleTokenRewards.addRewards` through `Core.forward`;
4. pays the actual emitted `stakeToken` amount into Core.

The target pool extension must be `SingleTokenRewards` and its `rewardToken` must equal the gauge `stakeToken`.

## Reward Extension Locker Restriction

`SingleTokenRewards` has an immutable `allowedLocker`.

If `allowedLocker == address(0)`, the extension is unrestricted. If it is non-zero, only that locker can update liquidity positions in pools using the extension. This check is performed in `beforeUpdatePosition`, not in forwarded reward methods, so anyone can still fund or donate rewards.

For the ve deployment, `allowedLocker` should be the `VePositions` address. This prevents users from bypassing the fee-surrendering position manager while still farming gauge emissions.

## Deployment

Use `script/DeployVe.s.sol`.

Required environment:

- `STAKE_TOKEN`: ERC20 token used for ve locks and emissions.

Optional environment:

- `OWNER_ADDRESS`: owner for metadata/admin actions; defaults to the first Foundry wallet.
- `CORE_ADDRESS`: deployed Core address.
- `SALT`: deterministic deployment salt.
- `SWAP_PROTOCOL_FEE_X64`: optional protocol fee on routed swap fees.
- `WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR`: optional withdrawal protocol fee denominator.
- `VE_POSITIONS_BASE_URL`: metadata base URL for ve positions.
- `VE_GAUGE_BASE_URL`: metadata base URL for ve lock NFTs.

The deploy script deploys `VePositions`, deploys `VeGauge`, sets `VePositions.feeReceiver` to the gauge, and deploys `SingleTokenRewards` with `allowedLocker = VePositions`.
