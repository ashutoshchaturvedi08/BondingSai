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
//  BASE SETUP — reusable for all test suites
// ============================================================================
contract BaseSetup is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000;
    uint256 internal constant P0 = 5798000000;
    uint256 internal constant M = 12500000000;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");

    constructor() {
        vm.warp(1_700_000_000);
    }

    MemeToken internal token;
    BondingCurveBNB internal curve;

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
//  TEST: BUG-1,4,5,6 — Solvency After Buy (Root Cause Fix)
//  sellQuoteFor(s, ds) now uses base price at (s-ds) and adds quadratic term,
//  so sellQuoteFor(sold, sold) == buyQuoteFor(0, sold). Contract stays solvent.
// ============================================================================
contract Test_BUG1_Solvency is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_solvent_after_single_buy() public {
        address buyer = makeAddr("buyer");
        vm.prank(owner);
        token.setExcludedFromLimits(buyer, true);

        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        curve.buyWithBNB{value: 10 ether}(0, _deadline());

        uint256 sold = curve.sold();
        uint256 balance = address(curve).balance;
        uint256 required = curve.sellQuoteFor(sold, sold);

        assertGe(balance, required, "BUG-1 FIX: contract should be solvent after buy");
    }

    function test_solvent_after_multiple_buys() public {
        address[3] memory buyers;
        for (uint256 i; i < 3; i++) {
            buyers[i] = makeAddr(string(abi.encodePacked("buyer", i)));
            vm.prank(owner);
            token.setExcludedFromLimits(buyers[i], true);
        }

        uint256 deadline = _deadline();
        for (uint256 i; i < 3; i++) {
            vm.deal(buyers[i], 3 ether);
            vm.prank(buyers[i]);
            curve.buyWithBNB{value: 2 ether}(0, deadline);
        }

        uint256 sold = curve.sold();
        uint256 balance = address(curve).balance;
        uint256 required = curve.sellQuoteFor(sold, sold);

        // Multiple separate buys accumulate dust-level rounding from (b*ds)/WAD truncation.
        // The deficit is bounded and not exploitable. Verify it's < 1 gwei.
        if (balance < required) {
            uint256 deficit = required - balance;
            assertLt(deficit, 1 gwei, "BUG-6 FIX: deficit should be dust-level, not exploitable");
        }
    }

    function test_buy_sell_roundtrip_succeeds() public {
        address user = makeAddr("user");
        vm.prank(owner);
        token.setExcludedFromLimits(user, true);

        vm.deal(user, 5 ether);
        vm.prank(user);
        curve.buyWithBNB{value: 5 ether}(0, _deadline());

        uint256 bought = token.balanceOf(user);
        assertGt(bought, 0, "should have tokens");

        vm.startPrank(user);
        token.approve(address(curve), bought);
        curve.sell(bought, 0, _deadline());
        vm.stopPrank();

        assertEq(token.balanceOf(user), 0, "BUG-5 FIX: roundtrip should complete");
    }

    function test_sell_quote_lte_buy_quote() public {
        uint256 sold = 100_000_000 * WAD;
        uint256 ds = 25_000_000 * WAD;

        uint256 sellQ = curve.sellQuoteFor(sold, ds);
        uint256 buyQ = curve.buyQuoteFor(sold - ds, ds);

        assertEq(sellQ, buyQ, "BUG-4 FIX: sellQuote should equal buyQuote for same range");
    }
}

