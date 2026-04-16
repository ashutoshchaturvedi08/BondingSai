# Token Factory Project

This project contains the TokenFactory and MemeToken smart contracts for creating tokens on Binance Smart Chain (BSC) Testnet.

## Contracts

- **TokenFactory**: A factory contract that allows users to create new MemeToken instances
- **MemeToken**: A BEP20-like token with anti-sniper protection, metadata support, and customizable settings

## Features

- Create tokens with default settings (1 billion supply, 9 decimals)
- Create tokens with custom settings and metadata
- Anti-sniper protection with configurable limits
- Rich metadata support (description, logo, website, social links)
- Project categories and buy options
- Owner-controlled configuration

## Setup

1. Install dependencies:
```bash
npm install
```

2. Create a `.env` file from `.env.example`:
```bash
cp .env.example .env
```

3. Add your private key and BscScan API key to `.env`:
```
PRIVATE_KEY=your_private_key_here
BSCSCAN_API_KEY=your_bscscan_api_key_here
```

**⚠️ WARNING**: Never commit your private key or `.env` file to version control!

**To get a BscScan API key:**
1. Go to https://testnet.bscscan.com/
2. Create an account or log in
3. Go to your account settings → API Keys
4. Create a new API key
5. Add it to your `.env` file

## Compilation

Compile the contracts:
```bash
npx hardhat compile
```

## Deployment

Deploy to BNB Testnet:
```bash
npx hardhat run scripts/deploy.js --network bscTestnet
```

Deploy to BNB Mainnet:
```bash
npx hardhat run scripts/deploy.js --network bsc
```

## Contract Verification

After deploying, verify your contract on BscScan:

```bash
npx hardhat verify --network bscTestnet <CONTRACT_ADDRESS>
```

For example, if your TokenFactory is deployed at `0x6105FE0FB45b94434f81A2b236E3D80B69fd92f0`:

```bash
npx hardhat verify --network bscTestnet 0x6105FE0FB45b94434f81A2b236E3D80B69fd92f0
```

**Note**: TokenFactory has no constructor arguments, so you don't need to pass any.

After verification, you'll see a link to the verified contract on BscScan where you can interact with it.

## Configuration

The Hardhat configuration matches the original contract settings:
- Solidity version: 0.8.28
- Optimizer: enabled with 1000 runs
- Via IR: enabled
- EVM Version: Paris

## Networks

- **BSC Testnet**: Chain ID 97
  - RPC URL: https://data-seed-prebsc-1-s1.binance.org:8545/
- **BSC Mainnet**: Chain ID 56
  - RPC URL: https://bsc-dataseed.binance.org/

## Usage

After deploying the TokenFactory, you can create tokens using the provided scripts:

### Create a Default Token (Simple)
```bash
npm run create:default
```
Or manually:
```bash
npx hardhat run scripts/createDefaultToken.js --network bscTestnet
```

This creates a token with:
- 1 billion supply
- 18 decimals
- Default settings

Edit `scripts/createDefaultToken.js` to change the token name and symbol.

### Create a Custom Token (Full Control)
```bash
npm run create:token
```
Or manually:
```bash
npx hardhat run scripts/createToken.js --network bscTestnet
```

Edit `scripts/createToken.js` to customize:
- Token name and symbol
- Decimals and total supply
- Description and metadata (logo, website, social links)
- Project categories
- Buy options

### Programmatic Usage

You can also interact with the TokenFactory programmatically:

```javascript
const TokenFactory = await ethers.getContractFactory("TokenFactory");
const tokenFactory = await TokenFactory.attach("0x6105FE0FB45b94434f81A2b236E3D80B69fd92f0");

// Create default token
const tokenAddress = await tokenFactory.createDefaultToken("MyToken", "MTK");

// Create custom token
const tokenAddress = await tokenFactory.createCustomToken(
  "MyToken",           // name
  "MTK",               // symbol
  18,                  // decimals
  1000000,             // totalSupply
  "Description",       // description
  "https://...",       // logoURL
  "https://...",       // website
  "https://...",       // github
  "@twitter",          // twitter
  ["DeFi", "Meme"],    // projectCategories
  [100, 500, 1000]     // buyOptions
);
```

## Contract Source

These contracts were retrieved from Sourcify:
- TokenFactory: https://repo.sourcify.dev/contracts/full_match/97/0xdcdC481657Df78bFf3551b1742897C7a500B293B
- MemeToken: https://repo.sourcify.dev/contracts/full_match/97/0xC3A4c23094efE94Ede90785A09b7Ff6EAC1B8908

## License

MIT

