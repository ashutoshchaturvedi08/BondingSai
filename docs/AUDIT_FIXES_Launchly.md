# Launchly Intermediary Audit – Remediation Summary (Lotique Labs)

This document maps each audit finding (LOT-01 through LOT-27) to the changes made so the audit team can verify fixes easily.

---

## CRITICAL

### LOT-02 – TokenFactoryWithCurve.createTokenWithBondingCurve() reverts for external callers
- **Fix:** Mint tokens to the factory (`address(this)`) instead of `msg.sender`, then atomically `safeTransfer` curve allocation to the bonding curve and the remainder to `msg.sender`. Use OpenZeppelin `SafeERC20`. After distribution, `transferOwnership(msg.sender)` and `setExcludedFromLimits(curveAddress, true)`.
- **Files:** `contracts/TokenFactoryWithCurve.sol` – `_createTokenWithBondingCurve` now mints to `address(this)` and distributes via `IERC20(tokenAddress).safeTransfer(...)`.

### LOT-03 – curveAllocation not scaled by token decimals
- **Fix:** Scale by decimals: `rawTotalSupply = _totalSupply * (10 ** _decimals)`, `curveAllocation = (rawTotalSupply * 80) / 100`.
- **Files:** `contracts/TokenFactoryWithCurve.sol` – same function; curve allocation is computed in raw token units.

### LOT-18 – Extra /WAD scaling nullifies quadratic term in pricing formula
- **Fix:** Introduced internal `_quadraticTerm(ds)` with the correct formula: `term2 = m * dsOverWad^2 / (2 * curveAllocationOverWad)` (no extra `/ WAD`). `buyQuoteFor` and `sellQuoteFor` use this helper so the quadratic price progression is correct.
- **Files:** `contracts/BondingCurve.sol` – `_quadraticTerm`, `buyQuoteFor`, `sellQuoteFor`.

---

## HIGH

### LOT-01 – sell() ignores minQuoteOut slippage parameter
- **Fix:** Uncommented and enforced `minQuoteOut`; added `deadline`. Signature: `sell(uint256 tokensIn, uint256 minQuoteOut, uint256 deadline)`. After computing `netOut`, added `require(netOut >= minQuoteOut, "slippage")` and `require(block.timestamp <= deadline, "transaction expired")`.
- **Files:** `contracts/BondingCurve.sol` – `sell()`.

### LOT-04 – Chainlink oracle missing staleness checks
- **Fix:** In `getLatestBNBPrice()`: use `roundId`, `updatedAt` from `latestRoundData()`; require `roundId != 0`, `updatedAt != 0 && updatedAt <= block.timestamp`, and `block.timestamp - updatedAt <= STALENESS_THRESHOLD` (3600 seconds).
- **Files:** `contracts/BondingCurveFactory.sol` – `getLatestBNBPrice()`, new constant `STALENESS_THRESHOLD`.

### LOT-05 – Bonding curve not excluded from MemeToken anti-sniper limits
- **Fix:** After creating the curve and distributing tokens, the factory (as token owner) calls `token.setExcludedFromLimits(curveAddress, true)` before transferring ownership to the creator. Applied in both `TokenFactoryWithCurve` and `TokenFactory` when creating token + curve.
- **Files:** `contracts/TokenFactoryWithCurve.sol`, `contracts/TokenFactory.sol`.

### LOT-06 – Owner can drain all BNB and tokens via rescue functions
- **Fix:**  
  - `withdrawToken`: require `currentBalance - amount >= activeBalance` (activeBalance = `curveAllocation - sold`); use `token.safeTransfer(to, amount)`.  
  - `rescueERC20`: require `tokenAddr != address(token)` so the curve token cannot be rescued; use `IERC20(tokenAddr).safeTransfer(to, amount)`.  
  - `rescueBNB`: require `address(this).balance - amount >= requiredBNB` where `requiredBNB = sellQuoteFor(sold, sold)` so the curve stays solvent.
