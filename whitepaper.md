# Ekubo V3: Shared Liquidity as a Public Good

## 1. Motivation

Most AMMs today follow the same pattern:

- Each team forks or reimplements an AMM.
- Each deployment holds its own liquidity and token balances.
- Each “version” requires new integrations, new analytics, and new approvals.

From users’ and integrators’ perspectives this leads to:

- **Fragmented liquidity** – the same pair trades in many unrelated pools.
- **Duplicated work** – every fork needs its own indexers, explorers, and tooling.
- **Unnecessary gas costs** – tokens are transferred in and out of many different contracts that are all doing roughly the same thing.

Ekubo Core is a response to this duplication. Instead of many unrelated AMM contracts, Ekubo defines **one canonical Core contract** that implements a high‑precision concentrated‑liquidity AMM. Multiple **licensees** (which you can think of as white‑labeled AMMs with their own revenue models and frontends) all share this same Core.

The objectives are:

- **One implementation, many brands.** Different teams can run their own “instance” of Ekubo as an extension or licensee, but all orders and liquidity ultimately settle in the same Core.
- **Shared tooling and integrations.** Indexers, risk engines, analytics, and aggregators only need to integrate once.
- **Gas efficiency across licensees.** When everything settles in one Core, you can avoid ERC‑20 transfers even when moving value between different licensees.

## 2. The AMM Encoded in Core

Ekubo Core encodes a concrete AMM design:

- A constant‑product (`x * y = k`) AMM.
- With **concentrated liquidity** over price ranges, similar in spirit to Uniswap v3‑style positions.
- At a **very fine tick size** of 1/100th of a basis point, enabling precise market‑maker control.

Additional pool configurations (such as stableswap‑style and full-range pools) are also supported, but the key point is that:

- The **curve logic and pool mechanics live in Core itself.**
- Licensees do **not** ship their own AMM math; they all rely on this shared implementation.

This keeps the “hard part” – the AMM’s correctness and efficiency – in one place that is audited for correctness, while still allowing many different products to be built on top of it.

## 3. Engineering for Gas Efficiency

Ekubo Core is engineered under the assumption that **gas is the scarcest resource**. A central design objective was to make it extremely difficult to build a meaningfully more gas‑efficient AMM without sacrificing safety, features or developer experience.

At a high level:

- Critical state is **bit‑packed into as few storage slots as possible**, reducing both reads and writes.
- Hot paths are implemented using carefully written low‑level arithmetic, while respecting clear invariants.
- Rounding is always chosen to favor the pool, preserving solvency even in edge cases.

One concrete example is the way Core represents price:

- Instead of using a fixed‑point type, Core defines a **custom floating‑point‑like representation with a 2‑bit exponent**, tailored specifically to AMM needs.
- This encoding allows **liquidity and the square‑root price to be packed together into a single storage word**, dramatically reducing the cost of updating pool state.
- The representation and arithmetic are designed so that any rounding error is biased toward the pool, ensuring that the system never pays out more than it should.

Taken together, these choices mean that:

- The marginal gas cost of a swap or liquidity update is dominated by **economic necessities** (price discovery, fee accounting), not by avoidable overhead.
- Competing designs that simply “re‑implement the same thing” are very likely to be more expensive on‑chain, because all of the possible optimizations have already been exhausted in Ekubo Core.

## 4. Licensees and White‑Labeled AMMs

Under the Ekubo DAO Shared Revenue License, multiple independent teams can become **licensees** of the Core implementation. Each licensee can:

- Operate its own frontend(s) and branding.
- Choose its own revenue model and fee recipients.
- Curate asset lists, default pools, and guardrails for their users.

On‑chain, a licensee may interact with Core:

- Directly from its frontend or contracts, calling the Core interface.
- Via thin helper contracts that batch or wrap user flows.
- Optionally, by opting into shared **extensions** that add features on top of the base AMM.

In practice, many licensees will deploy the **standard positions contract** that ships with Ekubo V3:

