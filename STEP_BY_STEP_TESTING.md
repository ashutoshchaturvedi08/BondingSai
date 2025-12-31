# Step-by-Step Full Testing Guide

This guide walks you through testing the entire bonding curve system from scratch.

---

## Prerequisites

✅ Make sure you have:
1. `.env` file with:
   - `PRIVATE_KEY=your_private_key_here`
   - `BSCSCAN_API_KEY=your_bscscan_api_key_here`
   - `BNB_PRICE_FEED=0x...` (Chainlink BNB/USD price feed address for BSC Testnet)

2. BNB Testnet BNB in your wallet (for gas fees)

---

## Step 1: Compile Contracts

First, compile all contracts to make sure everything is correct:

```bash
npm run compile
```

**Expected Output:**
```
Compiled X Solidity files successfully
```

---

## Step 2: Deploy Full System

Deploy both `BondingCurveFactory` and `TokenFactory` contracts:

```bash
npm run deploy:full
```

**What this does:**
- Deploys `BondingCurveFactory` with Chainlink price feed integration
- Deploys `TokenFactory` connected to the `BondingCurveFactory`
- Tests fetching BNB price from Chainlink
- Shows calculated bonding curve parameters

**Expected Output:**
```
Deploying Full System (BondingCurveFactory + TokenFactory) to BNB Testnet...

Step 1: Deploying BondingCurveFactory with Chainlink
✅ BondingCurveFactory deployed to: 0x...
✅ Current BNB Price (from Chainlink): 600.0 USD

Step 2: Deploying TokenFactory
✅ TokenFactory deployed to: 0x...

Deployment Summary
BondingCurveFactory: 0x...
TokenFactory: 0x...
```

**⚠️ IMPORTANT:** Save these addresses! You'll need them for testing.

---

## Step 3: Run Full Automated Test

This script does everything automatically:
- Creates a new token with bonding curve
- Deposits 800M tokens to the bonding curve
- Tests buying with 0.001 BNB
- Tests selling tokens
- Shows all results

```bash
npm run test:full
```

**What this does:**
1. ✅ Creates a token with bonding curve
2. ✅ Deposits 800M tokens automatically
3. ✅ Tests buying with 0.001 BNB
4. ✅ Tests selling tokens
5. ✅ Shows final status

**Expected Output:**
```
COMPLETE SYSTEM TEST - Token Creation with Bonding Curve

STEP 1: Creating Token with Bonding Curve
✅ Token Created Successfully!
  Token Address: 0x...
  Bonding Curve Address: 0x...

STEP 2: Depositing 800M Tokens to Bonding Curve
✅ Tokens deposited to bonding curve

STEP 3: Checking Bonding Curve Status
  Tokens Sold: 0.0
  Current Price (BNB): 0.0000000068176181

STEP 4: Testing Buy Function (User 1)
  ⏳ Testing buy with 0.001 BNB...
  ✅ Buy successful!
  ✅ Tokens received: 146XXX.XXX
  ✅ Fee paid: 0.00001 BNB

STEP 5: Testing Sell Function
  ✅ Sell successful!
  ✅ BNB received: 0.000XXX BNB
```

---

## Alternative: Manual Step-by-Step Testing

If you want to test manually step by step:

### Step 3a: Create a Token with Bonding Curve

```bash
npm run create:with-curve
```

**Save the addresses:**
- Token Address: `0x...`
- Bonding Curve Address: `0x...`

---

### Step 3b: Deposit Tokens to Bonding Curve

Open Hardhat console:
```bash
npx hardhat console --network bscTestnet
```