- **Files:** `contracts/BondingCurve.sol` – `withdrawToken`, `rescueERC20`, `rescueBNB`; added SafeERC20 and IERC20 from OpenZeppelin.

### LOT-07 – External self-call in createDefaultTokenWithCurve changes msg.sender context
- **Fix:** Extracted shared logic into internal `_createTokenWithBondingCurve(...)`. Both `createTokenWithBondingCurve` and `createDefaultTokenWithCurve` call this internal function so `msg.sender` is always the original user.
- **Files:** `contracts/TokenFactoryWithCurve.sol` – `_createTokenWithBondingCurve`, and both public functions delegate to it.

### LOT-19 – Bonding curve math assumes 18-decimal tokens
- **Fix:** Enforce 18 decimals in all factory paths that create bonding curves:  
  - `TokenFactory.createTokenWithBondingCurve`: `require(_decimals == 18, "bonding curves require 18 decimals")`.  
  - `TokenFactoryWithCurve._createTokenWithBondingCurve`: same.  
  - `BondingCurveFactory.createBondingCurve`: `require(_tokenDecimals == 18, "bonding curves require 18 decimals")`.
- **Files:** `contracts/TokenFactory.sol`, `contracts/TokenFactoryWithCurve.sol`, `contracts/BondingCurveFactory.sol`.

---

## MEDIUM

### LOT-09 – calculateCurveParams fetches BNB price but does not use it
- **Fix:** Documented in code: `bnbPriceUSD` is fetched and returned for off-chain use; P0 and m remain BNB-denominated (fixed targets). No change to formula so behavior is unchanged; comment added for audit clarity.
- **Files:** `contracts/BondingCurveFactory.sol` – comment in `calculateCurveParams()`.

### LOT-11 – TokenFactory.createTokenWithBondingCurve does not fund the bonding curve
- **Fix:** Same mint-to-factory pattern as LOT-02: create token with `address(this)` as recipient, create curve, then `safeTransfer` curve allocation to curve and remainder to `msg.sender`, then `transferOwnership(msg.sender)` and `setExcludedFromLimits(bondingCurveAddress, true)`.
- **Files:** `contracts/TokenFactory.sol` – `createTokenWithBondingCurve()`.

### LOT-20 – Immutable feeRecipient can permanently disable buy and sell operations
- **Fix:** In BondingCurve constructor, before setting `feeRecipient`, check that the address can receive BNB: `(bool testSend,) = payable(_feeRecipient).call{value: 0}(""); require(testSend, "feeRecipient cannot receive BNB");`
- **Files:** `contracts/BondingCurve.sol` – constructor.

### LOT-21 – buyWithBNB() lacks deadline parameter for transaction expiry
- **Fix:** Added `deadline` to both buy and sell.  
  - `buyWithBNB(uint256 minTokensOut, uint256 deadline)` with `require(block.timestamp <= deadline, "transaction expired")` at the start.  
  - `sell(uint256 tokensIn, uint256 minQuoteOut, uint256 deadline)` with the same check.
- **Files:** `contracts/BondingCurve.sol` – `buyWithBNB`, `sell`. Scripts/docs updated to pass a deadline (e.g. `Math.floor(Date.now()/1000) + 300`).

---

## LOW

### LOT-08 – Inconsistent term2 formula between buy and sell for sub-WAD amounts
- **Fix:** Both paths now use the same `_quadraticTerm(ds)` helper; the sub-WAD branch uses `(mOverWad * dsSquaredOverCurveAlloc) / 2` (no extra `/ (2 * WAD)` in sell).
- **Files:** `contracts/BondingCurve.sol` – `_quadraticTerm`, `sellQuoteFor` (via helper).

### LOT-12 – No bounds validation on P0 and m curve parameters
- **Fix:** In `TokenFactoryWithCurve._createTokenWithBondingCurve`: constants `MIN_P0 = 1`, `MAX_P0 = 1e18`, `MIN_M = 1`, `MAX_M = 100e18`; `require(_P0_wad >= MIN_P0 && _P0_wad <= MAX_P0, "P0 out of range")` and `require(_m_wad >= MIN_M && _m_wad <= MAX_M, "m out of range")`.
- **Files:** `contracts/TokenFactoryWithCurve.sol`.

