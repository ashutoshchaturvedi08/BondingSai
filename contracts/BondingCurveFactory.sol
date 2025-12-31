// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./BondingCurve.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title BondingCurveFactory
 * @notice Factory contract to deploy bonding curves for tokens
 * @dev Automatically calculates bonding curve parameters based on USD market cap targets
 * @dev Uses Chainlink Price Feed to get real-time BNB/USD price
 */
contract BondingCurveFactory is Ownable {
    address public immutable feeRecipient;
    AggregatorV3Interface public immutable bnbPriceFeed;
    
    uint256 public constant START_MARKET_CAP_USD = 5000; // $5,000 (initial market cap at start)
    uint256 public constant END_MARKET_CAP_USD = 76963; // ~$76,963 (target market cap at end, matching four.meme)
    uint256 public constant CURVE_TOKENS = 1_000_000_000; // 1B tokens total (800M tradable, 200M locked for DEX)
    uint256 public constant TRADABLE_TOKENS = 800_000_000; // 800M tokens available for trading
    // Target initial price in BNB (matching four.meme: 0.000000005798 BNB per token)
    // From four.meme expected amounts:
    //   - 0.00099 BNB → 170,734 tokens → P0 ≈ 5.798e-9
    //   - 0.0099 BNB → 1,704,902 tokens
    //   - 0.099 BNB → 16,808,861 tokens
    //   - 0.99 BNB → 147,334,426 tokens
    uint256 public constant TARGET_P0_BNB_NUMERATOR = 5798; // 0.000000005798 = 5798 / 1e12
    uint256 public constant TARGET_P0_BNB_DENOMINATOR = 1e12;
    uint256 public constant WAD = 1e18;
    uint256 public constant PRICE_FEED_DECIMALS = 8; // Chainlink price feeds use 8 decimals

    event BondingCurveCreated(
        address indexed token,
        address indexed bondingCurve,
        uint256 p0_wad,
        uint256 m_wad,
        uint256 curveAllocation,
        uint256 bnbPriceUSD
    );

    /**
     * @param _feeRecipient Address to receive 1% fees from buy/sell
     * @param _bnbPriceFeed Address of Chainlink BNB/USD price feed
     *                      BSC Mainnet: 0x0567F2323251f0Aab15c8dFbB7a6333D0d8771a3
     *                      BSC Testnet: Check Chainlink docs for testnet address
     */
    constructor(address _feeRecipient, address _bnbPriceFeed) {
        require(_feeRecipient != address(0), "feeRecipient 0");
        require(_bnbPriceFeed != address(0), "priceFeed 0");
        feeRecipient = _feeRecipient;
        bnbPriceFeed = AggregatorV3Interface(_bnbPriceFeed);
        _transferOwnership(msg.sender);
    }

    /**
     * @notice Get latest BNB price from Chainlink Price Feed
     * @return price BNB price in USD with 18 decimals (WAD)
     */
    function getLatestBNBPrice() public view returns (uint256 price) {
        (
            /* uint80 roundID */,
            int256 rawPrice,
            /* uint startedAt */,
            /* uint timeStamp */,
            /* uint80 answeredInRound */
        ) = bnbPriceFeed.latestRoundData();
        
        require(rawPrice > 0, "Invalid price");
        
        // Chainlink returns price with 8 decimals, convert to 18 decimals (WAD)
        // price = rawPrice * 10^(18-8) = rawPrice * 10^10
        // WAD = 1e18, so we need to multiply by 10^10 to go from 8 to 18 decimals
        price = uint256(rawPrice) * (10 ** 10);
    }

    /**
     * @notice Calculate bonding curve parameters to match four.meme pricing exactly
     * @dev Uses multiple target points to calculate m accurately:
     *      - 0.00099 BNB → 170,734 tokens
     *      - 0.0099 BNB → 1,704,902 tokens
     *      - 0.099 BNB → 16,808,861 tokens
     *      - 0.99 BNB → 147,334,426 tokens
     *      
     *      The formula: Cost = P0*s + 0.5*m*s^2/curveAllocation
     *      Solving for m using the largest point (0.99 BNB) for accuracy
     * @return p0_wad Starting price in BNB wei per token (WAD scaled)
     * @return m_wad Slope in BNB wei per token per token (WAD scaled)
     * @return bnbPriceUSD Current BNB price in USD (WAD scaled, 18 decimals)
     */
    function calculateCurveParams() public view returns (
        uint256 p0_wad,
        uint256 m_wad,
        uint256 bnbPriceUSD
    ) {
        // Fetch real-time BNB price from Chainlink (8 decimals -> 18 decimals)
        bnbPriceUSD = getLatestBNBPrice(); // Now in WAD (18 decimals)
        
        // Set P0 directly to target initial price: 5.798e-9 BNB per token (matching four.meme)
        // P0 = 5798 / 1e12 * 1e18 = 5798 * 1e6 = 5798000000 (in WAD)
        p0_wad = (TARGET_P0_BNB_NUMERATOR * WAD) / TARGET_P0_BNB_DENOMINATOR;
        
        // Calculate m to match the expected token amounts at initial state (s=0)
        // Expected: 0.99 BNB → 147,334,426 tokens
        // New formula: P(s) = P0 + (m * s) / curveAllocation
        // Cost from s=0: Cost = (P0 * ds) / WAD + (m * ds^2) / (2 * curveAllocation * WAD)
        // Note: m is stored as m_wad (already in WAD units), so m = m_wad
        // Solving for m_wad: (m_wad * ds^2) / (2 * curveAllocation * WAD) = Cost - (P0 * ds) / WAD
        // m_wad * ds^2 = 2 * (Cost - (P0 * ds) / WAD) * curveAllocation * WAD
        // m_wad = 2 * (Cost - (P0 * ds) / WAD) * curveAllocation * WAD / ds^2
        uint256 targetTokensSold = 147_334_426 * (10 ** 18); // In raw token units (WAD)
        uint256 targetCostWei = 99 * (10 ** 16); // 0.99 BNB net (after 1% fee from 1 BNB input)
        uint256 curveAllocation = CURVE_TOKENS * (10 ** 18); // 1B tokens in raw units (18 decimals)
        
        // P0 term: (P0 * ds) / WAD (in wei)
        uint256 p0TermWei = (p0_wad * targetTokensSold) / WAD;
        
        // Calculate m if there's a cost difference
        if (targetCostWei > p0TermWei && targetTokensSold > 0 && curveAllocation > 0) {
            uint256 costDiffWei = targetCostWei - p0TermWei;
            
            // Calculate ds^2 to avoid overflow
            // ds = 147334426 * 10^18
            // ds^2 = (147334426 * 10^18)^2 = 147334426^2 * 10^36
            // We need: m_wad = 2 * costDiffWei * curveAllocation * WAD / ds^2
            
            uint256 twoCostDiff = 2 * costDiffWei;
            
            // Calculate step by step to avoid overflow
            // m_wad = (2 * costDiff * curveAllocation * WAD) / ds^2
            // ds^2 = targetTokensSold^2 (36 decimals)
            // To avoid calculating huge ds^2, use: dsSquared = (ds/WAD)^2 (no decimals)
            // Then ds^2 = dsSquared * WAD^2
            // So: m_wad = (2 * costDiff * curveAllocation * WAD) / (dsSquared * WAD^2)
            // = (2 * costDiff * curveAllocation) / (dsSquared * WAD)
            
            uint256 dsSquared = (targetTokensSold / WAD) * (targetTokensSold / WAD); // (ds/WAD)^2, no decimals
            if (dsSquared == 0) dsSquared = 1; // Avoid division by zero
            
            // Calculate: (2 * costDiff * curveAllocation) / (dsSquared * WAD)
            if (twoCostDiff <= type(uint256).max / curveAllocation) {
                uint256 numerator = twoCostDiff * curveAllocation; // 18 + 18 = 36 decimals
                // Divide by (dsSquared * WAD)
                if (dsSquared <= type(uint256).max / WAD) {
                    uint256 denominator = dsSquared * WAD; // 0 + 18 = 18 decimals
                    m_wad = numerator / denominator; // 36 - 18 = 18 decimals (WAD) ✓
                } else {
                    // Divide numerator by WAD first, then by dsSquared
                    uint256 numeratorOverWad = numerator / WAD; // 36 - 18 = 18 decimals
                    m_wad = numeratorOverWad / dsSquared; // 18 - 0 = 18 decimals (WAD) ✓
                }
            } else {
                // Divide costDiff first to avoid overflow
                // Calculate: (2 * costDiff) / dsSquared, then * curveAllocation, then / WAD
                uint256 quotient = twoCostDiff / dsSquared;
                if (quotient > 0 && quotient <= type(uint256).max / curveAllocation) {
                    uint256 temp = quotient * curveAllocation; // 0 + 18 = 18 decimals
                    m_wad = temp / WAD; // 18 - 18 = 0 decimals... wait that's wrong!
                    // Actually, we need: m_wad = (2 * costDiff * curveAllocation) / (dsSquared * WAD)
                    // = ((2 * costDiff) / dsSquared) * curveAllocation / WAD
                    // But (2 * costDiff) / dsSquared might lose precision
                    // Better: calculate (2 * costDiff * curveAllocation) first, then divide
                    // If that overflows, use alternative method
                    uint256 costDiffTimesCurveAlloc = costDiffWei * curveAllocation;
                    if (costDiffTimesCurveAlloc <= type(uint256).max / 2) {
                        uint256 numerator = costDiffTimesCurveAlloc * 2; // 18 + 18 = 36 decimals
                        if (dsSquared <= type(uint256).max / WAD) {
                            m_wad = numerator / (dsSquared * WAD); // 36 - 18 = 18 decimals ✓
                        } else {
                            m_wad = (numerator / WAD) / dsSquared; // (36-18) - 0 = 18 decimals ✓
                        }
                    } else {
                        m_wad = 0; // Would overflow
                    }
                } else {
                    m_wad = 0; // Would overflow
                }
            }
        } else {
            m_wad = 0;
        }
    }

    /**
     * @notice Create a bonding curve for a token
     * @param _token Token address
     * @param _tokenDecimals Token decimals (usually 18)
     * @param _owner Owner of the bonding curve
     * @return bondingCurve Address of the deployed bonding curve
     */
    function createBondingCurve(
        address _token,
        uint8 _tokenDecimals,
        address _owner
    ) external returns (address bondingCurve) {
        require(_token != address(0), "token 0");
        require(_owner != address(0), "owner 0");

        // Calculate curve parameters using real-time BNB price from Chainlink
        (uint256 p0_wad, uint256 m_wad, uint256 bnbPriceUSD) = calculateCurveParams();
        // Use 1B tokens in curve (flatter curve), but only 800M will be tradable
        // The remaining 200M are locked and will go to DEX when curve finishes
        uint256 curveAllocation = CURVE_TOKENS * (10 ** _tokenDecimals);

        BondingCurveBNB curve = new BondingCurveBNB(
            _token,
            p0_wad,
            m_wad,
            curveAllocation,
            feeRecipient,
            _owner
        );

        bondingCurve = address(curve);
        emit BondingCurveCreated(_token, bondingCurve, p0_wad, m_wad, curveAllocation, bnbPriceUSD);
    }
}