- It manages user liquidity positions on top of Core.
- It exposes a configurable “protocol fee” parameter that lets a licensee take a share of LP fees without changing Core itself.
- It can be deployed as‑is with different fee settings, giving each licensee its own revenue model on the same underlying AMM.

All licensees:

- Share the **same** pools, ticks, and positions inside Core.
- Share the **same** token custody.
- Share the **same** global state that integrators and tools observe.

From a user’s point of view:

- Different licensees can feel like different “venues” or “frontends” with their own economic models and features.
- At a low level, they are all trading against one shared set of pools in the same Core contract, which directly results in better pricing.

## 5. Extensions: Shared Protocol Features

Extensions are **separate contracts** that integrate with Core to add reusable features. They are not new AMMs and they are not tied one‑to‑one with licensees. Instead, they provide functionality that **any** licensee can use.

In this version of the protocol, three extensions are shipped alongside Core:

- **Oracle** – efficiently records and exposes on‑chain price history for any token pair, perfect for bootstrapping new lending markets.
- **TWAMM (Time‑Weighted AMM)** – lets users place orders that execute gradually over time, smoothing execution and reducing market impact.
- **MEV Capture** – charges additional fees on swaps that move price significantly, directing that value back to liquidity providers.

Licensees can:

- Use these canonical extensions as‑is.
- Combine them in different ways in their own products.
- Optionally write additional extensions.

Conceptually:

- **Core** is the shared AMM engine and custody layer.
- **Extensions** are shared feature modules that any licensee can call.
- **Licensees** are off‑chain entities and/or contracts that choose how to assemble Core and extensions into a user‑facing product.

## 6. Network Effects From a Singleton Core

Having many licensees share a single Core contract creates several reinforcing network effects.

### 6.1 Tooling and Analytics

Because Core is the canonical place where all swaps and liquidity changes happen:

- Indexers, explorers, and analytics platforms only need to understand Core’s event stream.
- Risk and monitoring tools can be written once and reused across every licensee.
- New licensees can launch without waiting for custom integrations; they inherit the existing ecosystem “for free”.

This is similar to the way a common L2 or common DEX becomes a focal point for tooling: once the infrastructure exists, new frontends and business models are cheap to add.

### 6.2 Integrations and Routing

Aggregators, market makers, and other protocols only need to target Core’s interface:

- A single integration immediately supports all current and future licensees.
- Routing strategies can reason about one pool per pair (per configuration), not a forest of forks with small differences of behavior.

This reduces both engineering and operational complexity, and makes Ekubo a more attractive target for sophisticated routing logic.

### 6.3 Gas Efficiency Across Licensees

When two white‑labeled AMMs are implemented as separate deployments, moving value between them requires at least:

- An ERC‑20 transfer out of AMM A.
- An ERC‑20 transfer into AMM B.

Even if this all happens in one transaction, those extra token transfers cost gas.

When both licensees sit on top of the same Core:

- Tokens never need to leave Core just to move from “licensee A” logic to “licensee B” logic.
- Different licensees can even point at the **exact same pool**, but set up different revenue models externally (for example, by configuring different protocol‑fee parameters on their positions contracts).
- Licensee‑specific behavior can execute via direct Core calls or shared extensions, while balances stay in one place.

From the protocol's point of view, that means **one swap instead of two**: a trader routed through multiple licensees still interacts with a single Core pool, and each licensee settles its own economics off the back of that shared swap. This is the key network effect on gas: once tokens are in Core, all licensees can work with them without additional transfers between one another or redundant AMM hops.

## 7. Flash Accounting as a Supporting Feature

Ekubo Core also uses **flash accounting**: instead of transferring tokens in and out for every action, it keeps track of what each caller owes or is owed, and settles based on the net result.

This idea is not new in DeFi, but it is a good fit for a singleton AMM:

- Users can sequence multiple actions (e.g., swaps, liquidity changes) and only handle ERC‑20 transfers once.
- Power users and extensions can **save balances** in Core for later, reusing them across many operations.

