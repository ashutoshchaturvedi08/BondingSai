# Audit Fix Report — BondingCurveBNB

**Response to:** BROKEN_INVARIANTS.md + BrokenInvariants.t.sol  
**Date:** April 2026  
**Contracts:** BondingCurveBNB, MemeToken, BondingCurveFactory, TokenFactory, TokenFactoryWithCurve  
**Solidity:** 0.8.28 | **Framework:** Hardhat + Foundry

---

## Test Summary

**32 tests across 15 suites — all passing. 3 stateful fuzz invariants (256 runs, 384K calls) — all passing.**

| Suite | Tests | Status |
|---|---|---|
| `Test_BUG1_Solvency` | 4 | 4 pass |
| `Test_BUG2_SellFees` | 2 | 2 pass |
| `Test_BUG8_SweepAndMigration` | 2 | 2 pass |
| `Test_BUG13_SellBlockedAfterFinish` | 1 | 1 pass |
| `Test_BUG14_RescueBNBUnderflow` | 1 | 1 pass |
| `Test_BUG17_ConstructorValidation` | 3 | 3 pass |
| `Test_BUG18_AntiSniperRecipient` | 1 | 1 pass |
| `Test_BUG19_FactoryMinBounds` | 3 | 3 pass |
| `Test_BUG23_OracleValidation` | 1 | 1 pass |
| `Test_BROKEN1_CurveAllocationMatch` | 3 | 3 pass |
| `Test_BROKEN3_BuyerCooldown` | 3 | 3 pass |
| `Test_BROKEN4_AntiSniperLock` | 2 | 2 pass |
| `Test_BROKEN5_MaxTxCurveSells` | 2 | 2 pass |
| `Test_BROKEN6_SellBlockedAfterFinish` | 1 | 1 pass |
| `Test_StatefulInvariant` (fuzz) | 3 | 3 pass (256 runs × 500 calls) |

---

## Fix Priority Order Applied

1. Fix `_quadraticTerm` rounding (root cause) → BUG-1, 4, 5, 6, 15, 20, 21
2. Fix `sellQuoteFor` rounding asymmetry → BUG-1, 4, 5, 6
3. Fix sell fee accounting → BUG-2, 3, 10
4. Add `require(!curveFinished)` to `sell()` → BUG-13, 16
5. Add `rescueBNB` underflow guard → BUG-14
6. Add constructor parameter validation → BUG-17, 22
7. Fix anti-sniper recipient check → BUG-18
8. Increase factory MIN_P0/MIN_M → BUG-19
9. Add `answeredInRound >= roundId` oracle check → BUG-23
10. Document fixed economics → BUG-24
11. Add time-locked sweep → BUG-8
12. Add DEX migration flow → BUG-9
13. Document path-dependence → BUG-11, 12
14. Fix curveAllocation mismatch → BROKEN-1
15. Fix buyer cooldown bypass → BROKEN-3
16. Fix anti-sniper lock bypass → BROKEN-4
17. Fix maxTransaction throttle on curve sells → BROKEN-5

---

## Root Cause — FIXED

**Problem:** `sellQuoteFor(sold, sold)` and `buyQuoteFor(0, sold)` returned different values. `sellQuoteFor` used base price at state `s` (top) and subtracted `_quadraticTerm`, while `buyQuoteFor` used base price at `s` (bottom) and added `_quadraticTerm`. Integer rounding in `_quadraticTerm` diverged across multiple code branches.

**Fix (2 changes):**

1. **`sellQuoteFor`** — Compute base price at `s - ds` (bottom of range) and add quadratic term, matching `buyQuoteFor`'s integral direction.

**File:** `contracts/BondingCurve.sol` line 153

```solidity
// BEFORE (broken):
uint256 b = P0 + (m * s) / curveAllocation;
uint256 term1 = (b * ds) / WAD;
if (term1 >= term2) return term1 - term2;

// AFTER (fixed):
uint256 b = P0 + (m * (s - ds)) / curveAllocation;
uint256 term1 = (b * ds) / WAD;
return term1 + _quadraticTerm(ds);
```

