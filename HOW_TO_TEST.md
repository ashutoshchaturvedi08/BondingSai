# How to Test Your Bonding Curve System

## Quick Start - Run Full Automated Test

The easiest way to test everything:

```bash
npm run test:full
```

This will automatically:
1. ✅ Create a new token with bonding curve
2. ✅ Deposit 800M tokens to the bonding curve
3. ✅ Test buying tokens (tries small amounts automatically)
4. ✅ Test selling tokens
5. ✅ Show final status

---

## Manual Step-by-Step Testing

### Step 1: Create a Token with Bonding Curve

```bash
npm run create:with-curve
```

**Output**: You'll get:
- Token Address: `0x...`
- Bonding Curve Address: `0x...`

**Save these addresses!**

---

### Step 2: Deposit Tokens to Bonding Curve

Open Hardhat console:
```bash
npx hardhat console --network bscTestnet
```

Then run (replace with YOUR addresses from Step 1):
```javascript
// Replace these with your addresses
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

// Transfer 800M tokens directly to bonding curve
const curveTokens = ethers.parseEther("800000000");
await token.transfer(bondingCurveAddress, curveTokens);
console.log("✅ Tokens deposited!");
```

---

### Step 3: Test Buying Tokens

**Option A: Using the script (recommended)**

```bash
# Set your bonding curve address
export BONDING_CURVE_ADDRESS=YOUR_BONDING_CURVE_ADDRESS

# Buy with 0.00001 BNB (very small amount)
npm run bonding:buy 0.00001
```

**Option B: Using Hardhat console**

```javascript
// In Hardhat console
const bondingCurveAddress = "YOUR_BONDING_CURVE_ADDRESS";
const BondingCurve = await ethers.getContractFactory("BondingCurveBNB");
const bondingCurve = await BondingCurve.attach(bondingCurveAddress);

// Buy with 0.00001 BNB (deadline = 5 min from now, per LOT-21)
const buyAmount = ethers.parseEther("0.00001");
const deadline = Math.floor(Date.now() / 1000) + 300;
const buyTx = await bondingCurve.buyWithBNB(0, deadline, { value: buyAmount });
await buyTx.wait();
console.log("✅ Buy successful!");

// Check your token balance
const tokenAddress = await bondingCurve.token();
const MemeToken = await ethers.getContractFactory("MemeToken");
const token = await MemeToken.attach(tokenAddress);
const balance = await token.balanceOf(await ethers.provider.getSigner().getAddress());
console.log("Your tokens:", ethers.formatEther(balance));
```

---

### Step 4: Test Selling Tokens

**Option A: Using the script**

```bash
# Sell 1000 tokens
npm run bonding:sell 1000
```

**Option B: Using Hardhat console**

```javascript
// Get your token balance
const tokenBalance = await token.balanceOf(await ethers.provider.getSigner().getAddress());
console.log("Your balance:", ethers.formatEther(tokenBalance));

// Sell half of your tokens
const sellAmount = tokenBalance / 2n;

// Approve bonding curve
await token.approve(bondingCurveAddress, sellAmount);

// Execute sell (minQuoteOut = 0, deadline = 5 min)
const sellDeadline = Math.floor(Date.now() / 1000) + 300;
const sellTx = await bondingCurve.sell(sellAmount, 0, sellDeadline);
await sellTx.wait();
console.log("✅ Sell successful!");

// Check your BNB balance
const bnbBalance = await ethers.provider.getBalance(await ethers.provider.getSigner().getAddress());
console.log("Your BNB:", ethers.formatEther(bnbBalance));
```

---

### Step 5: Check Bonding Curve Status

```bash
npm run bonding:info
```

Or in console:
```javascript
const sold = await bondingCurve.sold();
const curveAllocation = await bondingCurve.curveAllocation();
const currentPrice = await bondingCurve.priceAt(sold);
const curveFinished = await bondingCurve.curveFinished();

console.log("Tokens Sold:", ethers.formatEther(sold));
console.log("Curve Allocation:", ethers.formatEther(curveAllocation));
console.log("Current Price (BNB):", ethers.formatEther(currentPrice));
console.log("Progress:", (Number(sold) / Number(curveAllocation) * 100).toFixed(2) + "%");
console.log("Curve Finished:", curveFinished);
```

---

## Testing with Very Small Amounts

The system now supports very small amounts. Try these:

```bash
# Very small amounts (will find minimum automatically)
npm run bonding:buy 0.000000001  # 1 gwei
npm run bonding:buy 0.00000001   # 10 gwei
npm run bonding:buy 0.0000001    # 100 gwei
npm run bonding:buy 0.000001     # 0.000001 BNB
npm run bonding:buy 0.00001      # 0.00001 BNB
```

The script will automatically find the minimum working amount if your specified amount is too small.

---

## What to Verify

After each test, verify:

### ✅ After Token Creation
- Token address received
- Bonding curve address received
- View on BscScan

### ✅ After Deposit
- 800M tokens in bonding curve
- 200M tokens remain with creator

### ✅ After Buy
- Tokens received in your wallet
- 1% fee sent to fee recipient (`0xc8EC74b1C61049C9158C14c16259227e03E5B8EC`)
- Price increased after purchase
- `sold` amount increased

### ✅ After Sell
- BNB received in your wallet
- 1% fee sent to fee recipient
- Price decreased after sale
- `sold` amount decreased
- Tokens returned to bonding curve

---

## Current Contract Addresses

- **TokenFactory**: `0x3450366939c65cC5aD76e7B650401438afc4dD57`
- **BondingCurveFactory**: `0x0371999eC1B5a81427567Eff4dBd71B93fFA1FA3`
- **Fee Recipient**: `0xc8EC74b1C61049C9158C14c16259227e03E5B8EC`

---

## Troubleshooting

### Issue: "insufficient BNB"
**Solution**: The amount is too small. The script will automatically try larger amounts.

### Issue: "insufficient liquidity" (when selling)
**Solution**: Make sure someone has bought tokens first (bonding curve needs BNB from buys to allow sells).

### Issue: "Transfer failed"
**Solution**: Make sure you have approved the bonding curve before depositing tokens.

### Issue: Network connection error
**Solution**: Check your internet connection and BSC testnet RPC endpoint.

---

## Quick Commands Reference

```bash
# Full automated test
npm run test:full

# Create token
npm run create:with-curve

# Buy tokens
export BONDING_CURVE_ADDRESS=0x...
npm run bonding:buy 0.00001

# Sell tokens
npm run bonding:sell 1000

# Check status
npm run bonding:info
```

---

## Next Steps After Testing

1. ✅ Verify all contracts on BscScan
2. ✅ Test with multiple users
3. ✅ Test edge cases (very large buys, selling all tokens, etc.)
4. ✅ Deploy to BSC Mainnet
5. ✅ Update price feed address for mainnet
6. ✅ Launch your platform!


