# Quick Testing Guide

## 🚀 Fastest Way to Test Everything

### Option 1: Run Complete Automated Test (Recommended)

```bash
npm run test:full
```

This will automatically:
- ✅ Create a token
- ✅ Deposit tokens to bonding curve
- ✅ Test buying
- ✅ Test selling
- ✅ Show all results

---

## 📝 Manual Step-by-Step

### Step 1: Create a Token

```bash
npm run create:with-curve
```

**Output**: You'll get token address and bonding curve address

**Example Output:**
```
Token Address: 0x...
Bonding Curve Address: 0x...
```

### Step 2: Deposit Tokens to Bonding Curve

**Open Hardhat Console:**
```bash
npx hardhat console --network bscTestnet
```

**Then run:**
```javascript
// Replace with your addresses from Step 1
const tokenAddress = "YOUR_TOKEN_ADDRESS";
const bondingCurveAddress = "YOUR_BONDING_CURVE_ADDRESS";

// Get contracts
const MemeToken = await ethers.getContractFactory("MemeToken");
const token = await MemeToken.attach(tokenAddress);

const BondingCurve = await ethers.getContractFactory("BondingCurveBNB");
const bondingCurve = await BondingCurve.attach(bondingCurveAddress);

// Approve and deposit 800M tokens
const curveTokens = ethers.parseEther("800000000");
await token.approve(bondingCurveAddress, curveTokens);
await bondingCurve.depositCurveTokens(curveTokens);
console.log("✅ Done!");
```

### Step 3: Test Buying

**Set bonding curve address:**
```bash
export BONDING_CURVE_ADDRESS=YOUR_BONDING_CURVE_ADDRESS
```

**Buy with 0.01 BNB:**
```bash
npm run bonding:buy 0.01
```

### Step 4: Test Selling

**Sell 1000 tokens:**
```bash
npm run bonding:sell 1000
```

### Step 5: Check Status

```bash
npm run bonding:info
```

---

## 📊 Your Current Contract Addresses

- **TokenFactory**: `0x3450366939c65cC5aD76e7B650401438afc4dD57`
- **BondingCurveFactory**: `0x0371999eC1B5a81427567Eff4dBd71B93fFA1FA3`
- **Fee Recipient**: `0xc8EC74b1C61049C9158C14c16259227e03E5B8EC`

---

## ✅ What to Verify

After each step, verify:

1. **After Token Creation:**
   - ✅ Token address received
   - ✅ Bonding curve address received
   - ✅ View on BscScan

2. **After Deposit:**
   - ✅ 800M tokens in bonding curve
   - ✅ 200M tokens remain with creator

3. **After Buy:**
   - ✅ Tokens received
   - ✅ 1% fee deducted
   - ✅ Price increased

4. **After Sell:**
   - ✅ BNB received
   - ✅ 1% fee deducted
   - ✅ Price decreased

---

## 🎯 Quick Commands Reference

```bash
# Create token
npm run create:with-curve

# Buy tokens
export BONDING_CURVE_ADDRESS=0x...
npm run bonding:buy 0.01

# Sell tokens
npm run bonding:sell 1000

# Check status
npm run bonding:info

# Full automated test
npm run test:full
```

---

## 📖 Full Documentation

See `TESTING_GUIDE.md` for detailed instructions and troubleshooting.


