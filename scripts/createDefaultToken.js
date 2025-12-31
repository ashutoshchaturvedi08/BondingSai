const hre = require("hardhat");

async function main() {
  // TokenFactory contract address (deployed earlier)
  const TOKEN_FACTORY_ADDRESS = "0x6105FE0FB45b94434f81A2b236E3D80B69fd92f0";

  // Simple token configuration - Edit these values
  const tokenName = "My Default Token";
  const tokenSymbol = "MDT";

  console.log("Creating default token via TokenFactory...");
  console.log("TokenFactory Address:", TOKEN_FACTORY_ADDRESS);
  console.log("\nToken Configuration:");
  console.log("  Name:", tokenName);
  console.log("  Symbol:", tokenSymbol);
  console.log("  Supply: 1,000,000,000 (1 billion)");
  console.log("  Decimals: 18");

  // Get the deployer account
  const [deployer] = await hre.ethers.getSigners();
  console.log("\nCreating token with account:", deployer.address);
  console.log("Account balance:", (await hre.ethers.provider.getBalance(deployer.address)).toString());

  // Connect to the deployed TokenFactory contract
  const TokenFactory = await hre.ethers.getContractFactory("TokenFactory");
  const tokenFactory = await TokenFactory.attach(TOKEN_FACTORY_ADDRESS);

  console.log("\nCalling createDefaultToken...");

  // Call createDefaultToken
  const tx = await tokenFactory.createDefaultToken(tokenName, tokenSymbol);

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


