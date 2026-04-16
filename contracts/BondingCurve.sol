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
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

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
    uint256 public immutable P0; // starting price per token (WAD), equals (startFDV / totalSupply) * WAD
    uint256 public immutable m; // slope (WAD per token)
    uint256 public sold; // tokens sold so far (raw token units)
    uint256 public immutable curveAllocation; // total tokens allocated to this curve (raw units)
    bool public curveFinished;
    address public migrator;
    bool public isMigrated;

    modifier onlyMigrator() {
        _onlyMigrator();
        _;
    }

    function _onlyMigrator() internal view {
        require(msg.sender == migrator, "Not migrator");
    }

    // AUDIT FIX (BUG-2,3,10): Track cumulative sell fees extracted from contract to adjust solvency checks
    uint256 public totalSellFeesExtracted;

    // AUDIT FIX (BUG-8): Time-locked sweep for burned/lost tokens that lock BNB forever
    uint256 public curveFinishedAt;
    uint256 public constant SWEEP_DELAY = 180 days;

    // AUDIT FIX (CRITICAL-1): Track tokens each address bought from the curve. Only tokens purchased
    // through buyWithBNB can be sold back. This prevents the creator (who receives 20% free tokens)
    // from selling their free allocation through the curve to drain all buyer BNB.
    mapping(address => uint256) public boughtFromCurve;

    // AUDIT FIX (HIGH-5): Timelock between markCurveFinished and migrateLiquidity to prevent instant rug.
    // Owner must wait MIGRATION_DELAY after finishing before draining BNB.
    uint256 public constant MIGRATION_DELAY = 24 hours;
    // AUDIT FIX (HIGH-5): Minimum percentage of curveAllocation that must be sold before owner can finish.
    uint256 public constant MIN_SOLD_PERCENT_TO_FINISH = 50;

    event DepositedTokens(address indexed from, uint256 amount);
    event Buy(
        address indexed buyer,
        uint256 bnbIn,
        uint256 tokensOut,
        uint256 fee
    );
    event Sell(
        address indexed seller,
        uint256 tokensIn,
        uint256 bnbOut,
        uint256 fee
    );
    event CurveFinished(uint256 sold);
    event LiquidityMigrated(address indexed to, uint256 amount);
    event BNBSwept(address indexed to, uint256 amount);
    // LOT-13 (Audit): Removed unused FeeRecipientChanged event - feeRecipient is immutable and never changed

    /// @dev LOT-32 (Audit Round 2): Payable constructor. If msg.value >= 1 wei, validates feeRecipient with a 1-wei
    /// transfer (zero-value probe is insufficient — some contracts accept 0 but revert on non-zero). Refunds remainder.
    constructor(
        address _token,
        uint256 _P0_wad,
        uint256 _m_wad,
        uint256 _curveAllocation,
        address _feeRecipient,
        address _owner,
        address _migrator
    ) payable {
        require(_token != address(0), "token 0");
        require(_feeRecipient != address(0), "feeRecipient 0");
        require(_migrator != address(0), "migrator 0");

        // AUDIT FIX (BUG-17): Reject degenerate curve parameters that produce broken/free curves
        require(_P0_wad > 0, "P0 must be > 0");
        require(_m_wad > 0, "m must be > 0");
        require(_curveAllocation > 0, "curveAllocation must be > 0");

        // AUDIT FIX (BUG-22): Bonding curve math requires 18-decimal tokens; reject non-18
        require(
            IERC20Metadata(_token).decimals() == 18,
            "requires 18 decimals"
        );

        if (msg.value >= 1) {
            (bool ok, ) = payable(_feeRecipient).call{value: 1}("");
            require(ok, "feeRecipient cannot receive BNB");
            if (msg.value > 1) {
                (bool refund, ) = payable(msg.sender).call{
                    value: msg.value - 1
                }("");
                require(refund, "refund failed");
            }
        } else {
            (bool testSend, ) = payable(_feeRecipient).call{value: 0}("");
            require(testSend, "feeRecipient cannot receive BNB");
        }
        token = IERC20(_token);
        P0 = _P0_wad;
        m = _m_wad;
        curveAllocation = _curveAllocation;
        feeRecipient = _feeRecipient;
        migrator = _migrator;
        _transferOwnership(_owner);
    }

    // Get current market cap in USD (approximate, based on BNB price)
    // This is a view function for reference - actual pricing is in BNB
    // Market cap = Current Price × Total Supply (curveAllocation)
    function getCurrentMarketCapUSD(
        uint256 bnbPriceUSD
    ) external view returns (uint256) {
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

    /// @dev LOT-18 (Audit): Quadratic term helper.
    /// term2 = m * ds^2 / (2 * curveAllocation * WAD)
    /// AUDIT FIX (BUG-15,21): Replaced multi-branch integer arithmetic with Math.mulDiv for full
    /// 512-bit intermediate precision. Eliminates rounding divergence that caused solvency deficit,
    /// non-additive quotes, and path-dependent pricing across all token magnitudes including sub-WAD.
    function _quadraticTerm(uint256 ds) internal view returns (uint256) {
        if (ds == 0 || curveAllocation == 0) return 0;
        uint256 dsSquaredOverWad = Math.mulDiv(ds, ds, WAD);
        return Math.mulDiv(m, dsSquaredOverWad, 2 * curveAllocation);
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

    /// @notice Quote returned when selling ds tokens from state s.
    /// AUDIT FIX (BUG-1,4,5,6 — Root Cause): Compute base price at (s - ds) — the bottom of the
    /// sell range — instead of s (the top). This makes sellQuoteFor(s, ds) == buyQuoteFor(s - ds, ds),
    /// eliminating the rounding asymmetry that caused insolvency after every buy, sell-quote exceeding
    /// buy-quote, and the impossible buy-sell roundtrip.
    function sellQuoteFor(uint256 s, uint256 ds) public view returns (uint256) {
        require(ds <= s, "ds > s");
        if (ds == 0) return 0;
        if (curveAllocation == 0) return 0;
        uint256 b = P0 + (m * (s - ds)) / curveAllocation;
        uint256 term1 = (b * ds) / WAD;
        return term1 + _quadraticTerm(ds);
    }

    /// @notice Solve for ds given netQuote using binary search.
    /// @dev AUDIT NOTE (BUG-11): Splitting a large buy into many small buys may yield ~0.00005% more
    /// tokens due to integer rounding in the binary search. This is a known limitation; the gas cost
    /// of splitting exceeds the rounding profit. Similarly (BUG-12), splitting sells into smaller
    /// chunks compounds rounding loss. Both are inherent to discrete-step binary search over an
    /// integer integral. Math.mulDiv in _quadraticTerm minimizes but cannot eliminate this.
    function tokensForQuote(
        uint256 s,
        uint256 netQuote
    ) public view returns (uint256) {
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

        uint256 upperBound = linearEstimate < remaining
            ? linearEstimate
            : remaining;
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

    // /// owner must pre-fund the curve with tokens
    // /// LOT-31 (Audit Round 2): Use SafeERC20 for compatibility with non-standard ERC-20 (e.g. USDT that doesn't return bool)
    // function depositCurveTokens(
    //     uint256 amount
    // ) external nonReentrant onlyOwner {
    //     require(amount > 0, "amount>0");
    //     token.safeTransferFrom(msg.sender, address(this), amount);
    //     emit DepositedTokens(msg.sender, amount);
    // }

    // Fee recipient is immutable, cannot be changed

    // LOT-06 (Audit): Withdraw only excess tokens. LOT-34: Owner can withdraw above active allocation; trust assumption.
    function withdrawToken(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero");
        require(isMigrated,"bonding not migrated yet");
        uint256 activeBalance = curveAllocation - sold;
        uint256 currentBalance = token.balanceOf(address(this));
        require(
            currentBalance - amount >= activeBalance,
            "cannot withdraw active tokens"
        );
        token.safeTransfer(to, amount);
    }

    // LOT-06 (Audit): Cannot rescue curve's own token; other ERC20 only (e.g. airdrops)
    function rescueERC20(
        address tokenAddr,
        address to,
        uint256 amount
    ) external onlyOwner {
        require(tokenAddr != address(token), "cannot rescue curve token");
        IERC20(tokenAddr).safeTransfer(to, amount);
    }
    // LOT-06 (Audit): Rescue BNB only if curve remains solvent. LOT-34: Combined with markCurveFinished, owner can extract within solvency; trust assumption.
    // AUDIT FIX (BUG-14): Guard against underflow when amount > balance (was Panic(0x11), now readable error).
    // AUDIT FIX (BUG-2,3,10): Subtract totalSellFeesExtracted from required reserve — fees already left the contract.
    // AUDIT FIX (CRITICAL-3): nonReentrant prevents reentrancy via .call{value} callback.
    function rescueBNB(
        address payable to,
        uint256 amount
    ) external onlyOwner nonReentrant {
        require(to != payable(address(0)), "zero");
        require(isMigrated,"bonding not migrated yet");
        require(amount <= address(this).balance, "insufficient balance");
        uint256 grossRequired = sellQuoteFor(sold, sold);
        uint256 requiredBNB = grossRequired > totalSellFeesExtracted
            ? grossRequired - totalSellFeesExtracted
            : 0;
        require(
            address(this).balance - amount >= requiredBNB,
            "would make curve insolvent"
        );
        (bool sent, ) = to.call{value: amount}("");
        require(sent, "BNB send failed");
    }

    // LOT-34 (Audit Round 2): Centralization — owner can unilaterally halt buys. Documented admin trust assumption.
    // For stronger protection consider TimelockController (24–48h delay) or renouncing ownership after launch.
    // AUDIT FIX (BUG-8): Record curveFinishedAt for time-locked sweep of permanently stuck BNB.
    // AUDIT FIX (HIGH-5): Require minimum 50% of curveAllocation sold before owner can manually finish.
    // This prevents instant rug where owner calls markCurveFinished() + migrateLiquidity() with 0 tokens sold.
    function markCurveFinished() external onlyOwner {
        require(
            sold >= (curveAllocation * MIN_SOLD_PERCENT_TO_FINISH) / 100,
            "minimum sold threshold not met"
        );
        curveFinished = true;
        curveFinishedAt = block.timestamp;
        emit CurveFinished(sold);
    }

    // --------------------
    // BUY (payable) - BNB
    // --------------------
    // LOT-21 (Audit): deadline prevents stale transactions (e.g. Four.Meme-style sandwich on BSC)
    // AUDIT FIX (CRITICAL-2): Fee is now computed on actualCost (what the user actually pays for tokens),
    // not on msg.value. On partial fills the user was overcharged up to 3.3x. Now fee = 1% of actualCost only.
    function buyWithBNB(
        uint256 minTokensOut,
        uint256 deadline
    ) external payable nonReentrant {
        require(block.timestamp <= deadline, "transaction expired");
        require(!curveFinished, "curve finished");
        require(msg.value > 0, "send BNB");

        uint256 maxNetQuote = msg.value - ((msg.value * FEE_BPS) / BPS_BASE);

        uint256 ds = tokensForQuote(sold, maxNetQuote);
        require(ds > 0, "insufficient BNB");

        uint256 remaining = curveAllocation - sold;
        if (ds > remaining) ds = remaining;

        uint256 actualCost = buyQuoteFor(sold, ds);
        require(actualCost <= maxNetQuote, "quote short");

        // AUDIT FIX (CRITICAL-2): Compute fee on actualCost, not msg.value
        uint256 fee = (actualCost * FEE_BPS) / (BPS_BASE - FEE_BPS);
        uint256 totalCharged = actualCost + fee;

        if (totalCharged < msg.value) {
            uint256 refund = msg.value - totalCharged;
            (bool sent, ) = payable(msg.sender).call{value: refund}("");
            require(sent, "refund failed");
        }

        if (fee > 0) {
            (bool ok, ) = payable(feeRecipient).call{value: fee}("");
            require(ok, "fee transfer failed");
        }

        require(ds >= minTokensOut, "slippage");

        // LOT-24 (Audit): CEI — update state before external call
        sold += ds;
        // AUDIT FIX (CRITICAL-1): Track tokens bought per user to prevent creator rug via sell()
        boughtFromCurve[msg.sender] += ds;
        // LOT-31 (Audit Round 2): Use SafeERC20 for compatibility with non-standard ERC-20
        token.safeTransfer(msg.sender, ds);

        if (sold >= curveAllocation) {
            curveFinished = true;
            curveFinishedAt = block.timestamp; // AUDIT FIX (BUG-8)
            emit CurveFinished(sold);
        }

        emit Buy(msg.sender, msg.value, ds, fee);
    }

    // --------------------
    // SELL (receive BNB)
    // --------------------
    // LOT-01 (Audit): Enforce minQuoteOut for slippage protection; LOT-21: deadline for stale txs
    // LOT-30 (Audit Round 2): Strict CEI — update sold BEFORE any external call (including transferFrom).
    // LOT-31 (Audit Round 2): Use safeTransferFrom for non-standard ERC-20 compatibility.
    // AUDIT FIX (BUG-13,16): Block sells after curveFinished to protect BNB reserved for DEX migration.
    // AUDIT FIX (CRITICAL-1): Only tokens purchased through buyWithBNB can be sold back. This prevents
    // the creator from selling their free 20% allocation to drain all buyer BNB.
    function sell(
        uint256 tokensIn,
        uint256 minQuoteOut,
        uint256 deadline
    ) external nonReentrant {
        require(block.timestamp <= deadline, "transaction expired");
        require(!curveFinished, "curve finished"); // AUDIT FIX (BUG-13,16)
        require(tokensIn > 0, "zero tokens");
        require(tokensIn <= sold, "cannot sell more than sold");
        require(
            tokensIn <= boughtFromCurve[msg.sender],
            "can only sell tokens bought from curve"
        );

        uint256 grossOut = sellQuoteFor(sold, tokensIn);
        require(grossOut > 0, "quote too small");

        uint256 fee = (grossOut * FEE_BPS) / BPS_BASE;
        uint256 netOut = grossOut - fee;
        require(netOut >= minQuoteOut, "slippage");

        require(address(this).balance >= grossOut, "insufficient liquidity");

        // CEI: update ALL state before ANY external calls (LOT-30)
        sold -= tokensIn;
        boughtFromCurve[msg.sender] -= tokensIn;
        // AUDIT FIX (BUG-2,3,10): Track cumulative sell fees so rescueBNB solvency check
        // accounts for BNB that already left the contract as fees.
        totalSellFeesExtracted += fee;

        token.safeTransferFrom(msg.sender, address(this), tokensIn);

        (bool sent, ) = payable(msg.sender).call{value: netOut}("");
        require(sent, "pay seller failed");

        if (fee > 0) {
            (bool ok, ) = payable(feeRecipient).call{value: fee}("");
            require(ok, "fee transfer failed");
        }

        emit Sell(msg.sender, tokensIn, netOut, fee);
    }

    // --- DEX Migration & Sweep ---

    /// @notice AUDIT FIX (BUG-9): Migrate BNB to DEX after curve finishes.
    /// AUDIT FIX (HIGH-5): 24-hour timelock after curveFinished before migration is allowed.
    /// This gives users time to react and prevents instant owner rug (markCurveFinished + migrateLiquidity).
    /// AUDIT FIX (CRITICAL-3): nonReentrant prevents reentrancy via .call{value} callback.
    function migrateLiquidity() external onlyMigrator nonReentrant {
        require(curveFinished, "not finished");
        require(!isMigrated, "already migrated");
        require(curveFinishedAt > 0, "finishedAt not set");
        require(
            block.timestamp >= curveFinishedAt + MIGRATION_DELAY,
            "migration delay not met"
        );
        require(migrator != payable(address(0)), "zero");
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        require(tokenBalance > 0, "No tokens");
        uint256 balance = address(this).balance;
        require(balance > 0, "no BNB");
        (bool ok, ) = migrator.call{value: balance}("");
        require(ok, "transfer failed");
        // 4. Transfer tokens
        IERC20(token).transfer(migrator, tokenBalance);
        isMigrated = true;
        emit LiquidityMigrated(migrator, balance);
    }

    /// @notice AUDIT FIX (BUG-8): Time-locked sweep for BNB permanently stuck due to burned/lost tokens.
    /// Only available 180 days after curveFinished — gives token holders ample time to sell on DEX.
    /// AUDIT FIX (CRITICAL-3): nonReentrant prevents reentrancy via .call{value} callback.
    function sweepRemainingBNB(
        address payable to
    ) external onlyOwner nonReentrant {
        require(curveFinished, "not finished");
        require(curveFinishedAt > 0, "finishedAt not set");
        require(block.timestamp >= curveFinishedAt + SWEEP_DELAY, "too early");
        require(to != payable(address(0)), "zero");
        uint256 balance = address(this).balance;
        (bool ok, ) = to.call{value: balance}("");
        require(ok, "transfer failed");
        emit BNBSwept(to, balance);
    }

    // receive fallback (pull in BNB if someone sends accidentally)
    receive() external payable {}
}
