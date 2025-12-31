const hre = require("hardhat");

/**
 * Local Price Calculator - Test prices WITHOUT deploying contracts
 * This saves gas by calculating prices off-chain first
 */

// Constants matching the contract
const WAD = BigInt("1000000000000000000"); // 1e18
const CURVE_TOKENS = 1_000_000_000; // 1B tokens
const TRADABLE_TOKENS = 800_000_000; // 800M tradable
const TARGET_P0_BNB_NUMERATOR = 5798;
const TARGET_P0_BNB_DENOMINATOR = 1e12;
const FEE_BPS = 100; // 1%
const BPS_BASE = 10000;

// Calculate P0 in WAD
const P0_WAD = (BigInt(TARGET_P0_BNB_NUMERATOR) * WAD) / BigInt(TARGET_P0_BNB_DENOMINATOR);

// Price at sold s: P(s) = P0 + m * s / curveAllocation
function priceAt(s, m_wad) {
    const curveAllocationWad = BigInt(CURVE_TOKENS) * WAD;
    if (curveAllocationWad === 0n) return P0_WAD;
    const mTerm = (m_wad * BigInt(s)) / curveAllocationWad;
    return P0_WAD + mTerm;
}

// Cost to buy ds tokens from state s
// Cost = P(s) * ds / WAD + 0.5 * m * ds^2 / (curveAllocation * WAD)
function buyQuoteFor(s, ds, m_wad) {
    if (ds === 0n) return 0n;
    const curveAllocationWad = BigInt(CURVE_TOKENS) * WAD;
    if (curveAllocationWad === 0n) return 0n;
    
    const b = priceAt(s, m_wad);
    const term1 = (b * ds) / WAD;
    const term2 = (m_wad * ds * ds) / (2n * curveAllocationWad * WAD);
    return term1 + term2;
}

// Binary search for tokens given BNB amount
function tokensForQuote(s, netQuoteBNB, m_wad) {
    if (netQuoteBNB === 0n) return 0n;
    
    const netQuoteWei = BigInt(Math.floor(Number(netQuoteBNB) * 1e18));
    const maxTradable = BigInt(TRADABLE_TOKENS) * WAD;
    const remaining = maxTradable > BigInt(s) ? (maxTradable - BigInt(s)) : 0n;
    if (remaining === 0n) return 0n;
    
    // Estimate
    const currentPrice = priceAt(s, m_wad);
    if (currentPrice === 0n) return 0n;
    const estimatedTokens = (netQuoteWei * WAD) / currentPrice;
    
    let low = 1n;
    let high = estimatedTokens > remaining ? remaining : estimatedTokens;
    if (high === 0n) return 0n;
    
    let answer = 0n;
    let iterations = 0;
    const maxIterations = 100;
    
    while (low <= high && iterations < maxIterations) {
        iterations++;
        const mid = (low + high) / 2n;
        if (mid === 0n) break;
        
        const cost = buyQuoteFor(s, mid, m_wad);
        
        if (cost <= netQuoteWei) {
            answer = mid;
            if (low === high) break;
            if (mid === high) break;
            low = mid + 1n;
        } else {
            if (mid <= 1n) break;
            high = mid - 1n;
        }
    }
    
    return answer;
}

// Calculate m directly from expected token amounts (matching four.meme)
function calculateM() {
    // Expected: 0.99 BNB → 147,334,426 tokens
    // Cost = P0*s + 0.5*m*s^2/CURVE_TOKENS
    // Solving for m: m = 2 * (cost - P0*s) * CURVE_TOKENS / s^2
    const targetTokensSold = BigInt(147_334_426) * WAD;
    const targetCostWei = BigInt(Math.floor(0.99 * 1e18));
    
    // P0 term: P0 * s / WAD (result in wei)
    const p0TermWei = (P0_WAD * targetTokensSold) / WAD;
    
    // Calculate m
    if (targetCostWei > p0TermWei && targetTokensSold > 0n) {
        const costDiffWei = targetCostWei - p0TermWei;
        // s^2 / WAD to keep proper scale
        const sSquared = (targetTokensSold * targetTokensSold) / WAD;
        // numerator: 2 * costDiff * CURVE_TOKENS
        const numerator = 2n * costDiffWei * BigInt(CURVE_TOKENS);
        // m_wad = numerator / sSquared
        const m_wad = numerator / sSquared;
        return m_wad;
    }
    
    return 0n;
}

