# FreeLP position manager

FreeLP adapts the zero-fee accounting and settlement of BasePositions/FreePositions into a standalone ownerless ERC-721 manager. Existing production contracts and their source dependency graphs are unchanged.

Each NFT has exactly one immutable extension-free concentrated-liquidity PoolKey and tick range. Monotonically increasing 192-bit IDs are never reused. Creation initializes a missing pool and deposits atomically. Full-range liquidity is represented by the minimum/maximum valid ticks of a concentrated pool. Extensions and stableswap pool configs are rejected.

`ownedIds(holder, offset, limit)` provides bounded pages of at most 100 IDs. Pin reads to a single block for a consistent snapshot. `descriptor`, `positionAmounts`, `poolState`, and `quoteDeposit` supply the data needed to manage positions without an indexer. Core remains the authoritative source of live liquidity and fees. Ownership indexes update before safe-transfer callbacks and handle forwarding and transfer-to-self.

`tokenURI` returns base64 JSON with an embedded base64 SVG, generated entirely on-chain. Address labels deliberately avoid arbitrary ERC-20 metadata calls and external assets. Collection name/symbol are fixed. No owner, metadata setter, upgrade mechanism, fee setter, fee collector, or swap entrypoint exists.

`createPosition` and `addLiquidity` accept token maxima, minimum minted liquidity, and a deadline. Deposits are capped so aggregate position liquidity remains representable by int128. `withdraw` always collects fees and enforces minimum output amounts and a deadline; withdrawing zero liquidity collects fees only. `burn` requires no remaining liquidity or collectible fees. Standard NFT owner/operator authorization applies.

Nonpayable `multicall` batches ERC-20 operations and withdrawals. Native deposits are standalone payable calls; exact excess msg.value is returned in the same transaction. This deliberately avoids delegatecall reuse of msg.value across native deposits. All position mutation entrypoints are guarded against reentrancy, and NFT transfers are forbidden during settlement/refund callbacks. Safe-transfer receiver callbacks may forward NFTs after an ordinary transfer.

Validation: targeted tests cover principal/fee settlement, partial withdrawals, output limits/deadlines, ownership paging and randomized transfers, safe-transfer forwarding, native refund reentrancy, metadata decoding, code-size limits, invalid pool/range rejection, burn lifecycle, and atomic withdraw/burn batching. Gas measurements are in `snapshots/FreeLP.gas`.
