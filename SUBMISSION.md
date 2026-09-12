# AetherVault — Submission

Candidate: Levan Tsibirashvili
Date: September 12, 2026
Hours: 16

## Threat model summary
Trust Assumptions & Privileges: The core architecture relies on immutable contracts without proxy patterns. Administrative privileges are strictly limited to the protocol owner for configuring risk parameters (setUserRiskBucket) and setting authorized liquidation engines, with no capability to arbitrarily seize user funds or alter historical share accounting.

Attack Surfaces: Primary threat vectors include ERC-4626 share inflation via flash-loan asset donations, read-only reentrancy vulnerabilities during external Automated Market Maker (AMM) interactions, oracle manipulation via TWAP sandwich attacks, and dust-level griefing during undercollateralized position liquidations.

Defensive Controls: Implements the Checks-Effects-Interactions (CEI) pattern, an ERC-4626 virtual decimal offset (_decimalsOffset()) to neutralize rounding attacks, cached LP mark protections (cachedLpMark alongside pool.unlocked() checks), and strict atomic execution boundaries.

## Section C answers

### 1. ERC-4626 + flash loan

If totalAssets includes raw token balances without a virtual offset, an attacker can manipulate share prices by donating tokens in the same transaction right after a vault is initialized. They deposit a tiny amount, get a single share, flash-loan a huge amount, and dump it straight into the vault. This inflates total assets while share supply stays minimal, causing subsequent deposits to round down to zero shares due to integer division. The attacker then redeems their single share and walks away with the entire pool. Adding a virtual offset introduces virtual shares and assets into the denominator, meaning the capital required to skew the share price becomes astronomical and completely unprofitable once flash-loan fees and gas are factored in.

### 2. Read-only reentrancy

Yes, it can. During an external callback mid-liquidation or AMM swap, internal accounting states might be partially updated while pool spot prices are temporarily skewed. If an integrator calls a view function like getAccountHealth during this uncommitted window, it evaluates against manipulated spot liquidity and falsely returns a healthy status. To stop integrators from relying on this, protocols enforce reentrancy guards, use cached mark values, and check unlocked pool flags, while explicitly documenting that external systems must rely on committed block states instead of querying uncommitted view functions.

### 3. Bad debt socialization

Vault LPs take the loss first when bad debt hits, because unrecoverable deficits directly reduce the asset backing per share. Liquidators never take losses since they operate atomically with guaranteed margins. For a protocol marketed as a "senior tranche" risk, letting senior LPs absorb first-loss deficits breaks the core premise. To maintain institutional integrity, the protocol must integrate a dedicated junior tranche or an overcollateralized safety module that absorbs bad debt before touching senior LP principal.

### 4. Oracle design

Sustaining an artificial TWAP over 30 minutes requires continuous block-by-block capital manipulation and massive swap fees across multiple blocks, making it exceptionally expensive. In contrast, exploiting a Chainlink heartbeat miss requires zero capital manipulation on the AMM side; the attacker just waits for market prices to drift away from a stale oracle feed. Liquidations must be frozen entirely when oracle divergence exceeds safety thresholds. Running in a degraded mode risks liquidating solvent positions based on stale or manipulated data, which leads straight to insolvency.

### 5. Storage packing

EVM arithmetic wraps around naturally, subtracting two uint128 fee growth values produces the exact same delta calculation as uint256 without causing logical overflow issues, as long as the accumulation window fits safely within 128 bits (which takes centuries under normal token scales).

Slot 1: uint128 liquidity (16 bytes) and uint128 feeGrowthInsideLastX128 (16 bytes), completely filling the 32-byte slot.

Slot 2: uint64 lastUpdateTime (8 bytes) and address owner (20 bytes), totaling 28 bytes and fitting cleanly into the second slot.

### 6. Upgradeable vs immutable

While immutable contracts are safer, three scenarios would force a proxy pattern: complex multi-chain state synchronization layers, dynamic yield-routing strategies that adapt to changing market strategies without forcing liquidity migrations, and emergency governance circuit-breakers for rapid patching. To migrate safely, you deploy the new implementation contract, execute a timelocked governance transaction to update the ERC-1967 proxy storage slot, and run automated invariant checks post-upgrade.

### 7. Cross-chain shares

Bridging vault shares as OFTs shatters the core ERC-4626 invariant that one share equals a deterministic slice of underlying assets locked locally in the vault. Minting shares on a remote chain without matching underlying assets deposited locally decouples share valuation from actual solvency. We refuse the assumption of instant synchronous finality across asynchronous cross-chain messaging layers, because network delays expose the protocol to cross-chain arbitrage and double-spending.

### 8. Gas budget for 12-collateral liquidation

To keep a 12-collateral liquidation under 2M gas on L2, we used memory arrays instead of storage arrays for temporary collateral loops, implemented early loop exits as soon as debt is fully repaid, and cached state variables in the stack to eliminate redundant SLOAD and SSTORE operations. We deliberately left out complex multi-hop dynamic pathfinding for collateral swaps, relying instead on direct pre-routed pool parameters to minimize opcode overhead.

## Attack labs status

| Test | Pass on fix? | Notes |
|------|--------------|-------|
| FirstDepositInflation     | Yes | Mitigated via virtual share offset to prevent initial deposit manipulation. |
| FlashLiquidityReentrancy  | Yes | Protected using a reentrancy guard modifier on liquidity flows. |
| LiquidationDustGrief      | Yes | Bypasses close factor checks for dust positions to clear residual debt. |
| TwapManipulationSandwich  | Yes | Validated against price manipulation using strict TWAP deviation checks. |
| BadDebtBricksRedeems      | Yes | Properly accounts for bad debt realization without breaking share redemptions.|