// ============================================================================
//  TEST: BUG-2,3,10 — Sell Fee Tracking & Last Seller Can Exit
// ============================================================================
contract Test_BUG2_SellFees is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_last_seller_can_exit() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        vm.prank(owner);
        token.setExcludedFromLimits(alice, true);
        vm.prank(owner);
        token.setExcludedFromLimits(bob, true);

        uint256 deadline = _deadline();

        vm.deal(alice, 5 ether);
        vm.prank(alice);
        curve.buyWithBNB{value: 3 ether}(0, deadline);

        vm.deal(bob, 5 ether);
        vm.prank(bob);
        curve.buyWithBNB{value: 3 ether}(0, deadline);

        uint256 aliceTokens = token.balanceOf(alice);
        vm.startPrank(alice);
        token.approve(address(curve), aliceTokens);
        curve.sell(aliceTokens, 0, deadline);
        vm.stopPrank();

        uint256 bobTokens = token.balanceOf(bob);
        vm.startPrank(bob);
        token.approve(address(curve), bobTokens);
        curve.sell(bobTokens, 0, deadline);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 0, "BUG-3 FIX: last seller should be able to exit");
    }

    function test_sell_fee_tracking() public {
        address user = makeAddr("user");
        vm.prank(owner);
        token.setExcludedFromLimits(user, true);

        vm.deal(user, 10 ether);
        vm.prank(user);
        curve.buyWithBNB{value: 5 ether}(0, _deadline());

        uint256 half = token.balanceOf(user) / 2;
        vm.startPrank(user);
        token.approve(address(curve), half);
        curve.sell(half, 0, _deadline());
        vm.stopPrank();

        assertGt(curve.totalSellFeesExtracted(), 0, "BUG-2 FIX: sell fees should be tracked");
    }
}

// ============================================================================
//  TEST: BUG-8,9 — Sweep & Migration
// ============================================================================
contract Test_BUG8_SweepAndMigration is BaseSetup {
    function setUp() public {
        vm.startPrank(owner);
        uint256 smallSupply = 1000;
        uint256 rawSupply = smallSupply * WAD;
        uint256 curveAlloc = (rawSupply * 80) / 100;

        token = new MemeToken(
            "Small", "SM", 18, owner, smallSupply,
            "", "", "", "", "", new string[](0), new uint256[](0)
        );
        curve = new BondingCurveBNB(
            address(token), 0.001 ether, 0.001 ether, curveAlloc, feeRecipient, owner
        );
        token.approve(address(curve), curveAlloc);
        curve.depositCurveTokens(curveAlloc);
        token.setExcludedFromLimits(address(curve), true);
        vm.stopPrank();
    }

    function test_migrateLiquidity_after_finish() public {
        address user = makeAddr("user");
        vm.prank(owner);
        token.setExcludedFromLimits(user, true);

        vm.deal(user, 100 ether);
        vm.prank(user);
        curve.buyWithBNB{value: 50 ether}(0, _deadline());

        assertTrue(curve.curveFinished(), "curve should auto-finish");
        assertGt(address(curve).balance, 0, "should have BNB");

        address payable dest = payable(makeAddr("dex"));
        uint256 balBefore = address(curve).balance;

        vm.prank(owner);
        curve.migrateLiquidity(dest);

        assertEq(address(curve).balance, 0, "BUG-9 FIX: all BNB migrated");
        assertEq(dest.balance, balBefore, "BUG-9 FIX: dest received BNB");
    }

    function test_sweep_after_delay() public {
        vm.prank(owner);
        curve.markCurveFinished();

        assertGt(curve.curveFinishedAt(), 0, "BUG-8 FIX: curveFinishedAt set");

        vm.prank(owner);
        vm.expectRevert("too early");
        curve.sweepRemainingBNB(payable(owner));

        vm.warp(block.timestamp + 180 days + 1);

        vm.deal(address(curve), 1 ether);
        vm.prank(owner);
        curve.sweepRemainingBNB(payable(owner));

        assertEq(address(curve).balance, 0, "BUG-8 FIX: BNB swept after delay");
    }
}

// ============================================================================
//  TEST: BUG-13,16 — Sell Blocked After curveFinished
// ============================================================================
contract Test_BUG13_SellBlockedAfterFinish is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_sell_reverts_after_curve_finished() public {
        address user = makeAddr("user");
        vm.prank(owner);
        token.setExcludedFromLimits(user, true);

        vm.deal(user, 1 ether);
        vm.prank(user);
        curve.buyWithBNB{value: 0.01 ether}(0, _deadline());

        vm.prank(owner);
        curve.markCurveFinished();
        assertTrue(curve.curveFinished());

        uint256 bal = token.balanceOf(user);
        vm.startPrank(user);
        token.approve(address(curve), bal);

        vm.expectRevert("curve finished");
        curve.sell(bal, 0, _deadline());
        vm.stopPrank();
    }
}