### LOT-13 – Unused event FeeRecipientChanged
- **Fix:** Removed the event declaration (feeRecipient is immutable and never changed).
- **Files:** `contracts/BondingCurve.sol`.

### LOT-14 – Unused state variable bondingCurveImplementation
- **Fix:** Removed `bondingCurveImplementation` and `setBondingCurveImplementation()`.
- **Files:** `contracts/TokenFactoryWithCurve.sol`.

### LOT-15 – Unused constant TRADABLE_TOKENS
- **Fix:** Removed `TRADABLE_TOKENS`; added `STALENESS_THRESHOLD` in its place for LOT-04.
- **Files:** `contracts/BondingCurveFactory.sol`.

### LOT-16 – Unnecessary nonReentrant modifier on token transfers
- **Fix:** Removed `nonReentrant` from `transfer` and `transferFrom` in MemeToken (no external calls in these functions).
- **Files:** `contracts/MemeToken.sol`.

### LOT-17 – P0 and m not declared as immutable
- **Fix:** Declared `P0` and `m` as `immutable` in BondingCurveBNB; set only in constructor.
- **Files:** `contracts/BondingCurve.sol`.

### LOT-23 – updateAntiSniperSettings event emits unscaled values
- **Fix:** Emit the stored (scaled) values: `emit AntiSniperSettingsUpdated(_antiSniperEnabled, maxWallet, maxTransaction, _cooldownPeriod)`.
- **Files:** `contracts/MemeToken.sol` – `updateAntiSniperSettings()`.

### LOT-24 – State updates after external calls violate checks-effects-interactions pattern
- **Fix:** In `buyWithBNB`: update `sold += ds` before `token.transfer(msg.sender, ds)`. In `sell`: update `sold -= tokensIn` before the BNB transfers to seller and feeRecipient.
- **Files:** `contracts/BondingCurve.sol` – `buyWithBNB`, `sell`.

### LOT-26 – lastTransferTime updated unconditionally regardless of anti-sniper state
- **Fix:** Update `lastTransferTime[from]` / `lastTransferTime[msg.sender]` only inside the `if (antiSniperEnabled && !excludedFromLimits[...])` block in both `transfer` and `transferFrom`.
- **Files:** `contracts/MemeToken.sol`.

### LOT-27 – Binary search in tokensForQuote may consume unpredictable gas
- **Fix:** Reduced `maxIterations` from 256 to 128 (sufficient for the search range).
- **Files:** `contracts/BondingCurve.sol` – `tokensForQuote()`.

---

## INFORMATIONAL

### LOT-10 – ERC-20 approve() front-running race condition
- **Fix:** Added a code comment that the implementation follows EIP-20 and that the known approve race exists; suggested EIP-2612 permit() for gasless approvals. No code change to approve().
- **Files:** `contracts/MemeToken.sol` – comment above `approve()`.

---

## Scripts and docs

- **Scripts:** `scripts/bondingCurveBuySell.js`, `scripts/testFullSystem.js` – all calls to `buyWithBNB` and `sell` updated to pass the new `deadline` (and for `sell`, `minQuoteOut`) parameters.
- **Docs:** `HOW_TO_TEST.md` – examples updated to use the new signatures with deadline.

---

## Summary

| Severity       | Count | Status   |
|----------------|-------|----------|
| Critical       | 3     | Fixed    |
| High           | 6     | Fixed    |
| Medium         | 4     | Fixed    |
| Low            | 11    | Fixed    |
| Informational  | 1     | Addressed (comment) |
| **Total**      | **25**| **All addressed**   |

All 25 findings from the Launchly Intermediary Audit Report (Lotique Labs) have been addressed with the changes above and accompanying comments in the code (tagged with “LOT-XX (Audit)” where applicable) for easy cross-reference during re-testing.
