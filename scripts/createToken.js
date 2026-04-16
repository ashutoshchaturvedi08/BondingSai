const hre = require("hardhat");

async function main() {
  // TokenFactory contract address (deployed earlier)
  const TOKEN_FACTORY_ADDRESS = "0x6105FE0FB45b94434f81A2b236E3D80B69fd92f0";

  // Token configuration - Edit these values to customize your token
  const tokenConfig = {
    name: "My Custom Token",
    symbol: "MCT",
    decimals: 18,
    totalSupply: 1000000, // 1 million tokens (will be multiplied by 10^decimals)
    description: "A custom meme token created via TokenFactory",
    logoURL: "https://example.com/logo.png",
    website: "https://example.com",
    github: "https://github.com/example",
    twitter: "@example",
    projectCategories: ["DeFi", "Meme", "Community"],
    buyOptions: [100, 500, 1000, 5000], // Buy options in base units
  };

  console.log("Creating custom token via TokenFactory...");
  console.log("TokenFactory Address:", TOKEN_FACTORY_ADDRESS);
  console.log("\nToken Configuration:");
  console.log("  Name:", tokenConfig.name);
  console.log("  Symbol:", tokenConfig.symbol);
  console.log("  Decimals:", tokenConfig.decimals);
  console.log("  Total Supply:", tokenConfig.totalSupply);
  console.log("  Description:", tokenConfig.description);
  console.log("  Categories:", tokenConfig.projectCategories.join(", "));
  console.log("  Buy Options:", tokenConfig.buyOptions.join(", "));

  // Get the deployer account
  const [deployer] = await hre.ethers.getSigners();
  console.log("\nCreating token with account:", deployer.address);
  console.log("Account balance:", (await hre.ethers.provider.getBalance(deployer.address)).toString());

  // Connect to the deployed TokenFactory contract
  const TokenFactory = await hre.ethers.getContractFactory("TokenFactory");
  const tokenFactory = await TokenFactory.attach(TOKEN_FACTORY_ADDRESS);

  console.log("\nCalling createCustomToken...");

  // Call createCustomToken
  const tx = await tokenFactory.createCustomToken(
    tokenConfig.name,
    tokenConfig.symbol,
    tokenConfig.decimals,
    tokenConfig.totalSupply,
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

  // Wait for the transaction to be mined
  const receipt = await tx.wait();
  console.log("Transaction confirmed in block:", receipt.blockNumber);

  // Get the TokenCreated event to find the new token address
  const tokenCreatedEvent = receipt.logs.find(
    (log) => {
      try {
        const parsed = tokenFactory.interface.parseLog(log);
        return parsed && parsed.name === "TokenCreated";
      } catch (e) {
        return false;
      }
    }
  );

  if (tokenCreatedEvent) {
    const parsed = tokenFactory.interface.parseLog(tokenCreatedEvent);
    const tokenAddress = parsed.args.tokenAddress;
    const creator = parsed.args.creator;
    const name = parsed.args.name;
    const symbol = parsed.args.symbol;

    console.log("\n✅ Token created successfully!");
    console.log("Token Address:", tokenAddress);
    console.log("Token Name:", name);
    console.log("Token Symbol:", symbol);
    console.log("Creator:", creator);
    console.log("\nView on BscScan:");
    console.log(`  https://testnet.bscscan.com/address/${tokenAddress}`);
    console.log("\nYou can now interact with your token at the address above!");
  } else {
    console.log("\n⚠️  Token created but could not parse event. Check transaction receipt.");
    console.log("Transaction receipt:", receipt);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("\n❌ Error creating token:");
    console.error(error);
    process.exit(1);
  });


