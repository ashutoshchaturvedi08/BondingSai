# 🚀 Quick Start Guide - Full Testing

## The Simplest Way (3 Commands)

### Step 1: Compile Contracts
```bash
npm run compile
```

### Step 2: Deploy Full System
```bash
npm run deploy:full
```

**📝 Save the addresses shown:**
- `BondingCurveFactory: 0x...`
- `TokenFactory: 0x...`

### Step 3: Run Full Test
```bash
npm run test:full
```

**That's it!** The test will:
- ✅ Create a new token with bonding curve
- ✅ Deposit 800M tokens automatically
- ✅ Buy tokens with 0.001 BNB
- ✅ Sell tokens
- ✅ Show all results

---

## If Test Script Needs Addresses

If `npm run test:full` fails because it can't find the contracts, update the addresses:

### Option 1: Set Environment Variables

Add to your `.env` file:
```bash
TOKEN_FACTORY_ADDRESS=0x...  # From Step 2
BONDING_CURVE_FACTORY_ADDRESS=0x...  # From Step 2
```

Then run:
```bash
npm run test:full
```

### Option 2: Update Script Directly

Edit `scripts/testFullSystem.js` and update line 18-19:
```javascript
const TOKEN_FACTORY_ADDRESS = "YOUR_TOKEN_FACTORY_ADDRESS";
const BONDING_CURVE_FACTORY_ADDRESS = "YOUR_BONDING_CURVE_FACTORY_ADDRESS";
```

---

## Complete Command Sequence

```bash
# 1. Compile
npm run compile

# 2. Deploy (save addresses from output)
npm run deploy:full

# 3. Test (update addresses if needed, then run)
npm run test:full
```

---

## Expected Output

After running `npm run test:full`, you should see:

```
✅ Token Created Successfully!
  Token Address: 0x...
  Bonding Curve Address: 0x...

✅ Tokens deposited to bonding curve

✅ Buy successful!
  Tokens received: 146XXX.XXX
  Fee paid: 0.00001 BNB

✅ Sell successful!
  BNB received: 0.000XXX BNB
```

---

## Troubleshooting

**"Contract not found"** → Run `npm run deploy:full` first

**"Insufficient BNB"** → Get testnet BNB from faucet

**"Price feed error"** → Check `BNB_PRICE_FEED` in `.env`

---

For detailed step-by-step instructions, see `STEP_BY_STEP_TESTING.md`


