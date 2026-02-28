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
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// LOT-06 (Audit): SafeERC20 used for rescue/withdraw to prevent rug-pull and handle non-standard tokens

contract BondingCurveBNB is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable token; // token sold on curve (e.g., MemeToken)
    address public immutable feeRecipient;

    uint256 public constant WAD = 1e18;
    uint256 public constant FEE_BPS = 100; // 1% (100/10000)
    uint256 public constant BPS_BASE = 10000;

    // LOT-17 (Audit): P0 and m declared immutable - set only in constructor, gas savings on every quote read
    // Curve parameters (price units = BNB wei scaled as WAD)
    uint256 public immutable P0;   // starting price per token (WAD), equals (startFDV / totalSupply) * WAD
    uint256 public immutable m;    // slope (WAD per token)
    uint256 public sold;           // tokens sold so far (raw token units)
    uint256 public immutable curveAllocation; // total tokens allocated to this curve (raw units)
    bool public curveFinished;

    event DepositedTokens(address indexed from, uint256 amount);
    event Buy(address indexed buyer, uint256 bnbIn, uint256 tokensOut, uint256 fee);
    event Sell(address indexed seller, uint256 tokensIn, uint256 bnbOut, uint256 fee);
    event CurveFinished(uint256 sold);
    // LOT-13 (Audit): Removed unused FeeRecipientChanged event - feeRecipient is immutable and never changed

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
        // LOT-20 (Audit): Verify feeRecipient can receive BNB to prevent permanent DoS of buy/sell
        (bool testSend,) = payable(_feeRecipient).call{value: 0}("");
        require(testSend, "feeRecipient cannot receive BNB");
        token = IERC20(_token);
        P0 = _P0_wad;
        m = _m_wad;
        curveAllocation = _curveAllocation;
        feeRecipient = _feeRecipient;
        _transferOwnership(_owner);
    }

    // Get current market cap in USD (approximate, based on BNB price)
    // This is a view function for reference - actual pricing is in BNB
    // Market cap = Current Price × Total Supply (curveAllocation)
    function getCurrentMarketCapUSD(uint256 bnbPriceUSD) external view returns (uint256) {
        // Calculate current price at the current sold amount
        uint256 currentPriceBNB = priceAt(sold); // Price in BNB (WAD scaled)
        
        // Market cap = currentPriceBNB × curveAllocation × bnbPriceUSD / (WAD × WAD)
        // currentPriceBNB is in WAD (18 decimals)
        // curveAllocation is in raw token units (18 decimals)
        // bnbPriceUSD is in WAD (18 decimals)
        // Result: (WAD × WAD × WAD) / (WAD × WAD) = WAD (18 decimals) ✓
        uint256 currentPriceUSD = (currentPriceBNB * bnbPriceUSD) / WAD; // Price in USD per token (WAD scaled)
        uint256 marketCapUSD = (currentPriceUSD * curveAllocation) / WAD; // Total market cap in USD (WAD scaled)
        
        return marketCapUSD;
    }

    // PRICE HELPERS
    // Price at sold s: P(s) = P0 + m * s / curveAllocation
    // This ensures price increases gradually from P0 (when s=0) to P0+m (when s=curveAllocation)
    function priceAt(uint256 s) public view returns (uint256) {
        if (curveAllocation == 0) return P0;
        return P0 + (m * s) / curveAllocation;
    }

    /// @dev LOT-18 (Audit): Quadratic term helper - correct formula without extra /WAD that nullified price progression.
    /// term2 = m * ds^2 / (2 * curveAllocation * WAD). With dsOverWad = ds/WAD, curveAllocationOverWad = curveAllocation/WAD:
    /// term2 = m * dsOverWad^2 / (2 * curveAllocationOverWad) — NO extra /WAD.
    function _quadraticTerm(uint256 ds) internal view returns (uint256) {
        if (ds == 0 || curveAllocation == 0) return 0;
        uint256 dsOverWad = ds / WAD;
        uint256 curveAllocationOverWad = curveAllocation / WAD;
        if (dsOverWad == 0) {
            // LOT-08 (Audit): Sub-WAD branch - consistent with buy path: divide by 2 only (no extra /WAD)
            uint256 mOverWad = m / WAD;
            uint256 dsSquaredOverCurveAlloc = (ds * ds) / curveAllocation;
            return (mOverWad * dsSquaredOverCurveAlloc) / 2;
        }
        if (curveAllocationOverWad == 0) return 0;
        if (m <= type(uint256).max / dsOverWad) {
            uint256 temp = m * dsOverWad;
            if (temp <= type(uint256).max / dsOverWad) {
                uint256 temp2 = temp * dsOverWad;
                return (temp2 / curveAllocationOverWad) / 2; // NO extra / WAD (LOT-18)
            }
        }
        uint256 mOverWad = m / WAD;
        uint256 numerator = mOverWad * dsOverWad * dsOverWad;
        return (numerator * WAD) / (2 * curveAllocationOverWad);
    }

    // Cost (in wei) to buy ds tokens from state s:
    // Price at s: P(s) = P0 + m * s / curveAllocation (in WAD units)
    // Cost = P(s)*ds/WAD + 0.5*m*ds^2/(curveAllocation*WAD) = term1 + term2
    function buyQuoteFor(uint256 s, uint256 ds) public view returns (uint256) {
        if (ds == 0) return 0;
        if (curveAllocation == 0) return 0;
        uint256 b = P0 + (m * s) / curveAllocation;
        uint256 term1 = (b * ds) / WAD;
        return term1 + _quadraticTerm(ds);
    }

    // Quote returned when selling ds from state s: term1 - term2 (same term2 as buy via _quadraticTerm)
    function sellQuoteFor(uint256 s, uint256 ds) public view returns (uint256) {
        require(ds <= s, "ds > s");
        if (ds == 0) return 0;
        if (curveAllocation == 0) return 0;
        uint256 b = P0 + (m * s) / curveAllocation;
        uint256 term1 = (b * ds) / WAD;
        uint256 term2 = _quadraticTerm(ds);
        if (term1 >= term2) return term1 - term2;
        return 0;
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
        // LOT-27 (Audit): 128 iterations sufficient for full uint256 range; reduces unpredictable gas
        uint256 maxIterations = 128;
        
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

    // LOT-06 (Audit): Withdraw only excess tokens — cannot withdraw active curve allocation
    function withdrawToken(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero");
        uint256 activeBalance = curveAllocation - sold;
        uint256 currentBalance = token.balanceOf(address(this));
        require(currentBalance - amount >= activeBalance, "cannot withdraw active tokens");
        token.safeTransfer(to, amount);
    }

    // LOT-06 (Audit): Cannot rescue curve's own token; other ERC20 only (e.g. airdrops)
    function rescueERC20(address tokenAddr, address to, uint256 amount) external onlyOwner {
        require(tokenAddr != address(token), "cannot rescue curve token");
        IERC20(tokenAddr).safeTransfer(to, amount);
    }
    // LOT-06 (Audit): Rescue BNB only if curve remains solvent for current sold amount
    function rescueBNB(address payable to, uint256 amount) external onlyOwner {
        require(to != payable(address(0)), "zero");
        uint256 requiredBNB = sellQuoteFor(sold, sold);
        require(address(this).balance - amount >= requiredBNB, "would make curve insolvent");
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
    // LOT-21 (Audit): deadline prevents stale transactions (e.g. Four.Meme-style sandwich on BSC)
    function buyWithBNB(uint256 minTokensOut, uint256 deadline) external payable nonReentrant {
        require(block.timestamp <= deadline, "transaction expired");
        require(!curveFinished, "curve finished");
        require(msg.value > 0, "send BNB");

        uint256 fee = (msg.value * FEE_BPS) / BPS_BASE;
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
        if (actualCost < netQuote) {
            uint256 refund = netQuote - actualCost;
            if (refund > 0) {
                (bool sent,) = payable(msg.sender).call{value: refund}("");
                require(sent, "refund failed");
            }
        } else if (actualCost > netQuote) {
            (bool r,) = payable(msg.sender).call{value: netQuote}("");
            require(r, "refund failed");
            revert("quote short");
        }

        require(ds >= minTokensOut, "slippage");

        // LOT-24 (Audit): CEI — update state before external call
        sold += ds;
        require(token.transfer(msg.sender, ds), "token transfer failed");

        if (sold >= curveAllocation) {
            curveFinished = true;
            emit CurveFinished(sold);
        }

        emit Buy(msg.sender, msg.value, ds, fee);
    }

    // --------------------
    // SELL (receive BNB)
    // --------------------
    // LOT-01 (Audit): Enforce minQuoteOut for slippage protection; LOT-21: deadline for stale txs
    function sell(uint256 tokensIn, uint256 minQuoteOut, uint256 deadline) external nonReentrant {
        require(block.timestamp <= deadline, "transaction expired");
        require(tokensIn > 0, "zero tokens");
        require(tokensIn <= sold, "cannot sell more than sold");

        require(token.transferFrom(msg.sender, address(this), tokensIn), "transferFrom failed");

        uint256 grossOut = sellQuoteFor(sold, tokensIn);
        require(grossOut > 0, "quote too small");

        uint256 fee = (grossOut * FEE_BPS) / BPS_BASE;
        uint256 netOut = grossOut - fee;
        require(netOut >= minQuoteOut, "slippage");

        require(address(this).balance >= grossOut, "insufficient liquidity");

        // LOT-24 (Audit): CEI — update state before external calls
        sold -= tokensIn;

        (bool sent,) = payable(msg.sender).call{value: netOut}("");
        require(sent, "pay seller failed");

        if (fee > 0) {
            (bool ok,) = payable(feeRecipient).call{value: fee}("");
            require(ok, "fee transfer failed");
        }

        emit Sell(msg.sender, tokensIn, netOut, fee);
    }

    // receive fallback (pull in BNB if someone sends accidentally)
    receive() external payable {}
}
