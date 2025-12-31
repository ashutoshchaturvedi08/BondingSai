// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/*
 BondingCurveBNB.sol
 - Linear bonding curve: P(s) = P0 + m * s/WAD  (price in BNB wei per token)
 - Buyers send BNB (payable). Contract takes 1% fee (sent to feeRecipient), uses net BNB to compute tokens out.
 - Sellers approve token -> sell(tokensIn) -> contract pays BNB net of 1% fee (fee forwarded).
 - Owner must deposit `curveAllocation` tokens to this contract before public buys.
 - Uses WAD (1e18) fixed point for price precision. token units are raw token units (with token decimals).
 - Curve starts at $5,000 market cap and ends at $50,000 market cap when all tokens are sold.
*/

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract BondingCurveBNB is Ownable, ReentrancyGuard {
    IERC20 public immutable token; // token sold on curve (e.g., MemeToken)
    address public immutable feeRecipient;

    uint256 public constant WAD = 1e18;
    uint256 public constant FEE_BPS = 100; // 1% (100/10000)
    uint256 public constant BPS_BASE = 10000;

    // Curve parameters (price units = BNB wei scaled as WAD)
    uint256 public P0;              // starting price per token (WAD), equals (startFDV / totalSupply) * WAD
    uint256 public m;               // slope (WAD per token)
    uint256 public sold;            // tokens sold so far (raw token units)
    uint256 public immutable curveAllocation; // total tokens allocated to this curve (raw units)
    bool public curveFinished;

    event DepositedTokens(address indexed from, uint256 amount);
    event Buy(address indexed buyer, uint256 bnbIn, uint256 tokensOut, uint256 fee);
    event Sell(address indexed seller, uint256 tokensIn, uint256 bnbOut, uint256 fee);
    event CurveFinished(uint256 sold);
    event FeeRecipientChanged(address indexed newRecipient);

    constructor(
        address _token,
        uint256 _P0_wad,
        uint256 _m_wad,
        uint256 _curveAllocation,
        address _feeRecipient,
        address _owner
    ) {
        require(_token != address(0), "token 0");
        require(_feeRecipient != address(0), "feeRecipient 0");
        token = IERC20(_token);
        P0 = _P0_wad;
        m = _m_wad;
        curveAllocation = _curveAllocation;
        feeRecipient = _feeRecipient;
        _transferOwnership(_owner);
    }

    // Get current market cap in USD (approximate, based on BNB price)
    // This is a view function for reference - actual pricing is in BNB
    // Returns $5,000 when sold == 0, then calculates based on integral of price function
    function getCurrentMarketCapUSD(uint256 bnbPriceUSD) external view returns (uint256) {
        if (sold == 0) {
            // Initial market cap is exactly $5,000
            return 5000 * WAD; // $5,000 in WAD (18 decimals)
        }
        
        // Calculate market cap based on integral of price function
        // Market cap = integral from 0 to sold of P(x) dx * bnbPriceUSD / WAD
        // P(x) = P0 + m*x/curveAllocation
        // Integral = P0*sold + (m*sold^2)/(2*curveAllocation)
        // Then multiply by bnbPriceUSD/WAD to get USD
        
        uint256 integralTerm1 = (P0 * sold) / WAD; // P0*sold in wei
        uint256 integralTerm2;
        if (curveAllocation > 0) {
            // (m * sold^2) / (2 * curveAllocation * WAD)
            uint256 soldOverWad = sold / WAD;
            if (soldOverWad > 0) {
                uint256 mOverWad = m / WAD;
                uint256 soldSquaredOverCurveAlloc = (sold * sold) / curveAllocation;
                integralTerm2 = (mOverWad * soldSquaredOverCurveAlloc) / (2 * WAD);
            }
        }
        
        uint256 totalCostBNB = integralTerm1 + integralTerm2; // Total BNB spent (in wei)
        // Convert to USD: totalCostBNB * bnbPriceUSD / WAD
        uint256 marketCapUSD = (totalCostBNB * bnbPriceUSD) / WAD;
        
        // Add remaining tokens at current price
        uint256 remainingTokens = token.balanceOf(address(this));
        uint256 currentPriceBNB = priceAt(sold);
        uint256 currentPriceUSD = (currentPriceBNB * bnbPriceUSD) / WAD;
        uint256 remainingValueUSD = (currentPriceUSD * remainingTokens) / WAD;
        
        return marketCapUSD + remainingValueUSD;
    }

    // PRICE HELPERS
    // Price at sold s: P(s) = P0 + m * s / curveAllocation
    // This ensures price increases gradually from P0 (when s=0) to P0+m (when s=curveAllocation)
    function priceAt(uint256 s) public view returns (uint256) {
        if (curveAllocation == 0) return P0;
        return P0 + (m * s) / curveAllocation;
    }

    // Cost (in wei) to buy ds tokens from state s:
    // Price at s: P(s) = P0 + m * s / WAD (in WAD units)
    // Cost = integral from s to s+ds of P(x) dx
    // Cost = P(s) * ds / WAD + 0.5 * m * ds^2 / WAD^2
    // Since P(s) is in WAD, we need to divide by WAD to get wei per token
    // Since m is in WAD and ds is in raw token units (18 decimals), ds^2 has 36 decimals
    // So we need to divide by WAD^2 to get the correct wei result
    function buyQuoteFor(uint256 s, uint256 ds) public view returns (uint256) {
        if (ds == 0) return 0;
        if (curveAllocation == 0) return 0;
        uint256 b = P0 + (m * s) / curveAllocation; // b is in WAD (price per token scaled by WAD)
        // term1 = (b / WAD) * ds = price per token in wei * tokens = wei
        uint256 term1 = (b * ds) / WAD;
        // term2 = 0.5 * m * ds^2 / WAD^2
        // m is in WAD (18 decimals), ds is in raw token units (18 decimals)
        // ds^2 has 36 decimals, so we need to divide by WAD^2 to get wei
        // Formula: term2 = (m * ds^2) / (2 * WAD^2)
        // To avoid overflow: term2 = (m * (ds/WAD) * (ds/WAD)) / (2 * curveAllocationOverWad)
        uint256 dsOverWad = ds / WAD;
        uint256 curveAllocationOverWad = curveAllocation / WAD;
        uint256 term2;
        
        // Handle case where ds < WAD (dsOverWad == 0)
        if (dsOverWad == 0) {
            // For very small ds, term2 is negligible, use direct calculation
            // term2 = (m * ds^2) / (2 * curveAllocation * WAD)
            // To avoid overflow, calculate: (m / WAD) * (ds^2 / curveAllocation) / 2
            uint256 mOverWad = m / WAD;
            uint256 dsSquaredOverCurveAlloc = (ds * ds) / curveAllocation;
            term2 = (mOverWad * dsSquaredOverCurveAlloc) / 2;
        } else {
            // term2 = (m * ds^2) / (2 * curveAllocation * WAD)
            // Using dsOverWad = ds / WAD (no decimals) and curveAllocationOverWad = curveAllocation / WAD
            // term2 = (m * dsOverWad * dsOverWad) / (2 * curveAllocationOverWad * WAD)
            if (m <= type(uint256).max / dsOverWad) {
                uint256 temp = m * dsOverWad;
                if (temp <= type(uint256).max / dsOverWad) {
                    uint256 temp2 = temp * dsOverWad;
                    // temp2 = m * dsOverWad * dsOverWad (in WAD units, 18 decimals)
                    // We need to divide by (2 * curveAllocationOverWad * WAD) to get wei
                    // term2 = temp2 / (2 * curveAllocationOverWad * WAD)
                    // = (temp2 / curveAllocationOverWad) / (2 * WAD)
                    if (curveAllocationOverWad > 0) {
                        if (temp2 / curveAllocationOverWad <= type(uint256).max / (2 * WAD)) {
                            term2 = (temp2 / curveAllocationOverWad) / (2 * WAD);
                        } else {
                            // Alternative: divide by 2 first
                            term2 = (temp2 / 2) / (curveAllocationOverWad * WAD);
                        }
                    } else {
                        term2 = 0;
                    }
                } else {
                    // Divide m first
                    // mOverWad has 0 decimals, dsOverWad has 0 decimals, curveAllocationOverWad has 0 decimals
                    // mOverWad * dsOverWad * dsOverWad has 0 decimals
                    // We need to divide by (2 * curveAllocationOverWad * WAD) to get wei
                    uint256 mOverWad = m / WAD;
                    if (curveAllocationOverWad > 0) {
                        term2 = (mOverWad * dsOverWad * dsOverWad) / (2 * curveAllocationOverWad * WAD);
                    } else {
                        term2 = 0;
                    }
                }
            } else {
                // Divide m first to avoid overflow
                // mOverWad has 0 decimals, dsOverWad has 0 decimals, curveAllocationOverWad has 0 decimals
                // mOverWad * dsOverWad * dsOverWad has 0 decimals
                // We need to divide by (2 * curveAllocationOverWad * WAD) to get wei
                uint256 mOverWad = m / WAD;
                if (curveAllocationOverWad > 0) {
                    term2 = (mOverWad * dsOverWad * dsOverWad) / (2 * curveAllocationOverWad * WAD);
                } else {
                    term2 = 0;
                }
            }
        }
        return term1 + term2;
    }

    // Quote returned when selling ds from state s:
    // quoteOut = (P0 + m*s/curveAllocation) * ds / WAD - 0.5 * m * ds^2 / (curveAllocation * WAD)
    function sellQuoteFor(uint256 s, uint256 ds) public view returns (uint256) {
        require(ds <= s, "ds > s");
        if (ds == 0) return 0;
        if (curveAllocation == 0) return 0;
        uint256 b = P0 + (m * s) / curveAllocation;
        uint256 term1 = (b * ds) / WAD;
        // term2 needs curveAllocation * WAD in denominator, same as buyQuoteFor
        // Use same overflow protection as buyQuoteFor
        uint256 dsOverWad = ds / WAD;
        uint256 curveAllocationOverWad = curveAllocation / WAD;
        uint256 term2;
        
        // Handle case where ds < WAD (dsOverWad == 0)
        if (dsOverWad == 0) {
            // For very small ds, term2 is negligible, use direct calculation
            // term2 = (m * ds^2) / (2 * curveAllocation * WAD)
            uint256 mOverWad = m / WAD;
            uint256 dsSquaredOverCurveAlloc = (ds * ds) / curveAllocation;
            term2 = (mOverWad * dsSquaredOverCurveAlloc) / (2 * WAD);
        } else {
            // term2 = (m * ds^2) / (2 * curveAllocation * WAD) - same as buyQuoteFor
            if (m <= type(uint256).max / dsOverWad) {
                uint256 temp = m * dsOverWad;
                if (temp <= type(uint256).max / dsOverWad) {
                    uint256 temp2 = temp * dsOverWad;
                    // temp2 = m * dsOverWad * dsOverWad (in WAD units, 18 decimals)
                    // We need to divide by (2 * curveAllocationOverWad * WAD) to get wei
                    // term2 = temp2 / (2 * curveAllocationOverWad * WAD)
                    if (curveAllocationOverWad > 0) {
                        if (temp2 / curveAllocationOverWad <= type(uint256).max / (2 * WAD)) {
                            term2 = (temp2 / curveAllocationOverWad) / (2 * WAD);
                        } else {
                            // Alternative: divide by 2 first
                            term2 = (temp2 / 2) / (curveAllocationOverWad * WAD);
                        }
                    } else {
                        term2 = 0;
                    }
                } else {
                    // Divide m first
                    // mOverWad has 0 decimals, dsOverWad has 0 decimals, curveAllocationOverWad has 0 decimals
                    // mOverWad * dsOverWad * dsOverWad has 0 decimals
                    // We need to divide by (2 * curveAllocationOverWad * WAD) to get wei
                    uint256 mOverWad = m / WAD;
                    if (curveAllocationOverWad > 0) {
                        term2 = (mOverWad * dsOverWad * dsOverWad) / (2 * curveAllocationOverWad * WAD);
                    } else {
                        term2 = 0;
                    }
                }
            } else {
                // Divide m first to avoid overflow
                // mOverWad has 0 decimals, dsOverWad has 0 decimals, curveAllocationOverWad has 0 decimals
                // mOverWad * dsOverWad * dsOverWad has 0 decimals
                // We need to divide by (2 * curveAllocationOverWad * WAD) to get wei
                uint256 mOverWad = m / WAD;
                if (curveAllocationOverWad > 0) {
                    term2 = (mOverWad * dsOverWad * dsOverWad) / (2 * curveAllocationOverWad * WAD);
                } else {
                    term2 = 0;
                }
            }
        }
        
        // Ensure no underflow - term1 should always be >= term2 for valid curve
        // But due to rounding with very small amounts, we need to handle it
        if (term1 >= term2) {
            return term1 - term2;
        } else {
            // For very small amounts, rounding might cause term2 > term1
            // Return 0 or a minimal value to prevent underflow
            return 0;
        }
    }

    // Solve for ds given netQuote using binary search
    function tokensForQuote(uint256 s, uint256 netQuote) public view returns (uint256) {
        if (netQuote == 0) return 0;
        uint256 remaining = curveAllocation - s;
        if (remaining == 0) return 0;
        
        // Calculate upper bound using linear estimate
        uint256 currentPrice = priceAt(s);
        if (currentPrice == 0) return 0;
        
        // Linear estimate: tokens ≈ (netQuote * WAD) / currentPrice
        // currentPrice is in WAD (price per token scaled by WAD)
        // netQuote is in wei (BNB wei)
        // We need: tokens = netQuote / (currentPrice / WAD) = (netQuote * WAD) / currentPrice
        uint256 linearEstimate;
        if (netQuote <= type(uint256).max / WAD) {
            linearEstimate = (netQuote * WAD) / currentPrice;
        } else {
            // If multiplication would overflow, use alternative calculation
            // currentPrice / WAD gives price in wei per token
            uint256 priceInWei = currentPrice / WAD;
            if (priceInWei == 0) return 0; // Price too small
            linearEstimate = netQuote / priceInWei;
        }
        
        uint256 upperBound = linearEstimate < remaining ? linearEstimate : remaining;
        if (upperBound == 0) return 0;
        
        // Binary search: find maximum tokens that can be bought
        if (upperBound == 0) return 0;
        
        uint256 low = 1;
        uint256 high = upperBound;
        uint256 answer = 0;
        uint256 maxIterations = 256;
        
        // Standard binary search to find the maximum tokens we can buy
        while (low <= high && maxIterations > 0) {
            maxIterations--;
            uint256 mid = (low + high) / 2;
            
            if (mid == 0) break;
            
            uint256 cost = buyQuoteFor(s, mid);
            
            if (cost <= netQuote) {
                answer = mid;
                if (low == high) break;
                if (mid == high) break; // Avoid infinite loop
                low = mid + 1;
            } else {
                if (mid <= 1) break;
                high = mid - 1;
            }
        }
        
        // Validate the answer
        if (answer > 0) {
            uint256 answerCost = buyQuoteFor(s, answer);
            // If cost is 0 (rounded), the amount is too small - return 0
            if (answerCost == 0) {
                return 0;
            }
            // Ensure answer is actually affordable
            if (answerCost > netQuote) {
                // Answer is too expensive, try one less
                if (answer > 1) {
                    answer--;
                    answerCost = buyQuoteFor(s, answer);
                    if (answerCost == 0 || answerCost > netQuote) {
                        return 0;
                    }
                } else {
                    return 0;
                }
            }
            return answer;
        }
        
        // Binary search didn't find anything - this shouldn't happen if linear estimate is correct
        // But try one more time with a smaller upper bound
        // Check if we can buy at least 1 wei
        uint256 costFor1 = buyQuoteFor(s, 1);
        if (costFor1 > 0 && costFor1 <= netQuote) {
            // We can buy at least 1 wei, so do a more careful binary search
            // Start from a minimum that we know works
            uint256 minTokens = 1;
            uint256 maxTokens = upperBound;
            
            // Find the maximum by checking powers of 2
            uint256 testAmount = minTokens;
            while (testAmount <= maxTokens) {
                uint256 testCost = buyQuoteFor(s, testAmount);
                if (testCost > 0 && testCost <= netQuote) {
                    answer = testAmount;
                    testAmount = testAmount * 2;
                    if (testAmount == 0) break; // Overflow
                } else {
                    break;
                }
            }
            
            // Now binary search between answer and answer*2 (or maxTokens)
            if (answer > 0) {
                low = answer;
                high = (answer * 2 < maxTokens) ? answer * 2 : maxTokens;
                
                for (uint256 i = 0; i < 100 && low <= high; i++) {
                    uint256 mid = (low + high) / 2;
                    uint256 cost = buyQuoteFor(s, mid);
                    
                    if (cost > 0 && cost <= netQuote) {
                        answer = mid;
                        if (low == high) break;
                        low = mid + 1;
                    } else {
                        if (mid <= answer) break;
                        high = mid - 1;
                    }
                }
            }
        }
        
        return answer;
    }

    // --- Admin / deposits ---

    /// owner must pre-fund the curve with tokens
    function depositCurveTokens(uint256 amount) external nonReentrant onlyOwner {
        require(amount > 0, "amount>0");
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit DepositedTokens(msg.sender, amount);
    }

    // Fee recipient is immutable, cannot be changed

    // Withdraw tokens (unused) - owner only
    function withdrawToken(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero");
        require(token.transfer(to, amount), "transfer failed");
    }

    // Emergency rescue for tokens/BNB by owner
    function rescueERC20(address tokenAddr, address to, uint256 amount) external onlyOwner {
        require(IERC20(tokenAddr).transfer(to, amount), "transfer failed");
    }
    function rescueBNB(address payable to, uint256 amount) external onlyOwner {
        require(to != payable(address(0)), "zero");
        (bool sent,) = to.call{value: amount}("");
        require(sent, "BNB send failed");
    }

    // Optionally mark finished
    function markCurveFinished() external onlyOwner {
        curveFinished = true;
        emit CurveFinished(sold);
    }

    // --------------------
    // BUY (payable) - BNB
    // --------------------
    // Buyer sends BNB (msg.value). Contract takes 1% fee to feeRecipient, then uses net BNB to compute tokens to send.
    function buyWithBNB(uint256 minTokensOut) external payable nonReentrant {
        require(!curveFinished, "curve finished");
        require(msg.value > 0, "send BNB");

        uint256 fee = (msg.value * FEE_BPS) / BPS_BASE; // fee in wei
        if (fee > 0) {
            (bool ok,) = payable(feeRecipient).call{value: fee}("");
            require(ok, "fee transfer failed");
        }
        uint256 netQuote = msg.value - fee;

        uint256 ds = tokensForQuote(sold, netQuote);
        require(ds > 0, "insufficient BNB");

        uint256 remaining = curveAllocation - sold;
        if (ds > remaining) ds = remaining;

        uint256 actualCost = buyQuoteFor(sold, ds);
        // refund netQuote - actualCost if any
        if (actualCost < netQuote) {
            uint256 refund = netQuote - actualCost;
            if (refund > 0) {
                (bool sent,) = payable(msg.sender).call{value: refund}("");
                require(sent, "refund failed");
            }
        } else if (actualCost > netQuote) {
            // shouldn't happen normally, but refund netQuote and revert
            (bool r,) = payable(msg.sender).call{value: netQuote}("");
            require(r, "refund failed");
            revert("quote short");
        }

        require(ds >= minTokensOut, "slippage");

        require(token.transfer(msg.sender, ds), "token transfer failed");
        sold += ds;

        if (sold >= curveAllocation) {
            curveFinished = true;
            emit CurveFinished(sold);
        }

        emit Buy(msg.sender, msg.value, ds, fee);
    }

    // --------------------
    // SELL (receive BNB)
    // --------------------
    // Seller approves the contract for tokensIn, then calls sell(tokensIn, minQuoteOut)
    function sell(uint256 tokensIn, uint256 /* minQuoteOut */) external nonReentrant {
        require(tokensIn > 0, "zero tokens");
        require(tokensIn <= sold, "cannot sell more than sold");

        // pull tokens
        require(token.transferFrom(msg.sender, address(this), tokensIn), "transferFrom failed");

        uint256 grossOut = sellQuoteFor(sold, tokensIn);
        require(grossOut > 0, "quote too small"); // Prevent selling when quote is 0 (due to rounding)
        
        uint256 fee = (grossOut * FEE_BPS) / BPS_BASE;
        uint256 netOut = grossOut - fee;

        // Need enough BNB to pay both netOut (to seller) and fee (to feeRecipient)
        require(address(this).balance >= grossOut, "insufficient liquidity");

        // send net BNB to seller
        (bool sent,) = payable(msg.sender).call{value: netOut}("");
        require(sent, "pay seller failed");

        // forward fee to feeRecipient
        if (fee > 0) {
            (bool ok,) = payable(feeRecipient).call{value: fee}("");
            require(ok, "fee transfer failed");
        }

        sold -= tokensIn;
        emit Sell(msg.sender, tokensIn, netOut, fee);
    }

    // receive fallback (pull in BNB if someone sends accidentally)
    receive() external payable {}
}
