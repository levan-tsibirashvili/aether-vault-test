# AetherVault — Senior Solidity Take-Home

**Role:** Senior Smart Contract Engineer (Solidity)  
**Timebox:** 6 hours focused / 48 hours open  
**Difficulty:** Senior+ (economic + safety traps)

---

## Protocol context

AetherVault is a **leveraged yield vault** sitting on top of a custom **concentrated-liquidity AMM** (`AetherPool`) with:

- Cross-margin accounts
- Isolated risk buckets
- Flash liquidity borrows (pool-level)
- Liquidations with bad-debt socialization
- ERC-4626 shares that are **not** 1:1 with underlying due to funding / interest accrual
- Permit2-style operator grants for keepers

The repo is Foundry-based. Core contracts compile but contain **intentional vulnerabilities, broken invariants, and unfinished modules**. Your job is to fix, complete, and prove safety with tests — not to paper over failures.

---

## Deliverables

1. Code completing Sections A–B.
2. `SUBMISSION.md` with written answers (Section C).
3. Foundry tests that demonstrate attack resistance (Section D).
4. Short `THREAT_MODEL.md` (≤2 pages).

---

## Section A — Must fix / implement

### A1. Share price manipulation on ERC-4626 (`contracts/core/AetherVault.sol`)

The vault uses `totalAssets()` that naively reads idle ERC20 balance + “marked” LP value.

**Tasks:**

- Prevent first-depositor inflation attacks **and** donation attacks that skew `convertToShares`.
- Accrue interest/funding **before** any deposit/withdraw/mint/redeem (reorder carefully — reentrancy surface exists via ERC777/hooks).
- `previewRedeem` must match actual redeem within 1 wei for the fuzz corpus in `test/invariant/VaultInvariant.t.sol`.

**Trap:** Virtual offset alone is insufficient because LP mark-to-market can be manipulated inside the same tx via flash liquidity.

### A2. Flash liquidity + reentrancy (`contracts/core/AetherPool.sol`)

`flashLiquidity` currently updates reserves **after** the callback. Fix the CEI pattern without breaking legitimate arb callbacks that must see post-borrow reserves.

Also implement:

- Fee-on-transfer token handling (or explicit ban list).
- TWAP oracle that cannot be manipulated within a single block for liquidations (document window + attack cost).

### A3. Liquidation engine (`contracts/core/LiquidationEngine.sol`)

Complete liquidations such that:

- Partial liquidations allowed only when health factor < 1 but > `CLOSE_FACTOR` threshold rules.
- Liquidator receives collateral bonus, but **cannot** leave account dust that is unliquidatable yet underwater.
- Bad debt socialized across vault LPs via `realizeBadDebt` — must not brick `totalSupply` or make shares permanently non-redeemable.
- Liquidation must work under shortfall when oracle and spot diverge (use your TWAP carefully).

**Trap:** A naive “seize all collateral” path can be griefed by donating 1 wei of a second collateral token.

### A4. Cross-margin risk buckets (`contracts/libraries/RiskBucket.sol`)

Positions across correlated assets share a risk bucket. Implement:

- Margin requirement as a function of bucket correlation matrix (fixed-point, 1e18).
- Prevent circular dependency when asset A’s risk depends on B and B on A (graph must be DAG **or** use iterative convergence with proven bound).

### A5. Operator / keeper permissions

Implement time-bounded operator grants with nonce + EIP-712, cancellable, and **not** vulnerable to signature malleability or replay across vault clones (include chainId + vault address in domain).

---

## Section B — Invariants you must prove with Foundry

Write / repair invariant tests so these hold under fuzz + handler:

1. `sum(userDebt) + badDebtBucket == totalDebtAccrued` (accounting identity).
2. Vault shares are never free: `deposit(0)` reverts; inflation attack yields ≤1 wei profit in your adversary test.
3. Pool constant-product / CLMM invariant holds outside of flash window; within flash window, debt is tracked and repaid before unlock.
4. Liquidation cannot increase protocol bad debt when spot ≥ TWAP * (1 - ε) for ε you define.
5. No unexpected ERC20 token left in pool beyond tracked reserves (+ accrued fees).

---

## Section C — Written questions (required)

1. **ERC-4626 + flash loan:** Show (math + words) how an attacker can inflate share price using a same-tx donation **if** `totalAssets` includes raw token balance. How does your fix change the attacker’s PnL?

2. **Read-only reentrancy:** Can a view `getAccountHealth` be forced to return healthy during an unsafe callback mid-liquidation? If yes, how do you stop integrators from relying on it?

3. **Bad debt socialization:** Who bears loss first — vault LPs, the liquidator, or a safety module? Justify the ordering for a protocol that markets “senior tranche” risk.

4. **Oracle design:** Compare attack cost to move your TWAP for 30 minutes vs a Chainlink heartbeat miss. When do you freeze liquidations vs continue with degraded mode?

5. **Storage packing:** Pack `AetherPool` position structs to ≤2 storage slots without introducing overflow in fee growth fields. Show the layout.

6. **Upgradeable vs immutable:** This take-home uses non-upgradeable contracts. List three features that would force a proxy pattern and how you’d migrate liquidity safely.

7. **Cross-chain shares:** If vault shares are bridged as OFTs, which invariants break and what message-passing assumptions do you refuse?

8. **Gas:** Liquidating a 12-collateral account must stay under 2M gas on L2. What algorithmic choices did you make (and what did you leave out)?

---

## Section D — Attack labs (must include tests)

Implement Foundry tests named exactly:

- `test_Attack_FirstDepositInflation`
- `test_Attack_FlashLiquidityReentrancy`
- `test_Attack_LiquidationDustGrief`
- `test_Attack_TwapManipulationSandwich`
- `test_Attack_BadDebtBricksRedeems` (must fail on broken code, pass on your fix)

Broken baseline should fail at least three of these. Your submission should pass all five.

---

## Section E — Rubric

| Area | Weight |
|------|--------|
| Economic safety (4626, flash, liq) | 30% |
| Invariant tests quality | 25% |
| Code clarity / gas awareness | 15% |
| Written answers | 20% |
| Threat model | 10% |

**Auto-fail:** silent overflow casts; trusting `tx.origin`; unbounded loops on user-controlled collateral arrays without gas bounds; “just use OpenZeppelin” without addressing flash-mark-to-market.

---

## Setup

```bash
cd 02-solidity-protocol-aether-vault
forge install
forge test
```

Solidity `0.8.28`, Foundry stable.

---

## Constraints

- Do not replace the architecture with a fork of Aave/Uniswap and call it done.
- You may use OpenZeppelin / Solmate / Solady, but custom risk math must remain yours.
- Document any spec ambiguity you resolve.