Flash accounting is therefore best understood as **one of several mechanisms** that make the shared‑Core vision practical:

- It complements the singleton design by minimizing ERC‑20 calls.
- It makes it easier for licensees to compose complex flows without burdening users with many approvals and transfers.

It is important, but not the central conceptual novelty; the more fundamental idea is that many licensees share a single AMM implementation and liquidity layer.

## 8. Permissionless, Ownerless, and Fee‑Externalized

Ekubo Core is designed to be:

- **Permissionless to deploy:** anyone can take the contracts in this repository and deploy them to any chain, at the same addresses, using the provided deploy scripts. Bringing Ekubo to a new chain does not require coordination with the Ekubo team or DAO.
- **Permissionless to build on:** anyone can integrate Core, extensions, and the positions contract into their own product, subject only to the terms of the Ekubo license.
- **Ownerless on‑chain:** there is no privileged actor that can confiscate funds or reroute global protocol fees at the Core level.

Legally, the only global requirement is **revenue sharing** as defined in the Ekubo DAO Shared Revenue License:

- Licensees that collect protocol revenue (for example, by setting a non‑zero protocol‑fee share on the positions contract) share a portion of that revenue with Ekubo DAO.
- This revenue‑sharing arrangement can be negotiated with the Ekubo DAO when necessary.
- If a licensee chooses **not** to collect any protocol revenue (e.g., allows LPs to keep 100% of fees), then there is no protocol revenue to share with Ekubo DAO.

Crucially, the notion of a **“protocol fee”** is **externalized** from Core itself:

- Core does not force a single global fee recipient or tax.
- Each licensee (through its chosen contracts and frontends, possibly via extensions) can define its own fee model and revenue split—for example, by configuring the protocol‑fee parameter on the shared positions contract it deploys.
- Communities can choose or fork the licensee logic that matches their values.

This separation lets Core focus on being a neutral, efficient, and durable AMM implementation, while economic policies live at the edges and are governed by license terms rather than on‑chain privileges. In this sense, the Core contracts function as **public infrastructure** for AMMs: a shared, well‑engineered base layer that anyone can deploy, integrate, and build on, so long as they respect the simple revenue‑sharing rules of the license.

## 9. How It Feels to Use Ekubo

### 9.1 For Traders

- You interact with a frontend (often tied to a specific licensee) and trade as usual.
- Under the hood, your trades settle against the same shared pools inside Core that other licensees use.
- You benefit from deeper liquidity and, over time, lower gas overhead per unit of volume as more activity concentrates in the singleton.

### 9.2 For Liquidity Providers

- You provide liquidity once into a Core pool.
- That liquidity can serve order flow from many different licensees.
- Your capital is not fragmented across multiple forks of the same AMM.

As more licensees launch on Ekubo, the same positions can see more order flow, without any extra management overhead from LPs.

### 9.3 For Licensees and Builders

- You focus on product, UX, and economics rather than re‑implementing AMM internals.
- You inherit existing liquidity, tooling, and integrations by plugging into Core.
- You can differentiate on fees, governance, curation, and user experience, while sharing a common, battle‑tested AMM engine.

## 10. Summary

Ekubo Core is a **singleton AMM implementation** that multiple licensees share—a public good for concentrated‑liquidity markets:

- The AMM itself is a high‑precision, concentrated‑liquidity constant‑product design encoded directly in Core.
- Licensees act as white‑labeled AMMs on top, with their own frontends and revenue models, but common liquidity and custody.
- Shared state produces strong network effects for tooling, integrations, and gas efficiency—even when value flows between different licensees.
- Flash accounting and saved balances support this vision by reducing ERC‑20 transfers and simplifying multi‑step flows, without being the main conceptual innovation.

The long‑term picture is a DeFi ecosystem where many brands and business models can coexist on top of a single, efficient, permissionless, and ownerless AMM Core, rather than a patchwork of incompatible forks all reinventing the same mechanics.