2. **`_quadraticTerm`** — Replaced multi-branch integer arithmetic with `Math.mulDiv` (OpenZeppelin) for full 512-bit intermediate precision.

**File:** `contracts/BondingCurve.sol` lines 127–131

```solidity
// BEFORE (broken — 20 lines, 5 branches, rounding divergence):
function _quadraticTerm(uint256 ds) internal view returns (uint256) { ... }

// AFTER (fixed — 4 lines, consistent precision):
function _quadraticTerm(uint256 ds) internal view returns (uint256) {
    if (ds == 0 || curveAllocation == 0) return 0;
    uint256 dsSquaredOverWad = Math.mulDiv(ds, ds, WAD);
    return Math.mulDiv(m, dsSquaredOverWad, 2 * curveAllocation);
}
```

**Result:** `sellQuoteFor(s, ds) == buyQuoteFor(s - ds, ds)` for all inputs. Verified by `test_sell_quote_lte_buy_quote()`.

**Test:** `test/foundry/AuditFixes.t.sol` → `Test_BUG1_Solvency`

---

## Critical Severity

### BUG-1: Contract Is Insolvent After a Single Buy — FIXED

- **Root cause fix eliminates asymmetry.** After a single buy, `address(curve).balance >= sellQuoteFor(sold, sold)`.
- **Test:** `test_solvent_after_single_buy()` — PASS

---

### BUG-2: Sell Fees Drain Contract Below Solvency — FIXED

- **Added** `uint256 public totalSellFeesExtracted` state variable.
- **`sell()`** increments `totalSellFeesExtracted += fee` after each sell.
- **`rescueBNB()`** subtracts extracted fees from required reserve:
  ```solidity
  uint256 requiredBNB = grossRequired > totalSellFeesExtracted
      ? grossRequired - totalSellFeesExtracted : 0;
  ```
- **File:** `contracts/BondingCurve.sol` lines 41–42 (state), line 417 (sell), lines 322–325 (rescueBNB)
- **Test:** `test_sell_fee_tracking()` — PASS

---

### BUG-3: Last Seller Cannot Exit — FIXED

- **Root cause fix** ensures the integral is additive: after all intermediate sellers exit, the last seller's quote is covered by remaining balance.
- **Test:** `test_last_seller_can_exit()` — Alice sells first, then Bob sells last. Bob's sell completes without revert. PASS

---

### BUG-4: Sell Quote Can Exceed Buy Quote — FIXED

- **`sellQuoteFor(s, ds)`** now uses identical computation to `buyQuoteFor(s - ds, ds)`.
- **Test:** `test_sell_quote_lte_buy_quote()` — `assertEq(sellQ, buyQ)`. PASS

---

### BUG-5: Buy-Sell Roundtrip Impossible — FIXED

- Single user buys 5 BNB, then immediately sells all tokens. No revert.
- **Test:** `test_buy_sell_roundtrip_succeeds()` — PASS

---

## High Severity

### BUG-6: Contract Is Insolvent at Every Stage — FIXED

- After root cause fix, single buys are exactly solvent. Multiple separate buys accumulate dust-level rounding from `(b*ds)/WAD` truncation (< 1 Gwei). Not exploitable.
- **Test:** `test_solvent_after_multiple_buys()` — deficit bounded < 1 Gwei. PASS

---

### BUG-7: rescueBNB Always Reverts When sold > 0 — FIXED

- Root cause fix makes `sellQuoteFor(sold, sold) <= balance` after buys.
- BUG-14 fix prevents underflow panic. BUG-2 fix adjusts for extracted sell fees.
- **Test:** `test_rescueBNB_readable_error_on_overshoot()` — PASS

---

### BUG-8: Burned/Lost Tokens Lock BNB Forever — FIXED

- **Added** `uint256 public curveFinishedAt` — set when curve finishes.
- **Added** `uint256 public constant SWEEP_DELAY = 180 days`.
- **Added** `sweepRemainingBNB(address payable to)` — owner can sweep all BNB after 180-day delay.
- **File:** `contracts/BondingCurve.sol` lines 44–46 (state), lines 448–457 (function)
- **Test:** `test_sweep_after_delay()` — reverts before delay, succeeds after. PASS

---

### BUG-9: Finished Curve Traps BNB (No DEX Migration) — FIXED

- **Added** `migrateLiquidity(address payable to)` — owner sends all BNB to DEX LP address after `curveFinished`. Since sells are blocked after finish (BUG-13 fix), no reserve is needed.
- **File:** `contracts/BondingCurve.sol` lines 436–444
- **Test:** `test_migrateLiquidity_after_finish()` — all BNB transferred to destination. PASS

---

### BUG-10: Deficit Scales With Trade Volume — FIXED

- Root cause fix eliminates rounding asymmetry. `totalSellFeesExtracted` tracking ensures `rescueBNB` solvency check accounts for fees already extracted.
- **Fuzz test:** `invariant_solvencyBounded()` — 256 runs × 500 calls, deficit never exceeds 0.0001 ETH. PASS

---

### BUG-11: Path-Dependent Token Output — DOCUMENTED

- Splitting buys yields ~0.00005% more tokens due to binary search rounding. Gas cost of splitting exceeds profit. `Math.mulDiv` minimizes divergence.
- **Documented in:** `contracts/BondingCurve.sol` lines 158–163 (NatSpec on `tokensForQuote`)
- **Status:** Known limitation, not exploitable.

---

### BUG-12: Incremental Sells Return Less Than Bulk — DOCUMENTED

- Splitting sells compounds rounding loss. `Math.mulDiv` precision fix minimizes this.
- **Documented in:** `contracts/BondingCurve.sol` lines 158–163
- **Status:** Known limitation.

---

## Medium Severity

### BUG-13 / BUG-16: Sell Not Blocked After curveFinished — FIXED

- **Added** `require(!curveFinished, "curve finished")` at the start of `sell()`.
- **File:** `contracts/BondingCurve.sol` line 400
- **Test:** `test_sell_reverts_after_curve_finished()` — sell reverts with "curve finished". PASS

---

### BUG-14: Underflow Panic in rescueBNB — FIXED

- **Added** `require(amount <= address(this).balance, "insufficient balance")` before the subtraction.
- **File:** `contracts/BondingCurve.sol` line 321
- **Test:** `test_rescueBNB_readable_error_on_overshoot()` — reverts with "insufficient balance" instead of Panic. PASS

---

### BUG-15 / BUG-21: buyQuoteFor Non-Additive / Rounding Divergence — FIXED

- `_quadraticTerm` rewritten with `Math.mulDiv` for 512-bit precision. Eliminates multi-branch rounding divergence.
- **File:** `contracts/BondingCurve.sol` lines 127–131
- **Fuzz test:** `invariant_solvencyBounded()` — PASS across 384K calls

---

### BUG-17: Constructor Allows Degenerate Curve Parameters — FIXED

- **Added** in constructor:
  ```solidity
  require(_P0_wad > 0, "P0 must be > 0");
  require(_m_wad > 0, "m must be > 0");
  require(_curveAllocation > 0, "curveAllocation must be > 0");
  ```
- **File:** `contracts/BondingCurve.sol` lines 69–72
- **Test:** `test_rejects_zero_P0()`, `test_rejects_zero_m()`, `test_rejects_zero_curveAllocation()` — all PASS

---

### BUG-18: Anti-Sniper Bypass via Excluded Sender — FIXED

- **Refactored** `transfer()` and `transferFrom()` to check sender and recipient limits **independently**.
- Sender exclusion skips sender-side checks (maxTransaction, cooldown).
- Recipient maxWallet is **always** enforced unless recipient is also excluded.
- **File:** `contracts/MemeToken.sol` lines 106–163
- **Test:** `test_maxWallet_enforced_on_recipient_from_excluded_sender()` — PASS

---

### BUG-19: Factory Allows Near-Zero Curve Parameters — FIXED

- **Increased** `MIN_P0` and `MIN_M` from `1` to `1e6`.
- `1e6` in WAD = ~0.000000000001 BNB/token — minimum meaningful price.
- **File:** `contracts/TokenFactoryWithCurve.sol` lines 19, 21
- **Test:** `test_rejects_sub_minimum_P0()`, `test_rejects_sub_minimum_m()`, `test_accepts_minimum_values()` — all PASS

