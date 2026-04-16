const hre = require("hardhat");

async function main() {
  // Contract addresses (from your deployment)
  // Use the latest deployed address or set in .env
  const TOKEN_FACTORY_ADDRESS = process.env.TOKEN_FACTORY_ADDRESS || "0x10A09f77F7Ab32749467f5Cd93B68798434D5307";
  
  // Token configuration
  const tokenConfig = {
    name: "My Bonding Curve Token",
    symbol: "MBCT",
    decimals: 18,
    description: "A token with bonding curve mechanism",
    logoURL: "https://example.com/logo.png",
    website: "https://example.com",
    github: "https://github.com/example",
    twitter: "@example",
    projectCategories: ["DeFi", "Meme", "BondingCurve"],
    buyOptions: [100, 500, 1000, 5000],
  };

  console.log("Creating token with bonding curve...");
  console.log("TokenFactory Address:", TOKEN_FACTORY_ADDRESS);
  console.log("\nToken Configuration:");
  console.log("  Name:", tokenConfig.name);
  console.log("  Symbol:", tokenConfig.symbol);
  console.log("  Decimals:", tokenConfig.decimals);

  // Get the deployer account
  const [deployer] = await hre.ethers.getSigners();
  console.log("\nCreating token with account:", deployer.address);
  console.log("Account balance:", (await hre.ethers.provider.getBalance(deployer.address)).toString());

  // Connect to TokenFactory
  const TokenFactory = await hre.ethers.getContractFactory("TokenFactory");
  const tokenFactory = await TokenFactory.attach(TOKEN_FACTORY_ADDRESS);

  console.log("\nCalling createTokenWithBondingCurve...");

  // Call createTokenWithBondingCurve
  const tx = await tokenFactory.createTokenWithBondingCurve(
    tokenConfig.name,
    tokenConfig.symbol,
    tokenConfig.decimals,
    tokenConfig.description,
    tokenConfig.logoURL,
    tokenConfig.website,
    tokenConfig.github,
    tokenConfig.twitter,
    tokenConfig.projectCategories,
    tokenConfig.buyOptions
  );

  console.log("Transaction hash:", tx.hash);
  console.log("Waiting for transaction to be mined...");

  const receipt = await tx.wait();
  console.log("Transaction confirmed in block:", receipt.blockNumber);

  // Get the event
  const event = receipt.logs.find(
    (log) => {
      try {
        const parsed = tokenFactory.interface.parseLog(log);
        return parsed && parsed.name === "TokenWithBondingCurveCreated";
      } catch (e) {
        return false;
      }
    }
  );

  if (event) {
    const parsed = tokenFactory.interface.parseLog(event);
    const tokenAddress = parsed.args.tokenAddress;
    const bondingCurveAddress = parsed.args.bondingCurveAddress;
    const creator = parsed.args.creator;

    console.log("\n✅ Token with bonding curve created successfully!");
    console.log("Token Address:", tokenAddress);
    console.log("Bonding Curve Address:", bondingCurveAddress);
    console.log("Creator:", creator);
    console.log("\nView on BscScan:");
    console.log(`  Token: https://testnet.bscscan.com/address/${tokenAddress}`);
    console.log(`  Bonding Curve: https://testnet.bscscan.com/address/${bondingCurveAddress}`);
    
    console.log("\n⚠️  IMPORTANT: You need to deposit 800M tokens to the bonding curve!");
    console.log("  1. Approve bonding curve to spend tokens:");
    console.log(`     Token.approve(${bondingCurveAddress}, 800000000000000000000000000)`);
    console.log("  2. Deposit tokens to bonding curve:");
    console.log(`     BondingCurve.depositCurveTokens(800000000000000000000000000)`);
  } else {
    console.log("\n⚠️  Token created but could not parse event.");
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Error creating token:");
    console.error(error);
    process.exit(1);
  });