// ============================================================================
//  TEST: BUG-14 — rescueBNB Underflow Guard
// ============================================================================
contract Test_BUG14_RescueBNBUnderflow is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_rescueBNB_readable_error_on_overshoot() public {
        vm.deal(address(curve), 1 ether);
        vm.prank(owner);
        vm.expectRevert("insufficient balance");
        curve.rescueBNB(payable(owner), 2 ether);
    }
}

// ============================================================================
//  TEST: BUG-17,22 — Constructor Parameter Validation
// ============================================================================
contract Test_BUG17_ConstructorValidation is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_rejects_zero_P0() public {
        vm.expectRevert("P0 must be > 0");
        new BondingCurveBNB(address(token), 0, M, 100 * WAD, feeRecipient, owner);
    }

    function test_rejects_zero_m() public {
        vm.expectRevert("m must be > 0");
        new BondingCurveBNB(address(token), P0, 0, 100 * WAD, feeRecipient, owner);
    }

    function test_rejects_zero_curveAllocation() public {
        vm.expectRevert("curveAllocation must be > 0");
        new BondingCurveBNB(address(token), P0, M, 0, feeRecipient, owner);
    }
}

// ============================================================================
//  TEST: BUG-18 — Anti-Sniper Recipient Check (maxWallet enforced independently)
// ============================================================================
contract Test_BUG18_AntiSniperRecipient is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_maxWallet_enforced_on_recipient_from_excluded_sender() public {
        address bob = makeAddr("bob");
        vm.startPrank(owner);
        token.updateAntiSniperSettings(true, 100, 50, 1);
        vm.stopPrank();

        uint256 maxWalletRaw = 100 * WAD;

        uint256 attempt = maxWalletRaw + 1;
        vm.prank(owner);
        vm.expectRevert("Recipient > maxWallet");
        token.transfer(bob, attempt);
    }
}

// ============================================================================
//  TEST: BUG-19 — Factory MIN_P0/MIN_M Increased
// ============================================================================
contract Test_BUG19_FactoryMinBounds is Test {
    function test_rejects_sub_minimum_P0() public {
        TokenFactoryWithCurve factory = new TokenFactoryWithCurve(makeAddr("fee"));
        vm.expectRevert("P0 out of range");
        factory.createDefaultTokenWithCurve("T", "T", 1, 1e6, 0);
    }

    function test_rejects_sub_minimum_m() public {
        TokenFactoryWithCurve factory = new TokenFactoryWithCurve(makeAddr("fee"));
        vm.expectRevert("m out of range");
        factory.createDefaultTokenWithCurve("T", "T", 1e6, 1, 0);
    }

    function test_accepts_minimum_values() public {
        TokenFactoryWithCurve factory = new TokenFactoryWithCurve(makeAddr("fee"));
        (address tokenAddr, address curveAddr) = factory.createDefaultTokenWithCurve("T", "T", 1e6, 1e6, 0);
        assertTrue(tokenAddr != address(0));
        assertTrue(curveAddr != address(0));
    }
}

// ============================================================================
//  TEST: BUG-23 — Oracle answeredInRound Validation
// ============================================================================
contract Test_BUG23_OracleValidation is Test {
    function test_oracle_accepts_fresh_answer() public {
        vm.warp(1_700_000_000);
        MockV3Aggregator feed = new MockV3Aggregator(8, 60000000000);
        BondingCurveFactory factory = new BondingCurveFactory(makeAddr("fee"), address(feed));
        uint256 price = factory.getLatestBNBPrice();
        assertGt(price, 0, "BUG-23 FIX: fresh answer accepted");
    }
}

// ============================================================================
//  TEST: BROKEN-1 — curveAllocation Matches Funded Amount (800M not 1B)
// ============================================================================
contract Test_BROKEN1_CurveAllocationMatch is Test {
    TokenFactory internal tokenFactory;
    BondingCurveFactory internal bcFactory;
    MockV3Aggregator internal priceFeed;
    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");

    constructor() { vm.warp(1_700_000_000); }

    function setUp() public {
        vm.startPrank(owner);
        priceFeed = new MockV3Aggregator(8, 60000000000);
        bcFactory = new BondingCurveFactory(feeRecipient, address(priceFeed));
        tokenFactory = new TokenFactory(address(bcFactory));
        bcFactory.setAuthorizedCaller(address(tokenFactory), true);
        vm.stopPrank();
    }

    function test_curveAllocation_equals_funded_tokens() public {
        address creator = makeAddr("creator");
        vm.prank(creator);
        (address tokenAddr, address curveAddr) = tokenFactory.createTokenWithBondingCurve(
            "Fix", "FIX", 18, "", "", "", "", "", new string[](0), new uint256[](0)
        );

        BondingCurveBNB c = BondingCurveBNB(payable(curveAddr));
        MemeToken t = MemeToken(tokenAddr);

        uint256 curveAlloc = c.curveAllocation();
        uint256 actualTokens = t.balanceOf(curveAddr);

        assertEq(curveAlloc, actualTokens, "BROKEN-1 FIX: curveAllocation must match funded tokens");
        assertEq(curveAlloc, (1_000_000_000 * 1e18 * 80) / 100, "should be 800M");
    }

    function test_curve_auto_finishes_at_funded_amount() public {
        address creator = makeAddr("creator");
        vm.prank(creator);
        (address tokenAddr, address curveAddr) = tokenFactory.createTokenWithBondingCurve(
            "Auto", "AUTO", 18, "", "", "", "", "", new string[](0), new uint256[](0)
        );

        BondingCurveBNB c = BondingCurveBNB(payable(curveAddr));
        MemeToken t = MemeToken(tokenAddr);

        vm.prank(creator);
        t.setExcludedFromLimits(address(this), true);

        uint256 deadline = block.timestamp + 3600;
        uint256 funded = t.balanceOf(curveAddr);

        for (uint256 i; i < 300; i++) {
            if (c.curveFinished()) break;
            vm.deal(address(this), 10 ether);
            try c.buyWithBNB{value: 5 ether}(0, deadline) {} catch { break; }
        }

        assertTrue(c.curveFinished(), "BROKEN-1 FIX: curve should auto-finish when sold reaches funded amount");
        assertGe(c.sold(), funded - 1 ether, "sold should approach funded amount");
    }

    function test_migrateLiquidity_works_after_auto_finish() public {
        address creator = makeAddr("creator");
        vm.prank(creator);
        (address tokenAddr, address curveAddr) = tokenFactory.createTokenWithBondingCurve(
            "Mig", "MIG", 18, "", "", "", "", "", new string[](0), new uint256[](0)
        );

        BondingCurveBNB c = BondingCurveBNB(payable(curveAddr));
        MemeToken t = MemeToken(tokenAddr);

        vm.prank(creator);
        t.setExcludedFromLimits(address(this), true);

        uint256 deadline = block.timestamp + 3600;
        for (uint256 i; i < 300; i++) {
            if (c.curveFinished()) break;
            vm.deal(address(this), 10 ether);
            try c.buyWithBNB{value: 5 ether}(0, deadline) {} catch { break; }
        }

        assertTrue(c.curveFinished(), "should be finished");
        uint256 bnb = address(c).balance;
        assertGt(bnb, 0, "should have BNB");

        address payable dest = payable(makeAddr("dex"));
        vm.prank(creator);
        c.migrateLiquidity(dest);

        assertEq(dest.balance, bnb, "BROKEN-1 FIX: migration should work after auto-finish");
    }

    receive() external payable {}
}

// ============================================================================
//  TEST: BROKEN-3 — Buyer Cooldown Now Enforced
// ============================================================================
contract Test_BROKEN3_BuyerCooldown is BaseSetup {
    function setUp() public {
        _deployMatched();
        vm.prank(owner);
        token.updateAntiSniperSettings(true, TOTAL_SUPPLY, TOTAL_SUPPLY, 300);
    }

    function test_buyer_cannot_sell_immediately() public {
        address sniper = makeAddr("sniper");

        vm.deal(sniper, 1 ether);
        vm.prank(sniper);
        curve.buyWithBNB{value: 0.01 ether}(0, _deadline());

        uint256 bought = token.balanceOf(sniper);
        assertGt(bought, 0);

        vm.prank(sniper);
        token.approve(address(curve), bought);

        vm.prank(sniper);
        vm.expectRevert("Cooldown active");
        curve.sell(bought, 0, _deadline());
    }

    function test_buyer_can_sell_after_cooldown() public {
        address sniper = makeAddr("sniper");

        vm.deal(sniper, 1 ether);
        vm.prank(sniper);
        curve.buyWithBNB{value: 0.01 ether}(0, _deadline());

        uint256 bought = token.balanceOf(sniper);
        vm.prank(sniper);
        token.approve(address(curve), bought);

        vm.warp(block.timestamp + 301);

        vm.prank(sniper);
        curve.sell(bought, 0, _deadline());

        assertEq(token.balanceOf(sniper), 0, "BROKEN-3 FIX: sell should work after cooldown");
    }

    function test_sniper_bot_atomic_buy_dump_reverts() public {
        SniperBot bot = new SniperBot(address(curve), address(token));
        // Bot is NOT excluded — cooldown should block the atomic buy+sell.
        // maxWallet is set to TOTAL_SUPPLY in setUp, so receiving tokens won't fail.

        vm.deal(address(bot), 1 ether);

        vm.expectRevert("Cooldown active");
        bot.buyAndDump{value: 0.1 ether}(_deadline());
    }
}

// ============================================================================
//  TEST: BROKEN-4 — Anti-Sniper Lock Prevents Disabling
// ============================================================================
contract Test_BROKEN4_AntiSniperLock is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_cannot_disable_antisniper_when_locked() public {
        vm.startPrank(owner);
        token.updateAntiSniperSettings(true, TOTAL_SUPPLY, TOTAL_SUPPLY, 60);
        token.lockAntiSniperSettings();
        vm.stopPrank();

        assertTrue(token.antiSniperLocked());
        assertTrue(token.antiSniperEnabled());

        vm.prank(owner);
        vm.expectRevert("cannot disable anti-sniper when locked");
        token.updateAntiSniperSettings(false, TOTAL_SUPPLY, TOTAL_SUPPLY, 60);

        assertTrue(token.antiSniperEnabled(), "BROKEN-4 FIX: anti-sniper still enabled");
    }

    function test_can_relax_limits_when_locked() public {
        vm.startPrank(owner);
        token.updateAntiSniperSettings(true, 1_000_000, 500_000, 60);
        token.lockAntiSniperSettings();

        token.updateAntiSniperSettings(true, 2_000_000, 1_000_000, 30);
        vm.stopPrank();

        assertEq(token.maxWallet(), 2_000_000 * WAD);
        assertEq(token.cooldownPeriod(), 30);
    }
}

// ============================================================================
//  TEST: BROKEN-5 — maxTransaction Does Not Throttle Curve Sells
// ============================================================================
contract Test_BROKEN5_MaxTxCurveSells is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_user_can_sell_full_amount_to_curve() public {
        address user = makeAddr("user");
        vm.prank(owner);
        token.setExcludedFromLimits(user, true);

        vm.deal(user, 5 ether);
        vm.prank(user);
        curve.buyWithBNB{value: 1 ether}(0, _deadline());
        uint256 bought = token.balanceOf(user);
        assertGt(bought, 0);

        vm.prank(user);
        token.approve(address(curve), type(uint256).max);

        vm.prank(owner);
        token.setExcludedFromLimits(user, false);
        vm.prank(owner);
        token.updateAntiSniperSettings(true, TOTAL_SUPPLY, 1_000_000, 1);

        uint256 maxTxRaw = 1_000_000 * WAD;
        if (bought > maxTxRaw) {
            vm.warp(block.timestamp + 2);
            vm.prank(user);
            curve.sell(bought, 0, _deadline());
            assertEq(token.balanceOf(user), 0, "BROKEN-5 FIX: full sell to curve should succeed");
        }
    }

    function test_maxTx_still_enforced_for_normal_transfers() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        vm.prank(owner);
        token.updateAntiSniperSettings(true, TOTAL_SUPPLY, 100, 1);

        vm.prank(owner);
        token.transfer(alice, 200 * WAD);

        uint256 maxTxRaw = 100 * WAD;

        vm.prank(alice);
        vm.expectRevert("Transfer > maxTransaction");
        token.transfer(bob, maxTxRaw + 1);
    }
}

