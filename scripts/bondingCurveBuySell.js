const hre = require("hardhat");

async function main() {
  // Configuration - Update these addresses
  // NOTE: This should be the bonding curve address from your token creation, NOT the factory address
  const BONDING_CURVE_ADDRESS = process.env.BONDING_CURVE_ADDRESS || "0x..."; // Set this after creating a token
  const ACTION = process.argv[2] || "buy"; // "buy" or "sell"
  const AMOUNT = process.argv[3] || "0.000000001"; // BNB amount for buy, or token amount for sell

  console.log(`Bonding Curve Interaction: ${ACTION.toUpperCase()}`);
  console.log("Bonding Curve Address:", BONDING_CURVE_ADDRESS);

  const [account] = await hre.ethers.getSigners();
  console.log("Account:", account.address);
  console.log("Account balance:", hre.ethers.formatEther(await hre.ethers.provider.getBalance(account.address)));

  const BondingCurve = await hre.ethers.getContractFactory("BondingCurveBNB");
  const bondingCurve = await BondingCurve.attach(BONDING_CURVE_ADDRESS);

  if (ACTION === "buy") {
    // Buy tokens with BNB
    const bnbAmount = hre.ethers.parseEther(AMOUNT);
    console.log(`\nBuying tokens with ${AMOUNT} BNB...`);

    // Get quote first
    const sold = await bondingCurve.sold();
    const quote = await bondingCurve.tokensForQuote(sold, bnbAmount);
    console.log("Estimated tokens out:", hre.ethers.formatEther(quote));

    // Execute buy
    const tx = await bondingCurve.buyWithBNB(0, { value: bnbAmount }); // minTokensOut = 0 for now
    console.log("Transaction hash:", tx.hash);
    const receipt = await tx.wait();
    console.log("✅ Buy successful! Block:", receipt.blockNumber);

    // Get event
    const buyEvent = receipt.logs.find((log) => {
      try {
        const parsed = bondingCurve.interface.parseLog(log);
        return parsed && parsed.name === "Buy";
      } catch (e) {
        return false;
      }
    });

    if (buyEvent) {
      const parsed = bondingCurve.interface.parseLog(buyEvent);
      console.log("Tokens received:", hre.ethers.formatEther(parsed.args.tokensOut));
      console.log("Fee paid:", hre.ethers.formatEther(parsed.args.fee));
    }

  } else if (ACTION === "sell") {
    // Sell tokens for BNB
    const tokenAmount = hre.ethers.parseEther(AMOUNT);
    console.log(`\nSelling ${AMOUNT} tokens...`);

    // Get token address and approve
    const tokenAddress = await bondingCurve.token();
    const Token = await hre.ethers.getContractFactory("MemeToken");
    const token = await Token.attach(tokenAddress);

    // Check balance
    const balance = await token.balanceOf(account.address);
    console.log("Token balance:", hre.ethers.formatEther(balance));

    if (balance < tokenAmount) {
      console.error("❌ Insufficient token balance!");
      process.exit(1);
    }

    // Approve bonding curve
    console.log("Approving bonding curve...");
    const approveTx = await token.approve(BONDING_CURVE_ADDRESS, tokenAmount);
    await approveTx.wait();
    console.log("✅ Approved");

    // Get quote
    const sold = await bondingCurve.sold();
    const quote = await bondingCurve.sellQuoteFor(sold, tokenAmount);
    console.log("Estimated BNB out:", hre.ethers.formatEther(quote));

    // Execute sell
    const tx = await bondingCurve.sell(tokenAmount, 0); // minQuoteOut = 0 for now
    console.log("Transaction hash:", tx.hash);
    const receipt = await tx.wait();
    console.log("✅ Sell successful! Block:", receipt.blockNumber);

    // Get event
    const sellEvent = receipt.logs.find((log) => {
      try {
        const parsed = bondingCurve.interface.parseLog(log);
        return parsed && parsed.name === "Sell";
      } catch (e) {
        return false;
      }
    });

    if (sellEvent) {
      const parsed = bondingCurve.interface.parseLog(sellEvent);
      console.log("BNB received:", hre.ethers.formatEther(parsed.args.bnbOut));
      console.log("Fee paid:", hre.ethers.formatEther(parsed.args.fee));
    }

  } else if (ACTION === "info") {
    // Get bonding curve info
    console.log("\nBonding Curve Information:");
    const sold = await bondingCurve.sold();
    const curveAllocation = await bondingCurve.curveAllocation();
    const curveFinished = await bondingCurve.curveFinished();
    const currentPrice = await bondingCurve.priceAt(sold);

    console.log("Tokens sold:", hre.ethers.formatEther(sold));
    console.log("Curve allocation:", hre.ethers.formatEther(curveAllocation));
    console.log("Current price (BNB):", hre.ethers.formatEther(currentPrice));
    console.log("Curve finished:", curveFinished);
    console.log("Progress:", ((Number(sold) / Number(curveAllocation)) * 100).toFixed(2) + "%");
  } else {
    console.error("Invalid action. Use 'buy', 'sell', or 'info'");
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

