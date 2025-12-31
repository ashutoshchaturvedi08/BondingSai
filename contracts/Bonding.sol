// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
 
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
 
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
 
contract Bonding is Ownable, ReentrancyGuard {
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
 
    // PRICE HELPERS
    // Price at sold s: P(s) = P0 + m * s / WAD
    function priceAt(uint256 s) public view returns (uint256) {
        return P0 + (m * s) / WAD;
    }
 
    // Cost (in wei) to buy ds tokens from state s:
    // Cost = integral from s to s+ds of P(x) dx = P0*ds + (m/(2*WAD))*ds^2 + (m/WAD)*s*ds
    // Where P(x) = P0 + m*x/WAD
    function buyQuoteFor(uint256 s, uint256 ds) public view returns (uint256) {
        if (ds == 0) return 0;
       
        // term1 = P0 * ds
        uint256 term1 = P0 * ds;
       
        // term2 = (m * s * ds) / WAD
        uint256 term2 = (m * s * ds) / WAD;
       
        // term3 = (m * ds * ds) / (2 * WAD)
        uint256 term3 = (m * ds * ds) / (2 * WAD);
       
        // Total cost in wei = (term1 + term2 + term3) / WAD
        // Because P0, m are in WAD (price per token * 1e18)
        return (term1 + term2 + term3) / WAD;
    }
 
    // Quote returned when selling ds from state s:
    // Revenue = integral from s-ds to s of P(x) dx = P0*ds - (m/(2*WAD))*ds^2 + (m/WAD)*s*ds
    function sellQuoteFor(uint256 s, uint256 ds) public view returns (uint256) {
        require(s >= ds, "cannot sell more than exists");
        if (ds == 0) return 0;
       
        // term1 = P0 * ds
        uint256 term1 = P0 * ds;
       
        // term2 = (m * s * ds) / WAD
        uint256 term2 = (m * s * ds) / WAD;
       
        // term3 = (m * ds * ds) / (2 * WAD)
        uint256 term3 = (m * ds * ds) / (2 * WAD);
       
        // Total revenue in wei = (term1 + term2 - term3) / WAD
        // Note: term3 is subtracted here (unlike in buyQuoteFor where it's added)
        return (term1 + term2 - term3) / WAD;
    }
 
    // Solve for ds given netQuote using quadratic formula
    // From the buyQuoteFor formula:
    // netQuote = (P0*ds + (m*s*ds)/WAD + (m*ds*ds)/(2*WAD)) / WAD
    // Multiply both sides by WAD: netQuote*WAD = P0*ds + (m*s*ds)/WAD + (m*ds*ds)/(2*WAD)
    // Let k = netQuote * WAD
    // Then: (m/(2*WAD))*ds^2 + (P0 + (m*s)/WAD)*ds - k = 0
    // This is a quadratic equation: a*ds^2 + b*ds - c = 0
    function tokensForQuote(uint256 s, uint256 netQuote) public view returns (uint256) {
        if (netQuote == 0) return 0;
       
        // Convert netQuote to same precision as P0 (WAD)
        uint256 k = netQuote * WAD;
       
        // Coefficients for quadratic formula
        // a = m / (2 * WAD)
        uint256 a = m / (2 * WAD);
       
        // b = P0 + (m * s) / WAD
        uint256 b = P0 + (m * s) / WAD;
       
        // Solve quadratic: ds = (-b + sqrt(b^2 + 4*a*k)) / (2*a)
        // Since all terms are positive, we use positive sqrt
       
        // Calculate discriminant: D = b*b + 4*a*k
        // Need to handle large numbers carefully
        uint256 b_squared = (b * b) / WAD; // Divide by WAD to keep scale
       
        uint256 four_a_k = (4 * a * k) / WAD; // Divide by WAD to keep scale
       
        uint256 D = b_squared + four_a_k;
       
        // Calculate sqrt(D) using Babylonian method (Newton's method for square root)
        uint256 sqrtD = sqrt(D * WAD); // Multiply by WAD before sqrt, then divide after
       
        // Calculate numerator: -b + sqrtD
        // Note: sqrtD is in WAD precision now, b is in WAD precision
        uint256 numerator;
        if (sqrtD > b) {
            numerator = sqrtD - b;
        } else {
            // This should rarely happen, but return 0 if discriminant is too small
            return 0;
        }
       
        // Calculate denominator: 2*a
        uint256 denominator = 2 * a;
       
        if (denominator == 0) {
            return 0;
        }
       
        // ds = numerator / denominator
        return (numerator * WAD) / denominator;
    }
 
    // Square root function using Babylonian method
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
       
        // Start with a reasonable estimate
        y = x;
        uint256 z = (y + x / y) / 2;
       
        // Iterate until convergence
        while (z < y) {
            y = z;
            z = (y + x / y) / 2;
        }
        return y;
    }
 
    // Alternative: Simple binary search for tokensForQuote (more stable for small amounts)
    function tokensForQuoteBinary(uint256 s, uint256 netQuote) public view returns (uint256) {
        if (netQuote == 0) return 0;
       
        uint256 remaining = curveAllocation - s;
        if (remaining == 0) return 0;
       
        // Use binary search
        uint256 low = 0;
        uint256 high = remaining;
        uint256 best = 0;
       
        // Cap iterations to prevent excessive gas
        for (uint256 i = 0; i < 128; i++) {
            if (low > high) break;
           
            uint256 mid = (low + high) / 2;
            uint256 cost = buyQuoteFor(s, mid);
           
            if (cost <= netQuote) {
                best = mid;
                low = mid + 1;
            } else {
                if (mid == 0) break;
                high = mid - 1;
            }
        }
       
        return best;
    }
 
    // --- Admin / deposits ---
 
    /// owner must pre-fund the curve with tokens
    function depositCurveTokens(uint256 amount) external nonReentrant onlyOwner {
        require(amount > 0, "amount>0");
        require(token.transferFrom(msg.sender, address(this), amount), "transfer failed");
        emit DepositedTokens(msg.sender, amount);
    }
 
    // Buy function using binary search for better stability
    function buyWithBNB(uint256 minTokensOut) external payable nonReentrant {
        require(!curveFinished, "curve finished");
        require(msg.value > 0, "send BNB");
 
        uint256 fee = (msg.value * FEE_BPS) / BPS_BASE;
        if (fee > 0) {
            (bool ok,) = payable(feeRecipient).call{value: fee}("");
            require(ok, "fee transfer failed");
        }
        uint256 netQuote = msg.value - fee;
 
        // Use binary search for better stability
        uint256 ds = tokensForQuoteBinary(sold, netQuote);
        require(ds > 0, "insufficient BNB");
 
        uint256 actualCost = buyQuoteFor(sold, ds);
        require(actualCost <= netQuote, "quote mismatch");
       
        // Refund any excess
        if (actualCost < netQuote) {
            uint256 refund = netQuote - actualCost;
            (bool sent,) = payable(msg.sender).call{value: refund}("");
            require(sent, "refund failed");
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
 
    // Sell function
    function sell(uint256 tokensIn, uint256 minQuoteOut) external nonReentrant {
        require(tokensIn > 0, "zero tokens");
        require(tokensIn <= sold, "cannot sell more than sold");
 
        // pull tokens
        require(token.transferFrom(msg.sender, address(this), tokensIn), "transferFrom failed");
 
        uint256 grossOut = sellQuoteFor(sold, tokensIn);
        require(grossOut >= minQuoteOut, "slippage");
       
        uint256 fee = (grossOut * FEE_BPS) / BPS_BASE;
        uint256 netOut = grossOut - fee;
 
        require(address(this).balance >= netOut, "insufficient liquidity");
 
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
 
    // View functions for frontend
    function getBuyQuote(uint256 bnbAmount) external view returns (uint256 tokensOut, uint256 costAfterFee) {
        uint256 fee = (bnbAmount * FEE_BPS) / BPS_BASE;
        uint256 netQuote = bnbAmount - fee;
        tokensOut = tokensForQuoteBinary(sold, netQuote);
        costAfterFee = buyQuoteFor(sold, tokensOut);
    }
 
    function getSellQuote(uint256 tokensIn) external view returns (uint256 bnbOut, uint256 bnbAfterFee) {
        require(tokensIn <= sold, "cannot sell more than sold");
        uint256 grossOut = sellQuoteFor(sold, tokensIn);
        uint256 fee = (grossOut * FEE_BPS) / BPS_BASE;
        bnbOut = grossOut;
        bnbAfterFee = grossOut - fee;
    }
 
    // Helper to check curve status
    function getCurveInfo() external view returns (
        uint256 currentPrice,
        uint256 tokensSold,
        uint256 tokensRemaining,
        bool finished
    ) {
        currentPrice = priceAt(sold);
        tokensSold = sold;
        tokensRemaining = curveAllocation - sold;
        finished = curveFinished;
    }
 
    receive() external payable {}
}