async function main() {
    console.log("======================================================================");
    console.log("LOCAL PRICE CALCULATOR - Test Prices Without Deploying");
    console.log("======================================================================\n");
    
    // Get BNB price (you can set this manually or fetch from Chainlink)
    const BNB_PRICE_USD = process.env.BNB_PRICE_USD || 875.53706221;
    console.log(`BNB Price (USD): $${BNB_PRICE_USD}\n`);
    
    // Calculate m (doesn't depend on BNB price, calculated from expected amounts)
    const m_wad = calculateM();
    const m_bnb = Number(m_wad) / Number(WAD);
    
    console.log("Curve Parameters:");
    console.log(`  P0: ${(Number(P0_WAD) / Number(WAD)).toExponential()} BNB per token`);
    console.log(`  m: ${m_bnb.toExponential()} BNB per token²`);
    console.log(`  Curve Allocation: ${CURVE_TOKENS.toLocaleString()} tokens`);
    console.log(`  Tradable: ${TRADABLE_TOKENS.toLocaleString()} tokens (80%)`);
    console.log(`  Locked: ${(CURVE_TOKENS - TRADABLE_TOKENS).toLocaleString()} tokens (20%)\n`);
    
    // Test different BNB amounts
    console.log("======================================================================");
    console.log("TOKEN QUOTES FOR DIFFERENT BNB AMOUNTS");
    console.log("======================================================================\n");
    
    const testAmounts = [
        { bnb: 1, label: "1 BNB" },
        { bnb: 0.1, label: "0.1 BNB" },
        { bnb: 0.01, label: "0.01 BNB" },
        { bnb: 0.001, label: "0.001 BNB" }
    ];
    
    const expected = {
        1: 147334426,
        0.1: 16808861,
        0.01: 1704902,
        0.001: 170734
    };
    
    let s = 0; // Start with 0 tokens sold
    
    for (const { bnb, label } of testAmounts) {
        const bnbWei = BigInt(Math.floor(bnb * 1e18));
        const fee = (bnbWei * BigInt(FEE_BPS)) / BigInt(BPS_BASE);
        const netBNB = bnbWei - fee;
        const netBNBFormatted = Number(netBNB) / 1e18;
        
        const tokens = tokensForQuote(s, netBNBFormatted, m_wad);
        const tokensFormatted = Number(tokens) / 1e18;
        
        const expectedTokens = expected[bnb] || 0;
        const diff = expectedTokens - tokensFormatted;
        const diffPercent = expectedTokens > 0 ? ((diff / expectedTokens) * 100).toFixed(2) : 0;
        
        console.log(`📊 ${label}:`);
        console.log(`   BNB Input: ${bnb} BNB`);
        console.log(`   Net BNB (after 1% fee): ${netBNBFormatted.toFixed(9)} BNB`);
        console.log(`   Tokens You'll Get: ${tokensFormatted.toLocaleString(undefined, { maximumFractionDigits: 0 })} tokens`);
        if (expectedTokens > 0) {
            console.log(`   Expected: ${expectedTokens.toLocaleString()} tokens`);
            console.log(`   Difference: ${diff.toLocaleString()} tokens (${diffPercent}%)`);
        }
        console.log("");
        
        // Update s for next calculation (simulate buying)
        s += Number(tokens);
    }
    
    console.log("======================================================================");
    console.log("✅ PRICE CALCULATION COMPLETE");
    console.log("======================================================================\n");
    console.log("💡 If amounts don't match expected, adjust m calculation in factory");
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });

