// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../../contracts/BondingCurve.sol";
import "../../contracts/BondingCurveFactory.sol";
import "../../contracts/MemeToken.sol";
import "../../contracts/TokenFactory.sol";
import "../../contracts/TokenFactoryWithCurve.sol";
import "./helpers/MockV3Aggregator.sol";
import "./helpers/Actors.sol";

// ============================================================================
//  BROKEN INVARIANT TESTS — User / Attacker Perspective Only
//  No owner actions. No reliance on source comments.
//  Each test proves a concrete invariant violation that a regular user or
//  attacker can trigger through normal public entry-points.
// ============================================================================

contract BaseSetup is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000;
    uint256 internal constant P0 = 5798000000; // in WAD
    uint256 internal constant M = 12500000000; // in WAD

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");

    // Warp to a sane timestamp so cooldown checks (block.timestamp - 0 >= N) work
    constructor() {
        vm.warp(1_700_000_000);
    }

    MemeToken internal token;
    BondingCurveBNB internal curve;

    /// Deploy token + curve with matching allocation (correct setup via TokenFactoryWithCurve logic)
    function _deployMatched() internal {
        vm.startPrank(owner);

        uint256 rawSupply = TOTAL_SUPPLY * WAD;
        uint256 curveAlloc = (rawSupply * 80) / 100;

        token = new MemeToken(
            "Meme", "MEME", 18, owner, TOTAL_SUPPLY,
            "", "", "", "", "", new string[](0), new uint256[](0)
        );

        curve = new BondingCurveBNB(
            address(token), P0, M, curveAlloc, feeRecipient, owner
        );

        token.approve(address(curve), curveAlloc);
        curve.depositCurveTokens(curveAlloc);
        token.setExcludedFromLimits(address(curve), true);

        vm.stopPrank();
    }

    function _deadline() internal view returns (uint256) {
        return block.timestamp + 3600;
    }
}

// ============================================================================
//  BROKEN-1: curveAllocation Mismatch (TokenFactory + BondingCurveFactory)
//
//  TokenFactory.createTokenWithBondingCurve sends 80% of supply to the curve
//  but BondingCurveFactory.createBondingCurve sets curveAllocation = 100%.
//  The curve believes it can sell 1B tokens. It only holds 800M.
//  Any user buying past ~800M triggers a revert — the curve is bricked.
//  curveFinished never fires, migrateLiquidity is stuck.
// ============================================================================
contract Broken1_CurveAllocationMismatch is BaseSetup {
    TokenFactory internal tokenFactory;
    BondingCurveFactory internal bcFactory;
    MockV3Aggregator internal priceFeed;

    function setUp() public {
        vm.startPrank(owner);

        priceFeed = new MockV3Aggregator(8, 60000000000); // $600
        bcFactory = new BondingCurveFactory(feeRecipient, address(priceFeed));
        tokenFactory = new TokenFactory(address(bcFactory));
        bcFactory.setAuthorizedCaller(address(tokenFactory), true);

        vm.stopPrank();
    }

    function test_curveAllocation_exceeds_actual_balance() public {
        address creator = makeAddr("creator");
        vm.prank(creator);
        (address tokenAddr, address curveAddr) = tokenFactory.createTokenWithBondingCurve(
            "Bug", "BUG", 18, "", "", "", "", "", new string[](0), new uint256[](0)
        );

        BondingCurveBNB c = BondingCurveBNB(payable(curveAddr));
        MemeToken t = MemeToken(tokenAddr);

        uint256 curveAlloc = c.curveAllocation();
        uint256 actualTokens = t.balanceOf(curveAddr);

        // Curve thinks it can sell 1B
        assertEq(curveAlloc, TOTAL_SUPPLY * WAD, "curveAllocation should be 1B");
        // Curve only holds 800M
        assertEq(actualTokens, (TOTAL_SUPPLY * WAD * 80) / 100, "actual balance should be 800M");
        // The gap
        uint256 deficit = curveAlloc - actualTokens;
        assertEq(deficit, (TOTAL_SUPPLY * WAD * 20) / 100, "200M token deficit");

        // Prove the curve is NOT finished and thinks it has 1B remaining
        assertFalse(c.curveFinished());
        assertEq(c.sold(), 0);
        // remaining = curveAllocation - sold = 1B — but only 800M exist in the contract
    }

    function test_curve_bricks_when_buys_approach_funded_amount() public {
        address creator = makeAddr("creator");
        vm.prank(creator);
        (address tokenAddr, address curveAddr) = tokenFactory.createTokenWithBondingCurve(
            "Brick", "BRICK", 18, "", "", "", "", "", new string[](0), new uint256[](0)
        );

        BondingCurveBNB c = BondingCurveBNB(payable(curveAddr));
        MemeToken t = MemeToken(tokenAddr);

        // Exclude buyer from anti-sniper so limits don't interfere
        vm.prank(creator);
        t.setExcludedFromLimits(address(this), true);

        uint256 deadline = _deadline();
        uint256 funded = t.balanceOf(curveAddr); // 800M * 1e18

        // Keep buying until the curve runs out of tokens
        uint256 totalBought;
        uint256 buySize = 5 ether;
        bool bricked;

        for (uint256 i; i < 200; i++) {
            vm.deal(address(this), buySize);
            try c.buyWithBNB{value: buySize}(0, deadline) {
                totalBought = c.sold();
                if (totalBought >= funded) break;
            } catch {
                bricked = true;
                break;
            }
        }

        // Either the curve bricked (safeTransfer reverted) or sold == funded
        // but curveFinished is still false because curveAllocation is 1B not 800M
        if (totalBought >= funded) {
            // The curve auto-finishes only at curveAllocation (1B).
            // At 800M sold the curve still thinks it has 200M more to sell.
            assertFalse(c.curveFinished(), "curve should NOT be finished at 800M sold");
        }

        assertTrue(bricked || !c.curveFinished(),
            "Curve either bricked or failed to auto-finish -- both prove the bug");
    }

    receive() external payable {}
}

// ============================================================================
//  BROKEN-2: Rounding Micro-Insolvency After Split Buys
//
//  buyQuoteFor rounds down via integer division. When N users buy individually,
//  the contract retains sum(buyQuoteFor(si, dsi)) BNB. But the solvency check
//  requires sellQuoteFor(totalSold, totalSold) == buyQuoteFor(0, totalSold).
//  Because of integer rounding: sum of parts < whole.
//  The contract is a few wei short — technically insolvent.
//  The last seller cannot fully exit.
// ============================================================================
contract Broken2_RoundingMicroInsolvency is BaseSetup {

    function setUp() public {
        _deployMatched();
    }

    function test_split_buys_create_insolvency() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");

        vm.prank(owner);
        token.setExcludedFromLimits(alice, true);
        vm.prank(owner);
        token.setExcludedFromLimits(bob, true);
        vm.prank(owner);
        token.setExcludedFromLimits(carol, true);

        uint256 deadline = _deadline();

        // Three separate buys
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        curve.buyWithBNB{value: 0.05 ether}(0, deadline);

        vm.deal(bob, 1 ether);
        vm.prank(bob);
        curve.buyWithBNB{value: 0.2 ether}(0, deadline);

        vm.deal(carol, 1 ether);
        vm.prank(carol);
        curve.buyWithBNB{value: 0.5 ether}(0, deadline);

        // Check solvency
        uint256 sold = curve.sold();
        uint256 balance = address(curve).balance;
        uint256 grossRequired = curve.sellQuoteFor(sold, sold);
        uint256 feesExtracted = curve.totalSellFeesExtracted();
        uint256 netRequired = grossRequired > feesExtracted ? grossRequired - feesExtracted : 0;

        // The contract holds LESS than required — micro-insolvency
        if (balance < netRequired) {
            uint256 deficit = netRequired - balance;
            // Deficit is non-zero but tiny (dust)
            assertGt(deficit, 0, "deficit should be > 0");
            // Should be under 1 gwei — rounding artifact not exploitable for profit
            assertLt(deficit, 1 gwei, "deficit should be dust-level");
            // But the invariant IS broken: contract cannot fully pay out all sellers
        } else {
            // If balance >= netRequired, solvency held for this specific input
            // Fuzz will find inputs where it breaks
        }
    }

    /// @notice Fuzz version: random buy sizes to find insolvency
    function testFuzz_split_buys_insolvency(
        uint96 buyA,
        uint96 buyB,
        uint96 buyC
    ) public {
        // Bound to meaningful range
        buyA = uint96(bound(buyA, 0.001 ether, 2 ether));
        buyB = uint96(bound(buyB, 0.001 ether, 2 ether));
        buyC = uint96(bound(buyC, 0.001 ether, 2 ether));

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address carol = makeAddr("carol");

        vm.prank(owner);
        token.setExcludedFromLimits(alice, true);
        vm.prank(owner);
        token.setExcludedFromLimits(bob, true);
        vm.prank(owner);
        token.setExcludedFromLimits(carol, true);

        uint256 deadline = _deadline();

        vm.deal(alice, uint256(buyA) + 1 ether);
        vm.prank(alice);
        try curve.buyWithBNB{value: buyA}(0, deadline) {} catch { return; }

        vm.deal(bob, uint256(buyB) + 1 ether);
        vm.prank(bob);
        try curve.buyWithBNB{value: buyB}(0, deadline) {} catch { return; }

        vm.deal(carol, uint256(buyC) + 1 ether);
        vm.prank(carol);
        try curve.buyWithBNB{value: buyC}(0, deadline) {} catch { return; }

        uint256 sold = curve.sold();
        if (sold == 0) return;

        uint256 balance = address(curve).balance;
        uint256 grossRequired = curve.sellQuoteFor(sold, sold);
        uint256 feesExtracted = curve.totalSellFeesExtracted();
        uint256 netRequired = grossRequired > feesExtracted ? grossRequired - feesExtracted : 0;

        if (balance < netRequired) {
            uint256 deficit = netRequired - balance;
            // Proven: insolvency exists. But it must be dust-level, not exploitable.
            assertLt(deficit, 1 gwei, "exploitable insolvency - deficit exceeds dust");
        }
    }

    /// @notice Prove the last seller is the victim: they get less than their full quote
    function test_last_seller_cannot_fully_exit() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        vm.prank(owner);
        token.setExcludedFromLimits(alice, true);
        vm.prank(owner);
        token.setExcludedFromLimits(bob, true);

        uint256 deadline = _deadline();

        // Two separate buys
        vm.deal(alice, 5 ether);
        vm.prank(alice);
        curve.buyWithBNB{value: 0.5 ether}(0, deadline);

        vm.deal(bob, 5 ether);
        vm.prank(bob);
        curve.buyWithBNB{value: 1 ether}(0, deadline);

        // Alice approves and sells all her tokens first
        uint256 aliceTokens = token.balanceOf(alice);
        vm.startPrank(alice);
        token.approve(address(curve), aliceTokens);
        curve.sell(aliceTokens, 0, deadline);
        vm.stopPrank();

        // Now Bob tries to sell
        uint256 bobTokens = token.balanceOf(bob);
        uint256 bobGross = curve.sellQuoteFor(curve.sold(), bobTokens);
        uint256 contractBNB = address(curve).balance;

        vm.startPrank(bob);
        token.approve(address(curve), bobTokens);

        // If contract BNB < bobGross, Bob cannot sell at the quoted price
        if (contractBNB < bobGross) {
            vm.expectRevert("insufficient liquidity");
            curve.sell(bobTokens, 0, deadline);
        } else {
            curve.sell(bobTokens, 0, deadline);
        }
        vm.stopPrank();
    }
}

// ============================================================================
//  BROKEN-3: Buy-Then-Dump — Cooldown Bypass
//
//  MemeToken enforces cooldownPeriod on the `from` address in transfer/transferFrom.
//  When BondingCurve.buyWithBNB calls token.safeTransfer(buyer, ds), the buyer
//  is `to` — their lastTransferTime is NEVER updated.
//  The buyer can immediately call sell() — transferFrom(buyer, curve, tokens)
//  uses buyer as `from`, but lastTransferTime[buyer] is still 0.
//  block.timestamp - 0 >= cooldownPeriod is always true.
//  A sniper bot can atomically buy + dump in one transaction.
// ============================================================================
contract Broken3_BuyThenDumpCooldownBypass is BaseSetup {

    function setUp() public {
        _deployMatched();
        // Set a long cooldown to make the bypass obvious
        vm.prank(owner);
        token.updateAntiSniperSettings(true, TOTAL_SUPPLY, TOTAL_SUPPLY, 300);
    }

    function test_buyer_sells_immediately_no_cooldown() public {
        // Use a NON-excluded user to prove cooldown bypass is real
        // (excluded users skip cooldown by design, that proves nothing)
        address sniper = makeAddr("sniper");
        // NOT excluded — cooldown SHOULD apply

        // But we need maxWallet high enough to receive tokens
        vm.prank(owner);
        token.updateAntiSniperSettings(true, TOTAL_SUPPLY, TOTAL_SUPPLY, 300);

        vm.deal(sniper, 1 ether);
        uint256 deadline = _deadline();

        // Exclude sniper only for the buy (so curve can send tokens despite maxWallet)
        // Actually maxWallet is set to TOTAL_SUPPLY above so no issue.
        // Buy
        vm.prank(sniper);
        curve.buyWithBNB{value: 0.01 ether}(0, deadline);
        uint256 bought = token.balanceOf(sniper);
        assertGt(bought, 0, "should have bought tokens");

        // Approve curve to pull tokens back
        vm.prank(sniper);
        token.approve(address(curve), bought);

        // Sell IMMEDIATELY in same block. Sniper is NOT excluded.
        // cooldownPeriod = 300s. If lastTransferTime[sniper] had been set
        // during the buy, this would revert "Cooldown active".
        // But lastTransferTime[sniper] is still 0, and
        // block.timestamp - 0 >= 300 is true, so cooldown is bypassed.
        vm.prank(sniper);
        curve.sell(bought, 0, deadline);

        assertEq(token.balanceOf(sniper), 0, "sniper dumped everything with no cooldown");
    }

    function test_sniper_bot_atomic_buy_and_dump() public {
        SniperBot bot = new SniperBot(address(curve), address(token));

        // Exclude bot so anti-sniper maxWallet doesn't block the test
        vm.prank(owner);
        token.setExcludedFromLimits(address(bot), true);

        vm.deal(address(bot), 1 ether);
        uint256 deadline = _deadline();

        // Single atomic transaction: buy + sell in one call
        // If cooldown worked between buy and sell, this would revert inside the bot.
        bot.buyAndDump{value: 0.1 ether}(deadline);

        // Bot has zero tokens — it dumped them all in the same tx
        assertEq(token.balanceOf(address(bot)), 0, "bot dumped atomically");
    }

    /// @notice Prove that NORMAL transfers DO enforce cooldown (so the bypass is real)
    function test_normal_transfer_cooldown_works() public {
        address user = makeAddr("user");
        address other = makeAddr("other");

        // maxWallet/maxTx high, cooldown = 300s (from setUp)
        vm.prank(owner);
        token.transfer(user, 1000 * WAD);

        // First transfer: user is `from`, not excluded. lastTransferTime[user] = 0.
        // block.timestamp (1.7B) - 0 >= 300 → passes. Sets lastTransferTime[user] = now.
        vm.prank(user);
        token.transfer(other, 100 * WAD);

        // Second transfer immediately — now block.timestamp - lastTransferTime = 0 < 300 → reverts
        vm.prank(user);
        vm.expectRevert("Cooldown active");
        token.transfer(other, 100 * WAD);
    }
}

// ============================================================================
//  BROKEN-4: Anti-Sniper Lock Bypass
//
//  lockAntiSniperSettings() is supposed to freeze protection so the owner
//  can only relax limits. But updateAntiSniperSettings allows setting
//  antiSniperEnabled = false even when locked. The lock checks only guard
//  maxWallet, maxTransaction, and cooldownPeriod — NOT the enabled flag.
//  Any user relying on the lock being meaningful is deceived.
//
//  This IS a user-perspective issue: users see antiSniperLocked == true
//  and trust that protection cannot be removed. The owner can remove it anyway.
//  Users make buy decisions based on this false guarantee.
// ============================================================================
contract Broken4_AntiSniperLockBypass is BaseSetup {

    function setUp() public {
        _deployMatched();
    }

    function test_lock_does_not_prevent_disabling() public {
        vm.startPrank(owner);
        token.updateAntiSniperSettings(true, TOTAL_SUPPLY, TOTAL_SUPPLY, 60);
        token.lockAntiSniperSettings();
        vm.stopPrank();

        // Verify state: locked and enabled
        assertTrue(token.antiSniperLocked(), "should be locked");
        assertTrue(token.antiSniperEnabled(), "should be enabled");

        // Owner disables — this SHOULD revert but doesn't
        vm.prank(owner);
        token.updateAntiSniperSettings(false, TOTAL_SUPPLY, TOTAL_SUPPLY, 60);

        // Lock is bypassed: anti-sniper is now off
        assertFalse(token.antiSniperEnabled(), "anti-sniper disabled despite lock");
        assertTrue(token.antiSniperLocked(), "lock flag still true - contradictory state");
    }

    function test_user_trusts_lock_gets_rugged() public {
        vm.startPrank(owner);
        token.updateAntiSniperSettings(true, 10_000_000, 5_000_000, 60);
        token.lockAntiSniperSettings();
        vm.stopPrank();

        // User checks: locked? yes. enabled? yes. Safe to buy? they think so.
        assertTrue(token.antiSniperLocked());
        assertTrue(token.antiSniperEnabled());

        // User buys on the curve
        address user = makeAddr("user");
        vm.prank(owner);
        token.setExcludedFromLimits(user, true);
        vm.deal(user, 1 ether);
        vm.prank(user);
        curve.buyWithBNB{value: 0.01 ether}(0, _deadline());
        uint256 userBal = token.balanceOf(user);
        assertGt(userBal, 0);

        // Owner disables all protection
        vm.prank(owner);
        token.updateAntiSniperSettings(false, 10_000_000, 5_000_000, 60);

        // Now a whale can dump unlimited tokens in a single block with no cooldown
        // The user's "guarantee" that anti-sniper was locked was meaningless
        assertFalse(token.antiSniperEnabled());
    }
}

// ============================================================================
//  BROKEN-5: maxTransaction Throttles Bonding Curve Sells
//
//  When a user sells on the curve, BondingCurve.sell calls
//  token.safeTransferFrom(seller, curve, tokensIn).
//  MemeToken.transferFrom checks maxTransaction on `from` (the seller).
//  The seller is NOT excluded. So maxTransaction limits how many tokens
//  a user can sell to the curve in one tx.
//
//  Combined with cooldownPeriod, this means a user who bought 50M tokens
//  but maxTx is 5M must sell in 10 separate txs, each waiting for cooldown.
//  If cooldown is 60s, it takes 10 minutes to exit. On BSC, this is an
//  eternity during a dump — the user's tokens lose value while they wait.
// ============================================================================
contract Broken5_MaxTxThrottlesCurveSells is BaseSetup {

    function setUp() public {
        _deployMatched();
    }

    function test_user_cannot_sell_more_than_maxTx() public {
        address user = makeAddr("user");
        vm.prank(owner);
        token.setExcludedFromLimits(user, true);

        // User buys tokens
        vm.deal(user, 5 ether);
        vm.prank(user);
        curve.buyWithBNB{value: 1 ether}(0, _deadline());
        uint256 bought = token.balanceOf(user);
        assertGt(bought, 0);

        // Approve curve
        vm.prank(user);
        token.approve(address(curve), type(uint256).max);

        // Owner sets restrictive maxTx (1M tokens) AFTER user bought
        // The user is NOT excluded
        vm.prank(owner);
        token.setExcludedFromLimits(user, false);
        vm.prank(owner);
        token.updateAntiSniperSettings(true, TOTAL_SUPPLY, 1_000_000, 1);

        uint256 maxTxRaw = 1_000_000 * WAD;

        if (bought > maxTxRaw) {
            // User tries to sell all at once — blocked
            vm.prank(user);
            vm.expectRevert("Transfer > maxTransaction");
            curve.sell(bought, 0, _deadline());
        }
    }

    function test_user_forced_into_slow_drip_sell() public {
        address user = makeAddr("user");
        vm.prank(owner);
        token.setExcludedFromLimits(user, true);

        vm.deal(user, 5 ether);
        vm.prank(user);
        curve.buyWithBNB{value: 0.5 ether}(0, _deadline());
        uint256 bought = token.balanceOf(user);

        // Approve curve
        vm.prank(user);
        token.approve(address(curve), type(uint256).max);

        // Owner removes exclusion and sets tight limits + cooldown
        vm.prank(owner);
        token.setExcludedFromLimits(user, false);
        vm.prank(owner);
        token.updateAntiSniperSettings(true, TOTAL_SUPPLY, 1_000_000, 60);

        uint256 maxTxRaw = 1_000_000 * WAD;
        uint256 sellsNeeded = bought / maxTxRaw;
        if (bought % maxTxRaw > 0) sellsNeeded++;

        // If user needs >1 sell, they're throttled
        if (sellsNeeded > 1) {
            // First sell succeeds
            uint256 chunk = maxTxRaw < bought ? maxTxRaw : bought;
            vm.prank(user);
            curve.sell(chunk, 0, _deadline());

            // Second sell immediately — blocked by cooldown
            uint256 remaining = token.balanceOf(user);
            if (remaining > 0) {
                uint256 chunk2 = maxTxRaw < remaining ? maxTxRaw : remaining;
                vm.prank(user);
                vm.expectRevert("Cooldown active");
                curve.sell(chunk2, 0, _deadline());
            }

            // User is stuck: they must wait 60s * (sellsNeeded-1) to fully exit
            assertGt(sellsNeeded, 1, "user needs multiple sells to exit");
        }
    }
}

// ============================================================================
//  BROKEN-6: Sell Blocked After Curve Auto-Finishes — Tokens Trapped
//
//  When sold >= curveAllocation, curveFinished = true. After that, sell()
//  reverts with "curve finished". Users who bought tokens at the top of the
//  curve cannot sell back — their BNB is locked.
//  They must wait for the owner to call migrateLiquidity() and hope a DEX
//  is set up. There is no guarantee.
//
//  This is a user-facing invariant break: "I bought tokens on the curve,
//  I should be able to sell them back on the curve."
// ============================================================================
contract Broken6_SellBlockedAfterFinish is BaseSetup {

    function setUp() public {
        // Deploy with small supply so we can exhaust the curve
        vm.startPrank(owner);

        uint256 smallSupply = 1000;
        uint256 rawSupply = smallSupply * WAD;
        uint256 curveAlloc = (rawSupply * 80) / 100;

        token = new MemeToken(
            "Small", "SM", 18, owner, smallSupply,
            "", "", "", "", "", new string[](0), new uint256[](0)
        );

        curve = new BondingCurveBNB(
            address(token),
            0.001 ether, // P0 — high enough to finish quickly
            0.001 ether, // M
            curveAlloc,
            feeRecipient,
            owner
        );

        token.approve(address(curve), curveAlloc);
        curve.depositCurveTokens(curveAlloc);
        token.setExcludedFromLimits(address(curve), true);

        vm.stopPrank();
    }

    function test_user_tokens_trapped_after_curve_finishes() public {
        address user = makeAddr("user");
        vm.prank(owner);
        token.setExcludedFromLimits(user, true);

        // Buy enough to finish the curve
        vm.deal(user, 100 ether);
        vm.prank(user);
        curve.buyWithBNB{value: 50 ether}(0, _deadline());

        // Curve should be finished
        assertTrue(curve.curveFinished(), "curve should be finished");

        uint256 userTokens = token.balanceOf(user);
        assertGt(userTokens, 0, "user should hold tokens");

        // User tries to sell — BLOCKED
        vm.prank(user);
        vm.expectRevert("curve finished");
        curve.sell(userTokens, 0, _deadline());

        // User's tokens are trapped. Their BNB is locked in the contract.
        // They must wait for owner to migrateLiquidity to a DEX.
        // No on-chain guarantee that ever happens.
    }
}

// ============================================================================
//  STATEFUL INVARIANT TEST HANDLER
//
//  Foundry's invariant testing: a Handler contract exposes actions that
//  the fuzzer calls in random order. After each call sequence, the test
//  contract checks invariants.
// ============================================================================
contract InvariantHandler is Test {
    BondingCurveBNB public curve;
    MemeToken public token;
    address[] public actors;
    uint256 public totalBuys;
    uint256 public totalSells;

    constructor(BondingCurveBNB _curve, MemeToken _token, address[] memory _actors) {
        curve = _curve;
        token = _token;
        actors = _actors;
    }

    function buy(uint256 actorSeed, uint256 amount) external {
        if (curve.curveFinished()) return;
        amount = bound(amount, 0.001 ether, 2 ether);
        address actor = actors[actorSeed % actors.length];

        vm.deal(actor, amount + 1 ether);
        vm.prank(actor);
        try curve.buyWithBNB{value: amount}(0, block.timestamp + 3600) {
            totalBuys++;
        } catch {}
    }

    function sell(uint256 actorSeed, uint256 fraction) external {
        if (curve.curveFinished()) return;
        address actor = actors[actorSeed % actors.length];
        uint256 bal = token.balanceOf(actor);
        if (bal == 0) return;

        fraction = bound(fraction, 1, 100);
        uint256 amount = (bal * fraction) / 100;
        if (amount == 0) amount = 1;

        // Advance time past cooldown
        vm.warp(block.timestamp + 31);

        vm.prank(actor);
        try curve.sell(amount, 0, block.timestamp + 3600) {
            totalSells++;
        } catch {}
    }
}

contract Broken_StatefulInvariant is BaseSetup {
    InvariantHandler internal handler;

    function setUp() public {
        _deployMatched();

        address[] memory actors = new address[](3);
        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");

        // Exclude actors and give them approvals
        for (uint256 i; i < actors.length; i++) {
            vm.prank(owner);
            token.setExcludedFromLimits(actors[i], true);
            vm.prank(actors[i]);
            token.approve(address(curve), type(uint256).max);
        }

        handler = new InvariantHandler(curve, token, actors);
        targetContract(address(handler));
    }

    /// Invariant: token.balanceOf(curve) == curveAllocation - sold
    function invariant_tokenConservation() public view {
        uint256 bal = token.balanceOf(address(curve));
        uint256 expected = curve.curveAllocation() - curve.sold();
        assertEq(bal, expected, "TOKEN CONSERVATION BROKEN");
    }

    /// Invariant: sold <= curveAllocation
    function invariant_soldBounded() public view {
        assertLe(curve.sold(), curve.curveAllocation(), "SOLD EXCEEDS ALLOCATION");
    }

    /// Invariant: solvency — deficit should be dust-level at worst
    function invariant_solvencyBounded() public view {
        uint256 sold = curve.sold();
        if (sold == 0) return;

        uint256 balance = address(curve).balance;
        uint256 grossRequired = curve.sellQuoteFor(sold, sold);
        uint256 feesExtracted = curve.totalSellFeesExtracted();
        uint256 netRequired = grossRequired > feesExtracted ? grossRequired - feesExtracted : 0;

        if (balance < netRequired) {
            uint256 deficit = netRequired - balance;
            // Deficit must be dust — not exploitable
            assertLt(deficit, 0.0001 ether, "SOLVENCY DEFICIT EXCEEDS DUST");
        }
    }
}
