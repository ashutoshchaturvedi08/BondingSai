const hre = require("hardhat");

async function main() {
  console.log("Deploying TokenFactory to BNB Testnet...");

  // Get the deployer account
  const [deployer] = await hre.ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  console.log("Account balance:", (await hre.ethers.provider.getBalance(deployer.address)).toString());

  // Deploy TokenFactory
  const TokenFactory = await hre.ethers.getContractFactory("TokenFactory");
  const tokenFactory = await TokenFactory.deploy();
  await tokenFactory.waitForDeployment();

  const tokenFactoryAddress = await tokenFactory.getAddress();
  console.log("TokenFactory deployed to:", tokenFactoryAddress);

  // Optional: Verify deployment by checking owner
  const owner = await tokenFactory.owner();
  console.log("TokenFactory owner:", owner);
  console.log("\nDeployment completed successfully!");
  console.log("\nYou can now use the TokenFactory to create tokens:");
  console.log("  - createDefaultToken(name, symbol) - Creates a token with default settings");
  console.log("  - createCustomToken(...) - Creates a token with custom settings");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