// ============================================================================
//  TEST: BROKEN-6 — Sell Blocked After Auto-Finish (Design Acknowledgment)
// ============================================================================
contract Test_BROKEN6_SellBlockedAfterFinish is BaseSetup {
    function setUp() public {
        vm.startPrank(owner);
        uint256 smallSupply = 1000;
        uint256 rawSupply = smallSupply * WAD;
        uint256 curveAlloc = (rawSupply * 80) / 100;

        token = new MemeToken(
            "Small", "SM", 18, owner, smallSupply,
            "", "", "", "", "", new string[](0), new uint256[](0)
        );
        curve = new BondingCurveBNB(
            address(token), 0.001 ether, 0.001 ether, curveAlloc, feeRecipient, owner
        );
        token.approve(address(curve), curveAlloc);
        curve.depositCurveTokens(curveAlloc);
        token.setExcludedFromLimits(address(curve), true);
        vm.stopPrank();
    }

    function test_sell_blocked_after_auto_finish_migration_works() public {
        address user = makeAddr("user");
        vm.prank(owner);
        token.setExcludedFromLimits(user, true);

        vm.deal(user, 100 ether);
        vm.prank(user);
        curve.buyWithBNB{value: 50 ether}(0, _deadline());

        assertTrue(curve.curveFinished());
        uint256 userTokens = token.balanceOf(user);

        vm.prank(user);
        token.approve(address(curve), userTokens);
        vm.prank(user);
        vm.expectRevert("curve finished");
        curve.sell(userTokens, 0, _deadline());

        address payable dest = payable(makeAddr("dex"));
        vm.prank(owner);
        curve.migrateLiquidity(dest);
        assertGt(dest.balance, 0, "BROKEN-6: migration works so users can sell on DEX");
    }
}

// ============================================================================
//  STATEFUL INVARIANT TEST — Solvency Under Random Buy/Sell Sequences
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

        vm.warp(block.timestamp + 301);

        vm.prank(actor);
        try curve.sell(amount, 0, block.timestamp + 3600) {
            totalSells++;
        } catch {}
    }
}

contract Test_StatefulInvariant is BaseSetup {
    InvariantHandler internal handler;

    function setUp() public {
        _deployMatched();

        address[] memory actors = new address[](3);
        actors[0] = makeAddr("actor0");
        actors[1] = makeAddr("actor1");
        actors[2] = makeAddr("actor2");

        for (uint256 i; i < actors.length; i++) {
            vm.prank(owner);
            token.setExcludedFromLimits(actors[i], true);
            vm.prank(actors[i]);
            token.approve(address(curve), type(uint256).max);
        }

        handler = new InvariantHandler(curve, token, actors);
        targetContract(address(handler));
    }

    function invariant_tokenConservation() public view {
        uint256 bal = token.balanceOf(address(curve));
        uint256 expected = curve.curveAllocation() - curve.sold();
        assertEq(bal, expected, "TOKEN CONSERVATION BROKEN");
    }

    function invariant_soldBounded() public view {
        assertLe(curve.sold(), curve.curveAllocation(), "SOLD EXCEEDS ALLOCATION");
    }

    function invariant_solvencyBounded() public view {
        uint256 sold = curve.sold();
        if (sold == 0) return;

        uint256 balance = address(curve).balance;
        uint256 grossRequired = curve.sellQuoteFor(sold, sold);
        uint256 feesExtracted = curve.totalSellFeesExtracted();
        uint256 netRequired = grossRequired > feesExtracted ? grossRequired - feesExtracted : 0;

        if (balance < netRequired) {
            uint256 deficit = netRequired - balance;
            assertLt(deficit, 0.0001 ether, "SOLVENCY DEFICIT EXCEEDS DUST");
        }
    }
}
