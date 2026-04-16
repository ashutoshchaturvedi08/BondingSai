/**
 * Helper script to calculate bonding curve parameters
 * Based on requirements:
 * - Start: $5,000 market cap
 * - End: $50,000 market cap
 * - 800M tokens on curve
 * - Formula: P(x) = P0 + m * x
 * - P0 = 0.00000625 USD
 * - Pmax ≈ 0.00011875 USD
 */

const hre = require("hardhat");

// Constants from requirements
const START_MARKET_CAP_USD = 5000; // $5,000
const END_MARKET_CAP_USD = 50000; // $50,000
const CURVE_TOKENS = 800_000_000; // 800M tokens
const TOTAL_SUPPLY = 1_000_000_000; // 1B tokens (800M curve + 200M liquidity)

// Price calculations in USD
const P0_USD = START_MARKET_CAP_USD / CURVE_TOKENS; // 0.00000625
const AVG_PRICE_USD = END_MARKET_CAP_USD / CURVE_TOKENS; // 0.0000625
const PMAX_USD = 2 * AVG_PRICE_USD - P0_USD; // ≈ 0.00011875

// Slope calculation
const M_USD = (PMAX_USD - P0_USD) / CURVE_TOKENS; // 1.41e-10

function calculateBondingCurveParams(bnbPriceUSD) {
  if (!bnbPriceUSD || bnbPriceUSD <= 0) {
    throw new Error("BNB price must be provided and > 0");
  }

  // Convert USD prices to BNB prices
  const P0_BNB = P0_USD / bnbPriceUSD;
  const PMAX_BNB = PMAX_USD / bnbPriceUSD;
  const M_BNB = M_USD / bnbPriceUSD;

  // Convert to WAD (1e18) scaled values for contract
  const WAD = hre.ethers.parseEther("1"); // 1e18
  const P0_WAD = BigInt(Math.floor(P0_BNB * 1e18));
  const M_WAD = BigInt(Math.floor(M_BNB * 1e18));

  // Calculate with token decimals (assuming 18 decimals)
  const TOKEN_DECIMALS = 18;
  const CURVE_ALLOCATION = BigInt(CURVE_TOKENS) * BigInt(10 ** TOKEN_DECIMALS);

  return {
    // USD values (for reference)
    usd: {
      startMarketCap: START_MARKET_CAP_USD,
      endMarketCap: END_MARKET_CAP_USD,
      p0: P0_USD,
      pmax: PMAX_USD,
      m: M_USD,
      bnbPrice: bnbPriceUSD,
    },
    // BNB values
    bnb: {
      p0: P0_BNB,
      pmax: PMAX_BNB,
      m: M_BNB,
    },
    // Contract parameters (WAD scaled)
    contract: {
      p0_wad: P0_WAD.toString(),
      m_wad: M_WAD.toString(),
      curveAllocation: CURVE_ALLOCATION.toString(),
      tokenDecimals: TOKEN_DECIMALS,
    },
    // Formula
    formula: {
      linear: `P(x) = ${P0_BNB.toFixed(18)} + ${M_BNB.toExponential()} * x`,
      usdFormula: `P(x) = ${P0_USD} + ${M_USD.toExponential()} * x`,
    },
  };
}

// Main function
function main() {
  // Get BNB price from command line or use default
  const args = process.argv.slice(2);
  const bnbPriceUSD = args[0] ? parseFloat(args[0]) : 600; // Default $600

  console.log("=".repeat(60));
  console.log("Bonding Curve Parameter Calculator");
  console.log("=".repeat(60));
  console.log("\nRequirements:");
  console.log(`  Start Market Cap: $${START_MARKET_CAP_USD.toLocaleString()}`);
  console.log(`  End Market Cap: $${END_MARKET_CAP_USD.toLocaleString()}`);
  console.log(`  Tokens on Curve: ${CURVE_TOKENS.toLocaleString()}`);
  console.log(`  Total Supply: ${TOTAL_SUPPLY.toLocaleString()}`);
  console.log(`  BNB Price (USD): $${bnbPriceUSD}`);

  const params = calculateBondingCurveParams(bnbPriceUSD);

  console.log("\n" + "=".repeat(60));
  console.log("USD Price Formula:");
  console.log("=".repeat(60));
  console.log(`  P0 (Initial): $${params.usd.p0.toFixed(10)}`);
  console.log(`  Pmax (Final): $${params.usd.pmax.toFixed(10)}`);
  console.log(`  Slope (m): ${params.usd.m.toExponential()}`);
  console.log(`  Formula: ${params.formula.usdFormula}`);

  console.log("\n" + "=".repeat(60));
  console.log("BNB Price Formula:");
  console.log("=".repeat(60));
  console.log(`  P0 (Initial): ${params.bnb.p0.toFixed(18)} BNB`);
  console.log(`  Pmax (Final): ${params.bnb.pmax.toFixed(18)} BNB`);
  console.log(`  Slope (m): ${params.bnb.m.toExponential()} BNB`);
  console.log(`  Formula: ${params.formula.linear}`);

  console.log("\n" + "=".repeat(60));
  console.log("Contract Parameters (for deployment):");
  console.log("=".repeat(60));
  console.log(`  P0_WAD: ${params.contract.p0_wad}`);
  console.log(`  M_WAD: ${params.contract.m_wad}`);
  console.log(`  Curve Allocation: ${params.contract.curveAllocation}`);
  console.log(`  Token Decimals: ${params.contract.tokenDecimals}`);

  console.log("\n" + "=".repeat(60));
  console.log("Example Usage:");
  console.log("=".repeat(60));
  console.log(`  P0_WAD: ${params.contract.p0_wad}`);
  console.log(`  M_WAD: ${params.contract.m_wad}`);
  console.log(`  Curve Allocation: ${params.contract.curveAllocation}`);
  console.log(`  Fee Recipient: 0xc8EC74b1C61049C9158C14c16259227e03E5B8EC`);

  return params;
}

if (require.main === module) {
  main();
}

module.exports = { calculateBondingCurveParams };