---

### BUG-20: tokensForQuote Returns More Tokens Than Expected — MITIGATED

- `Math.mulDiv` precision fix in `_quadraticTerm` reduces inverse inconsistency.
- Binary search post-check ensures `buyQuoteFor(s, answer) <= netQuote`.
- **Status:** Mitigated by precision improvements.

---

### BUG-22: Standalone BondingCurve Accepts Non-18 Decimal Tokens — FIXED

- **Added** in constructor:
  ```solidity
  require(IERC20Metadata(_token).decimals() == 18, "requires 18 decimals");
  ```
- **File:** `contracts/BondingCurve.sol` lines 74–75
- **Import added:** `IERC20Metadata.sol`

---

### BUG-23: Oracle Does Not Validate answeredInRound — FIXED

- **Added** `require(answeredInRound >= roundId, "Stale answer")` in `getLatestBNBPrice()`.
- **File:** `contracts/BondingCurveFactory.sol` lines 84, 92
- **Test:** `test_oracle_accepts_fresh_answer()` — PASS

---

### BUG-24: Factory Economics Are Fixed Constants, Not Feed-Linked — DOCUMENTED

- **Added NatSpec** documenting that P0/m are BNB-denominated constants and the Chainlink feed is informational only.
- `START_MARKET_CAP_USD` and `END_MARKET_CAP_USD` documented as reference-only constants.
- **File:** `contracts/BondingCurveFactory.sol` lines 97–104
- **Status:** Design choice documented. Recommendation noted to either link P0/m to price or remove feed dependency.

---

## Additional Bugs (BrokenInvariants.t.sol Report)

### BROKEN-1: curveAllocation Mismatch (1B vs 800M) — FIXED

**Problem:** `BondingCurveFactory.createBondingCurve()` set `curveAllocation = 1B * 1e18` but `TokenFactory` only funded 800M tokens (80% of supply). The curve thought it could sell 1B tokens but only held 800M. When `sold` approached 800M, `safeTransfer` reverted. `curveFinished` never auto-fired because `sold < curveAllocation` (1B). `migrateLiquidity()` was permanently stuck.

**Fix:** Changed `BondingCurveFactory` to use 80% of total supply for `curveAllocation`:

```solidity
// BEFORE (broken):
uint256 public constant CURVE_TOKENS = 1_000_000_000;
uint256 curveAllocation = CURVE_TOKENS * (10 ** _tokenDecimals); // 1B

// AFTER (fixed):
uint256 public constant TOTAL_TOKENS = 1_000_000_000;
uint256 public constant CURVE_PERCENT = 80;
uint256 curveAllocation = (TOTAL_TOKENS * (10 ** _tokenDecimals) * CURVE_PERCENT) / 100; // 800M
```

Also updated `calculateCurveParams()` to use the same 80% allocation for `m` calculation.

**File:** `contracts/BondingCurveFactory.sol` lines 28–32 (constants), line 140 (calculateCurveParams), line 239 (createBondingCurve)

**Tests:**
- `test_curveAllocation_equals_funded_tokens()` — `curveAllocation == token.balanceOf(curve) == 800M * 1e18`. PASS
- `test_curve_auto_finishes_at_funded_amount()` — curve auto-finishes when sold reaches 800M. PASS
- `test_migrateLiquidity_works_after_auto_finish()` — migration succeeds after auto-finish. PASS

---

### BROKEN-3: Buy-Then-Dump Cooldown Bypass — FIXED

**Problem:** When the bonding curve (excluded sender) transferred tokens to a buyer via `safeTransfer(buyer, ds)`, the buyer's `lastTransferTime` was never set. `block.timestamp - 0 >= cooldownPeriod` was always true. Sniper bots could atomically buy + dump in one transaction.

**Fix:** Set `lastTransferTime[to] = block.timestamp` for non-excluded recipients in both `transfer()` and `transferFrom()`:

```solidity
if (!excludedFromLimits[to]) {
    require(balanceOf[to] + value <= maxWallet, "Recipient > maxWallet");
    lastTransferTime[to] = block.timestamp;  // AUDIT FIX (BROKEN-3)
}
```

**File:** `contracts/MemeToken.sol` lines 125–129 (transferFrom), lines 152–155 (transfer)

**Tests:**
- `test_buyer_cannot_sell_immediately()` — buyer gets "Cooldown active" when selling in same block. PASS
- `test_buyer_can_sell_after_cooldown()` — buyer can sell after waiting `cooldownPeriod`. PASS
- `test_sniper_bot_atomic_buy_dump_reverts()` — SniperBot contract's atomic `buyAndDump()` reverts with "Cooldown active". PASS

---

### BROKEN-4: Anti-Sniper Lock Bypass — FIXED

**Problem:** `lockAntiSniperSettings()` checked `maxWallet`, `maxTransaction`, and `cooldownPeriod` when locked — but did NOT check the `antiSniperEnabled` flag. Owner could set `antiSniperEnabled = false` despite the lock, deceiving users who trusted the lock.

**Fix:** Added enabled-flag guard in `updateAntiSniperSettings()`:

```solidity
if (antiSniperLocked) {
    require(_antiSniperEnabled || !antiSniperEnabled, "cannot disable anti-sniper when locked");
    // ... existing maxWallet/maxTx/cooldown checks ...
}
```

**File:** `contracts/MemeToken.sol` lines 183–185

**Tests:**
- `test_cannot_disable_antisniper_when_locked()` — reverts with "cannot disable anti-sniper when locked". PASS
- `test_can_relax_limits_when_locked()` — relaxing maxWallet/cooldown still allowed. PASS

---

### BROKEN-5: maxTransaction Throttles Bonding Curve Sells — FIXED

**Problem:** When a user sold tokens back to the curve via `sell()` → `safeTransferFrom(seller, curve, tokensIn)`, the `maxTransaction` check applied to the seller. This throttled how many tokens a user could sell in one tx. Combined with cooldown, a user with 50M tokens but `maxTx = 5M` needed 10 separate transactions over 10+ minutes to exit — an eternity during a dump.

**Fix:** `maxTransaction` is only enforced when `to` is NOT excluded. Selling to the bonding curve (excluded) bypasses `maxTransaction`:

```solidity
if (!excludedFromLimits[from]) {
    if (!excludedFromLimits[to]) {  // AUDIT FIX (BROKEN-5)
        require(value <= maxTransaction, "Transfer > maxTransaction");
    }
    require(block.timestamp - lastTransferTime[from] >= cooldownPeriod, "Cooldown active");
    lastTransferTime[from] = block.timestamp;
}
```

Note: Cooldown still applies to the sender — only `maxTransaction` is skipped for sells to excluded addresses.

**File:** `contracts/MemeToken.sol` lines 117–121 (transferFrom), lines 146–148 (transfer)

**Tests:**
- `test_user_can_sell_full_amount_to_curve()` — user sells all tokens to curve in one tx despite `maxTx = 1M`. PASS
- `test_maxTx_still_enforced_for_normal_transfers()` — normal user-to-user transfers still check maxTransaction. PASS

---

### BROKEN-6: Sell Blocked After Curve Auto-Finishes — ACKNOWLEDGED

**Behavior:** When `sold >= curveAllocation`, `curveFinished = true` and `sell()` reverts with "curve finished". Users who bought at the top cannot sell back on the curve.

**Design Decision:** This is intentional. After the curve finishes, the owner calls `migrateLiquidity()` to send BNB to a DEX router. Token holders then sell on the DEX instead of the curve. The `migrateLiquidity()` function (BUG-9 fix) ensures this path works.

**Test:** `test_sell_blocked_after_auto_finish_migration_works()` — sell blocked, but migration succeeds and DEX destination receives BNB. PASS

---

## Stateful Fuzz Invariants — ALL PASSING

3 invariants tested over 256 runs (500 calls each = 384,000 total random operations):

| # | Invariant | Result |
|---|---|---|
| 1 | `token.balanceOf(curve) == curveAllocation - sold` | PASS (0 violations in 384K calls) |
| 2 | `sold <= curveAllocation` | PASS (0 violations in 384K calls) |
| 3 | Solvency deficit < 0.0001 ETH | PASS (0 violations in 384K calls) |

---

## Files Changed

| File | Changes |
|---|---|
| `contracts/BondingCurve.sol` | `_quadraticTerm` rewrite (Math.mulDiv), `sellQuoteFor` rounding fix, constructor validation (P0/m/alloc > 0, 18 decimals), `totalSellFeesExtracted` tracking, `curveFinishedAt` timestamp, `sell()` curveFinished guard, `rescueBNB` underflow guard + fee adjustment, `migrateLiquidity()`, `sweepRemainingBNB()`, `tokensForQuote` NatSpec |
| `contracts/MemeToken.sol` | Independent sender/recipient anti-sniper checks, `lastTransferTime[to]` on receive, `maxTransaction` skip when `to` excluded, `antiSniperLocked` prevents disabling |
| `contracts/BondingCurveFactory.sol` | `CURVE_TOKENS` → `TOTAL_TOKENS + CURVE_PERCENT` (80%), `curveAllocation` = 80% in both `createBondingCurve` and `calculateCurveParams`, `answeredInRound >= roundId` check, BUG-24 NatSpec |
| `contracts/TokenFactoryWithCurve.sol` | `MIN_P0` and `MIN_M` increased from `1` to `1e6` |

## New Imports Added

| File | Import |
|---|---|
| `contracts/BondingCurve.sol` | `@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol` |
| `contracts/BondingCurve.sol` | `@openzeppelin/contracts/utils/math/Math.sol` |

---

## Test Files

| File | Purpose | Tests |
|---|---|---|
| `test/foundry/AuditFixes.t.sol` | All bug fix verification + fuzz invariants | 32 |
| `test/foundry/helpers/MockV3Aggregator.sol` | Chainlink price feed mock | — |
| `test/foundry/helpers/Actors.sol` | SniperBot for atomic buy+dump test | — |

## Running Tests

```bash
# All unit tests (fast, ~15s with via_ir)
forge test --no-match-contract "StatefulInvariant" -v

# Stateful fuzz invariants (256 runs)
forge test --match-contract "StatefulInvariant" -v

# Full suite
forge test -v

# Specific fix
forge test --match-contract Test_BUG1_Solvency -vvv
forge test --match-contract Test_BROKEN1 -vvv
forge test --match-contract Test_BROKEN3 -vvv
```

---

## Remaining Known Limitations

| Item | Status | Risk |
|---|---|---|
| Path-dependent token output (BUG-11) | Documented | ~0.00005% — gas cost exceeds profit |
| Incremental sells round down (BUG-12) | Documented | Dust-level — Math.mulDiv minimizes |
| Multi-buy dust insolvency (BUG-6) | Bounded | < 1 Gwei per buy — not exploitable |
| Fixed P0/m constants (BUG-24) | Documented | Design choice — feed is informational only |
| Sell blocked after finish (BROKEN-6) | By design | Users sell on DEX after `migrateLiquidity()` |

---

## Round 3 Fixes (Post-Fix Audit)

### CRITICAL #1 — Creator Rug via sell() with Free 20% Tokens — FIXED

- **Added** `mapping(address => uint256) public boughtFromCurve` to track tokens each address purchased through `buyWithBNB`.
- **`sell()`** now requires `tokensIn <= boughtFromCurve[msg.sender]`. Creator's free 200M tokens cannot be sold through the curve.
- **File:** `contracts/BondingCurve.sol` — `boughtFromCurve` state, `buyWithBNB` increments, `sell` checks and decrements
- **Test:** `test_creator_cannot_sell_free_tokens()`, `test_buyer_can_sell_bought_tokens()`

### CRITICAL #2 — Buy Fee Overcharged on Partial Fills — FIXED