Then run (replace with YOUR addresses):
```javascript
// Replace with your addresses from Step 3a
const tokenAddress = "YOUR_TOKEN_ADDRESS";
const bondingCurveAddress = "YOUR_BONDING_CURVE_ADDRESS";

// Get contracts
const MemeToken = await ethers.getContractFactory("MemeToken");
const token = await MemeToken.attach(tokenAddress);

const BondingCurve = await ethers.getContractFactory("BondingCurveBNB");
const bondingCurve = await BondingCurve.attach(bondingCurveAddress);

// Check your balance
const [deployer] = await ethers.getSigners();
const balance = await token.balanceOf(deployer.address);
console.log("Your balance:", ethers.formatEther(balance));

// Transfer 800M tokens to bonding curve
const curveTokens = ethers.parseEther("800000000");
const tx = await token.transfer(bondingCurveAddress, curveTokens);
await tx.wait();
console.log("✅ Tokens deposited!");

// Verify
const curveBalance = await token.balanceOf(bondingCurveAddress);
console.log("Curve balance:", ethers.formatEther(curveBalance));
```

---

### Step 3c: Check Bonding Curve Status

```bash
export BONDING_CURVE_ADDRESS=YOUR_BONDING_CURVE_ADDRESS
npm run bonding:info
```

Or in Hardhat console:
```javascript
const sold = await bondingCurve.sold();
const curveAllocation = await bondingCurve.curveAllocation();
const currentPrice = await bondingCurve.priceAt(sold);

console.log("Tokens Sold:", ethers.formatEther(sold));
console.log("Curve Allocation:", ethers.formatEther(curveAllocation));
console.log("Current Price (BNB):", ethers.formatEther(currentPrice));
```

---

### Step 3d: Test Buying Tokens (0.001 BNB)

```bash
export BONDING_CURVE_ADDRESS=YOUR_BONDING_CURVE_ADDRESS
npm run bonding:buy 0.001
```

**Expected Output:**
```
Buying tokens with 0.001 BNB...
Estimated tokens out: 146XXX.XXX
Transaction hash: 0x...
✅ Buy successful! Block: 12345678
Tokens received: 146XXX.XXX
Fee paid: 0.00001 BNB
```

---

### Step 3e: Test Selling Tokens

```bash
npm run bonding:sell 1000
```

**Expected Output:**
```
Selling 1000 tokens...
Transaction hash: 0x...
✅ Sell successful! Block: 12345679
BNB received: 0.000XXX BNB
Fee paid: 0.00000X BNB
```

---

## Quick Reference: All Commands

```bash
# 1. Compile
npm run compile

# 2. Deploy full system
npm run deploy:full

# 3. Run full automated test
npm run test:full

# OR Manual testing:
# 3a. Create token
npm run create:with-curve

# 3b. Buy tokens
export BONDING_CURVE_ADDRESS=0x...
npm run bonding:buy 0.001

# 3c. Sell tokens
npm run bonding:sell 1000

# 3d. Check status
npm run bonding:info
```

---

## Troubleshooting

### Issue: "Contract not deployed"
**Solution:** Run `npm run deploy:full` first

### Issue: "Insufficient BNB"
**Solution:** Make sure you have BNB testnet tokens in your wallet

### Issue: "Price feed error"
**Solution:** Check that `BNB_PRICE_FEED` in `.env` is correct for BSC Testnet

### Issue: "Tokens not deposited"
**Solution:** Make sure you've deposited 800M tokens to the bonding curve before buying

---

## What to Verify

After testing, verify:

✅ **Token Creation:**
- Token address exists
- Bonding curve address exists
- View on BscScan

✅ **Token Deposit:**
- 800M tokens in bonding curve
- 200M tokens remain with creator

✅ **Buy Function:**
- Tokens received in wallet
- 1% fee sent to fee recipient
- Price increased after purchase

✅ **Sell Function:**
- BNB received in wallet
- 1% fee sent to fee recipient
- Price decreased after sale
- Tokens returned to bonding curve

---

## Next Steps After Testing

1. ✅ Verify contracts on BscScan
2. ✅ Test with multiple users
3. ✅ Test edge cases (large buys, selling all tokens)
4. ✅ Deploy to BSC Mainnet
5. ✅ Update price feed address for mainnet
6. ✅ Launch your platform!

---

## Summary

**Quick Start (Recommended):**
```bash
npm run compile          # Step 1
npm run deploy:full      # Step 2
npm run test:full        # Step 3 (does everything automatically)
```

That's it! The automated test does everything for you.


