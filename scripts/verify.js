const hre = require("hardhat");

async function main() {
  // Get the contract address from command line arguments or use default
  const contractAddress = process.argv[2];
  
  if (!contractAddress) {
    console.error("Please provide the contract address to verify");
    console.log("Usage: npx hardhat run scripts/verify.js --network bscTestnet <CONTRACT_ADDRESS>");
    process.exit(1);
  }

  console.log(`Verifying contract at address: ${contractAddress}`);
  console.log("Network:", hre.network.name);

  try {
    // Verify TokenFactory (no constructor arguments)
    await hre.run("verify:verify", {
      address: contractAddress,
      constructorArguments: [],
    });
    
    console.log("\n✅ Contract verified successfully!");
    console.log(`View on BscScan: https://testnet.bscscan.com/address/${contractAddress}`);
  } catch (error) {
    if (error.message.includes("Already Verified")) {
      console.log("\n✅ Contract is already verified!");
      console.log(`View on BscScan: https://testnet.bscscan.com/address/${contractAddress}`);
    } else {
      console.error("\n❌ Verification failed:");
      console.error(error.message);
    }
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });



