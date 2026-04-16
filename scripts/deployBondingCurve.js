const hre = require("hardhat");
const { calculateBondingCurveParams } = require("./calculateBondingCurve");

async function main() {
  console.log("Deploying BondingCurveFactory to BNB Testnet...");

  // Configuration
  const FEE_RECIPIENT = "0xc8EC74b1C61049C9158C14c16259227e03E5B8EC"; // Master wallet
  
  // Chainlink BNB/USD Price Feed addresses
  // BSC Mainnet: 0x0567F2323251f0Aab15c8dFbB7a6333D0d8771a3
  // BSC Testnet: Check https://docs.chain.link/data-feeds/price-feeds/addresses
  // For testnet, you may need to use a mock or find the testnet address
  const BNB_PRICE_FEED = process.env.BNB_PRICE_FEED || "0x2514895c72f50D8bd4B4F9b1110F0D6bD2c97526"; // Default to mainnet address

  // Get the deployer account
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  console.log("Account balance:", (await hre.ethers.provider.getBalance(deployer.address)).toString());

  // Deploy BondingCurveFactory with Chainlink Price Feed
  console.log("\nDeploying BondingCurveFactory with Chainlink Price Feed...");
  console.log("BNB/USD Price Feed:", BNB_PRICE_FEED);
  
  const BondingCurveFactory = await hre.ethers.getContractFactory("BondingCurveFactory");
  const bondingCurveFactory = await BondingCurveFactory.deploy(
    FEE_RECIPIENT,
    BNB_PRICE_FEED
  );
  await bondingCurveFactory.waitForDeployment();

  const factoryAddress = await bondingCurveFactory.getAddress();
  console.log("BondingCurveFactory deployed to:", factoryAddress);
  console.log("Fee Recipient:", FEE_RECIPIENT);
  
  // Test fetching BNB price
  try {
    const bnbPrice = await bondingCurveFactory.getLatestBNBPrice();
    const bnbPriceFormatted = hre.ethers.formatEther(bnbPrice);
    console.log("Current BNB Price (from Chainlink):", bnbPriceFormatted, "USD");
  } catch (error) {
    console.log("⚠️  Could not fetch BNB price (may be testnet or wrong address):", error.message);
  }

  // Verify deployment
  const owner = await bondingCurveFactory.owner();
  console.log("Factory owner:", owner);

  console.log("\n✅ Deployment completed successfully!");
  console.log("\nNext steps:");
  console.log("1. Update TokenFactory with BondingCurveFactory address");
  console.log("2. Use createTokenWithBondingCurve() to create tokens with bonding curves");
  console.log("3. BNB price is now fetched dynamically from Chainlink - no manual updates needed!");
  console.log("\nFactory Address:", factoryAddress);
  console.log("\nNote: Make sure the BNB Price Feed address is correct for your network!");
  console.log("  Mainnet: 0x0567F2323251f0Aab15c8dFbB7a6333D0d8771a3");
  console.log("  Testnet: Check Chainlink docs for testnet address");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

