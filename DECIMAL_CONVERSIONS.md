# Decimal Conversions Guide

This document explains how decimals are handled throughout the bonding curve system.

## Decimal Standards

- **USD (Chainlink Price Feed)**: 8 decimals
- **BNB**: 18 decimals (wei)
- **Tokens**: 18 decimals (raw token units)
- **WAD (Fixed Point)**: 18 decimals (used for price calculations)

## Conversion Flow

### 1. Chainlink Price Feed → BNB Price (WAD)

```solidity
// Chainlink returns: rawPrice (8 decimals)
// Example: BNB = $600 → rawPrice = 600 * 10^8 = 60000000000

// Convert to WAD (18 decimals):
price = rawPrice * 10^10
// Result: 600 * 10^18 = 600000000000000000000
```

**File**: `BondingCurveFactory.sol` → `getLatestBNBPrice()`

---

### 2. USD Market Cap → USD Price Per Token (WAD)

```solidity
// Market cap targets:
START_MARKET_CAP_USD = 5000  // $5,000 (no decimals)
END_MARKET_CAP_USD = 50000   // $50,000 (no decimals)
CURVE_TOKENS = 800_000_000   // 800M tokens (raw count)

// Calculate USD price per token:
p0_usd_wad = (5000 * 1e18) / 800_000_000
// = 6.25e-6 * 1e18 = 6.25e12
// This represents $0.00000625 per token (with 18 decimals)
```

**File**: `BondingCurveFactory.sol` → `calculateCurveParams()`

---

### 3. USD Price → BNB Price (WAD)

```solidity
// Convert USD price to BNB price:
p0_wad = (p0_usd_wad * WAD) / bnbPriceUSD
// Both p0_usd_wad and bnbPriceUSD are in WAD (18 decimals)
// Result: p0_wad is in WAD, representing BNB wei per token

// Example:
// p0_usd_wad = 6.25e12 ($0.00000625)
// bnbPriceUSD = 600 * 1e18 ($600)
// p0_wad = (6.25e12 * 1e18) / (600 * 1e18) = 1.04e10
// This means: 1.04e10 / 1e18 = 0.0000000104 BNB per token
```

**File**: `BondingCurveFactory.sol` → `calculateCurveParams()`

---

### 4. Slope Calculation (WAD)

```solidity
// Calculate slope: m = (Pmax - P0) / CURVE_TOKENS
m_wad = ((pmax_wad - p0_wad) * WAD) / CURVE_TOKENS

// m_wad represents: change in BNB wei per token, per token sold
// Units: WAD (18 decimals)
```

**File**: `BondingCurveFactory.sol` → `calculateCurveParams()`

---

### 5. Price Calculation in Bonding Curve

```solidity
// Price at state s (tokens sold):
P(s) = P0 + m * s / WAD

// Where:
// - P0: WAD-scaled (BNB wei per token)
// - m: WAD-scaled (BNB wei per token per token)
// - s: Raw token units (18 decimals)
// - Result: WAD-scaled (BNB wei per token)
```

**File**: `BondingCurve.sol` → `priceAt()`

---

### 6. Cost Calculation (Buy)

```solidity
// Cost to buy ds tokens from state s:
cost = (P(s) * ds) / WAD + (m * ds^2) / (2 * WAD)

// Where:
// - P(s): WAD-scaled (BNB wei per token)
// - ds: Raw token units (18 decimals)
// - m: WAD-scaled
// - Result: BNB wei (18 decimals)

// Example:
// P(s) = 1e18 (1 wei per token)
// ds = 1e18 (1 token)
// cost = (1e18 * 1e18) / 1e18 + ... = 1e18 wei = 1 wei
```

**File**: `BondingCurve.sol` → `buyQuoteFor()`

---

## Key Points

1. **All prices are stored in WAD (18 decimals)** to maintain precision
2. **Token amounts are in raw units** (e.g., 1 token = 1e18)
3. **BNB amounts are in wei** (18 decimals)
4. **USD prices are converted from 8 decimals to 18 decimals** for consistency

## Testing with 0.001 BNB

When testing with 0.001 BNB:
- `0.001 BNB = 1e15 wei`
- After 1% fee: `netQuote = 0.00099 BNB = 9.9e14 wei`
- The `tokensForQuote()` function uses binary search to find how many tokens can be bought with this amount

## Verification

To verify calculations are correct:
1. Check that `P0` and `m` are reasonable (should be very small for micro-tokens)
2. Check that `priceAt(0)` returns a small value (starting price)
3. Check that `buyQuoteFor(0, 1e18)` returns a small cost (cost for 1 token at start)

