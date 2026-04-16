# Chainlink Price Feed Integration

## Overview

The BondingCurveFactory now uses **Chainlink Price Feeds** to fetch BNB/USD price dynamically at runtime. This eliminates the need to manually update BNB prices.

## How It Works

1. **Chainlink Price Feed**: The contract uses Chainlink's decentralized oracle network to get real-time BNB/USD prices
2. **Automatic Updates**: Prices are fetched on-chain whenever a bonding curve is created
3. **No Manual Intervention**: No need to call `updateBNBPrice()` anymore

## Chainlink Price Feed Addresses

### BSC Mainnet
```
BNB/USD: 0x0567F2323251f0Aab15c8dFbB7a6333D0d8771a3
```

### BSC Testnet
Check the official Chainlink documentation for testnet addresses:
https://docs.chain.link/data-feeds/price-feeds/addresses

## Contract Changes

### BondingCurveFactory.sol

**New Features:**
- `getLatestBNBPrice()` - Fetches current BNB price from Chainlink
- `calculateCurveParams()` - Now uses Chainlink price automatically
- Removed manual `updateBNBPrice()` function (no longer needed)

**Constructor:**
```solidity
constructor(address _feeRecipient, address _bnbPriceFeed)
```

**Price Feed Details:**
- Chainlink returns prices with **8 decimals**
- Contract converts to **18 decimals (WAD)** for internal calculations
- Example: If Chainlink returns `60000000000` (8 decimals), it represents $600.00

## Deployment

### Using Environment Variable
```bash
export BNB_PRICE_FEED=0x0567F2323251f0Aab15c8dFbB7a6333D0d8771a3
npm run deploy:full
```

### Or Update Script Directly
Edit `scripts/deployFullSystem.js` or `scripts/deployBondingCurve.js`:
```javascript
const BNB_PRICE_FEED = "0x0567F2323251f0Aab15c8dFbB7a6333D0d8771a3"; // Mainnet
```

## Usage

### Creating a Bonding Curve

When you call `createBondingCurve()`, the contract will:
1. Automatically fetch the latest BNB/USD price from Chainlink
2. Calculate P0 and M parameters based on the current price
3. Deploy the bonding curve with correct parameters

### Viewing Current Price

```javascript
const bnbPrice = await bondingCurveFactory.getLatestBNBPrice();
console.log("BNB Price:", ethers.formatEther(bnbPrice), "USD");
```

### Getting Curve Parameters

```javascript
const params = await bondingCurveFactory.calculateCurveParams();
console.log("P0_WAD:", params.p0_wad.toString());
console.log("M_WAD:", params.m_wad.toString());
console.log("BNB Price:", ethers.formatEther(params.bnbPriceUSD), "USD");
```

## Benefits

✅ **Real-time Price Data**: Always uses current market price  
✅ **No Manual Updates**: Eliminates need for owner to update prices  
✅ **Decentralized**: Uses Chainlink's decentralized oracle network  
✅ **Reliable**: Chainlink aggregates data from multiple sources  
✅ **Gas Efficient**: Price feeds are already on-chain, just a view call  

## Important Notes

1. **Testnet**: Make sure to use the correct Chainlink price feed address for your network
2. **Price Feed Availability**: Chainlink price feeds are available on BSC mainnet. For testnet, you may need to deploy a mock or use a different oracle
3. **Price Staleness**: Chainlink price feeds are updated regularly, but check the `latestRoundData()` timestamp if needed
4. **Gas Costs**: Fetching from Chainlink is a view call (free) when called externally, but costs gas when called in a transaction

## References

- [Chainlink Documentation](https://docs.chain.link/data-feeds/price-feeds)
- [Chainlink Price Feed Addresses](https://docs.chain.link/data-feeds/price-feeds/addresses)
- [How to Fetch Price Data in Solidity](https://blog.chain.link/fetch-current-crypto-price-data-solidity/)