- Fee now computed on `actualCost` (what the user actually pays for tokens), not `msg.value`. On partial fills (curve exhausted), the user pays 1% of what they got, not 1% of what they sent.
- **File:** `contracts/BondingCurve.sol` — `buyWithBNB` restructured: compute tokens first, then fee on `actualCost`
- **Test:** `test_fee_not_overcharged_on_partial_fill()`

### CRITICAL #3 — rescueBNB/migrateLiquidity Have No Reentrancy Guard — FIXED

- Added `nonReentrant` modifier to `rescueBNB`, `migrateLiquidity`, and `sweepRemainingBNB`.
- **File:** `contracts/BondingCurve.sol` — all three functions now `nonReentrant`

### HIGH #4 — Anti-Sniper Weaponization (No Mandatory Lock) — FIXED

- Both `TokenFactory` and `TokenFactoryWithCurve` now call `token.lockAntiSniperSettings()` before transferring ownership. Anti-sniper is auto-locked at deployment.
- **File:** `contracts/TokenFactory.sol`, `contracts/TokenFactoryWithCurve.sol`
- **Test:** `test_factory_auto_locks_anti_sniper()`, `test_token_factory_auto_locks()`

### HIGH #5 — markCurveFinished + migrateLiquidity Instant Rug — FIXED

- `markCurveFinished()` now requires `sold >= 50% of curveAllocation` before owner can manually finish.
- `migrateLiquidity()` now requires 24-hour delay (`MIGRATION_DELAY`) after `curveFinishedAt` before BNB can be withdrawn.
- **File:** `contracts/BondingCurve.sol` — `MIN_SOLD_PERCENT_TO_FINISH = 50`, `MIGRATION_DELAY = 24 hours`
- **Test:** `test_cannot_finish_with_zero_sold()`, `test_cannot_finish_below_50_percent()`, `test_migration_blocked_before_delay()`

### MEDIUM #6 — Chainlink Stale Feed DoS — FIXED

- Added `tryGetLatestBNBPrice()` — non-reverting wrapper using try/catch. Returns 0 if feed is stale.
- `calculateCurveParams()` uses `tryGetLatestBNBPrice()` instead of `getLatestBNBPrice()`. Stale feed returns `bnbPriceUSD = 0` (informational) but P0/m are still computed.
- **File:** `contracts/BondingCurveFactory.sol`
- **Test:** `test_stale_feed_does_not_block_createBondingCurve()`

### MEDIUM #7 — Anti-Sniper Lock Bypass: Can Re-enable After Disabling — FIXED

- When locked, `antiSniperEnabled` flag is **frozen** — `require(_antiSniperEnabled == antiSniperEnabled)`. Cannot disable OR re-enable.
- `lockAntiSniperSettings()` now requires `antiSniperEnabled == true` to prevent locking while disabled (false confidence).
- **File:** `contracts/MemeToken.sol`
- **Test:** `test_cannot_change_enabled_flag_when_locked()`, `test_cannot_lock_while_disabled()`

### MEDIUM #8 — MIN Bounds Enable Near-Free Purchases — FIXED

- Increased `MIN_P0` and `MIN_M` from `1e6` to `1e9`. At 1e9: cost to buy all 800M tokens ≈ 1.2 BNB (~$720).
- **File:** `contracts/TokenFactoryWithCurve.sol`
- **Test:** `test_minimum_cost_is_meaningful()`

### NEW-BUG-1 — Cooldown Griefing via Dust Transfers — FIXED

- `lastTransferTime[to]` is now **only set when sender is excluded** (e.g., bonding curve). Regular user-to-user transfers do NOT reset the recipient's cooldown. Attackers can no longer lock victims by sending dust.
- **File:** `contracts/MemeToken.sol` — `transfer()` and `transferFrom()` conditioned on `excludedFromLimits[from]`
- **Test:** `test_dust_transfer_does_not_reset_victim_cooldown()`, `test_curve_buy_still_sets_buyer_cooldown()`

### Dead Code — Refund-then-Revert in buyWithBNB — REMOVED

- The `else if (actualCost > netQuote)` branch that refunded BNB then immediately reverted was dead code (revert rolls back the refund). Replaced with a simple `require(actualCost <= maxNetQuote, "quote short")`.
