const hre = require("hardhat");
const { calculateBondingCurveParams } = require("./calculateBondingCurve");

async function main() {
  const networkName = hre.network.name;
  const isLocalhost = networkName === "localhost" || networkName === "hardhat";
  
  console.log(`Deploying Full System (BondingCurveFactory + TokenFactory) to ${networkName}...`);

  // Configuration
  const FEE_RECIPIENT = "0xc8EC74b1C61049C9158C14c16259227e03E5B8EC"; // Master wallet
  
  // Get the deployer account
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying with account:", deployer.address);
  console.log("Account balance:", (await hre.ethers.provider.getBalance(deployer.address)).toString());

  // Step 0: Deploy MockPriceFeed if on localhost
  let BNB_PRICE_FEED;
  if (isLocalhost) {
    console.log("\n" + "=".repeat(60));
    console.log("Step 0: Deploying MockPriceFeed for localhost");
    console.log("=".repeat(60));
    const MockPriceFeed = await hre.ethers.getContractFactory("MockPriceFeed");
    const mockPriceFeed = await MockPriceFeed.deploy();
    await mockPriceFeed.waitForDeployment();
    BNB_PRICE_FEED = await mockPriceFeed.getAddress();
    console.log("✅ MockPriceFeed deployed to:", BNB_PRICE_FEED);
    console.log("   Mock BNB Price: $875 USD");
  } else {
    // Chainlink BNB/USD Price Feed addresses
    // BSC Mainnet: 0x0567F2323251f0Aab15c8dFbB7a6333D0d8771a3
    // BSC Testnet: Check https://docs.chain.link/data-feeds/price-feeds/addresses
    BNB_PRICE_FEED = process.env.BNB_PRICE_FEED || "0x0567F2323251f0Aab15c8dFbB7a6333D0d8771a3";
  }

  // Step 1: Deploy BondingCurveFactory with Chainlink Price Feed
  console.log("\n" + "=".repeat(60));
  console.log("Step 1: Deploying BondingCurveFactory with Chainlink");
  console.log("=".repeat(60));
  console.log("BNB/USD Price Feed:", BNB_PRICE_FEED);
  const BondingCurveFactory = await hre.ethers.getContractFactory("BondingCurveFactory");
  const bondingCurveFactory = await BondingCurveFactory.deploy(
    FEE_RECIPIENT,
    BNB_PRICE_FEED
  );
  await bondingCurveFactory.waitForDeployment();
  const bondingCurveFactoryAddress = await bondingCurveFactory.getAddress();
  console.log("✅ BondingCurveFactory deployed to:", bondingCurveFactoryAddress);
  
  // Test fetching BNB price
  try {
    const bnbPrice = await bondingCurveFactory.getLatestBNBPrice();
    const bnbPriceFormatted = hre.ethers.formatEther(bnbPrice);
    console.log("✅ Current BNB Price (from Chainlink):", bnbPriceFormatted, "USD");
  } catch (error) {
    console.log("⚠️  Could not fetch BNB price:", error.message);
  }

  // Step 2: Deploy TokenFactory with BondingCurveFactory
  console.log("\n" + "=".repeat(60));
  console.log("Step 2: Deploying TokenFactory");
  console.log("=".repeat(60));
  const TokenFactory = await hre.ethers.getContractFactory("TokenFactory");
  const tokenFactory = await TokenFactory.deploy(bondingCurveFactoryAddress);
  await tokenFactory.waitForDeployment();
  const tokenFactoryAddress = await tokenFactory.getAddress();
  console.log("✅ TokenFactory deployed to:", tokenFactoryAddress);

  // Verify deployments
  console.log("\n" + "=".repeat(60));
  console.log("Deployment Summary");
  console.log("=".repeat(60));
  console.log("BondingCurveFactory:", bondingCurveFactoryAddress);
  console.log("TokenFactory:", tokenFactoryAddress);
  console.log("Fee Recipient:", FEE_RECIPIENT);
  console.log("BNB Price Feed:", BNB_PRICE_FEED);
  
  // Show bonding curve parameters (calculated dynamically)
  try {
    const curveParams = await bondingCurveFactory.calculateCurveParams();
    console.log("\nBonding Curve Parameters (from Chainlink):");
    console.log("  P0_WAD:", curveParams.p0_wad.toString());
    console.log("  M_WAD:", curveParams.m_wad.toString());
    console.log("  Current BNB Price (USD):", hre.ethers.formatEther(curveParams.bnbPriceUSD));
  } catch (error) {
    console.log("\n⚠️  Could not calculate curve params:", error.message);
  }

  console.log("\n✅ Full system deployed successfully!");
  console.log("\nYou can now:");
  console.log("1. Create tokens with bonding curves using TokenFactory");
  console.log("2. Update BNB price in BondingCurveFactory if needed");
  console.log("3. Interact with bonding curves to buy/sell tokens");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

