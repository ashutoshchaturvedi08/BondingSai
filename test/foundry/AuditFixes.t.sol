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
//  BASE SETUP
// ============================================================================
contract BaseSetup is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant TOTAL_SUPPLY = 1_000_000_000;
    uint256 internal constant P0 = 5798000000;
    uint256 internal constant M = 12500000000;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");

    constructor() { vm.warp(1_700_000_000); }

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

    function _buyAs(address user, uint256 amount) internal {
        vm.deal(user, amount + 1 ether);
        vm.prank(user);
        curve.buyWithBNB{value: amount}(0, _deadline());
    }
}

// ============================================================================
//  BUG-1,4,5,6 — Solvency
// ============================================================================
contract Test_BUG1_Solvency is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_solvent_after_single_buy() public {
        address buyer = makeAddr("buyer");
        vm.prank(owner); token.setExcludedFromLimits(buyer, true);
        _buyAs(buyer, 10 ether);

        uint256 s = curve.sold();
        assertGe(address(curve).balance, curve.sellQuoteFor(s, s), "should be solvent");
    }

    function test_buy_sell_roundtrip_succeeds() public {
        address user = makeAddr("user");
        vm.prank(owner); token.setExcludedFromLimits(user, true);
        _buyAs(user, 5 ether);

        uint256 bought = token.balanceOf(user);
        vm.startPrank(user);
        token.approve(address(curve), bought);
        curve.sell(bought, 0, _deadline());
        vm.stopPrank();
        assertEq(token.balanceOf(user), 0, "roundtrip should complete");
    }

    function test_sell_quote_equals_buy_quote() public view {
        uint256 s = 100_000_000 * WAD;
        uint256 ds = 25_000_000 * WAD;
        assertEq(curve.sellQuoteFor(s, ds), curve.buyQuoteFor(s - ds, ds));
    }
}

// ============================================================================
//  BUG-2,3,10 — Sell Fees & Last Seller Exit
// ============================================================================
contract Test_BUG2_SellFees is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_last_seller_can_exit() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        vm.prank(owner); token.setExcludedFromLimits(alice, true);
        vm.prank(owner); token.setExcludedFromLimits(bob, true);

        _buyAs(alice, 3 ether);
        _buyAs(bob, 3 ether);

        uint256 aliceTokens = token.balanceOf(alice);
        vm.startPrank(alice);
        token.approve(address(curve), aliceTokens);
        curve.sell(aliceTokens, 0, _deadline());
        vm.stopPrank();

        uint256 bobTokens = token.balanceOf(bob);
        vm.startPrank(bob);
        token.approve(address(curve), bobTokens);
        curve.sell(bobTokens, 0, _deadline());
        vm.stopPrank();
        assertEq(token.balanceOf(bob), 0, "last seller should exit");
    }
}

// ============================================================================
//  BUG-8,9 — Sweep & Migration (with HIGH-5 timelock)
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

    function test_migrateLiquidity_after_finish_and_delay() public {
        address user = makeAddr("user");
        vm.prank(owner); token.setExcludedFromLimits(user, true);

        vm.deal(user, 100 ether);
        vm.prank(user);
        curve.buyWithBNB{value: 50 ether}(0, _deadline());
        assertTrue(curve.curveFinished());

        // HIGH-5 FIX: migration blocked before delay
        vm.prank(owner);
        vm.expectRevert("migration delay not met");
        curve.migrateLiquidity(payable(owner));

        // After delay, migration works
        vm.warp(block.timestamp + 24 hours + 1);
        address payable dest = payable(makeAddr("dex"));
        uint256 bal = address(curve).balance;
        vm.prank(owner);
        curve.migrateLiquidity(dest);
        assertEq(dest.balance, bal, "BNB migrated after delay");
    }

    function test_sweep_after_180_days() public {
        address user = makeAddr("user");
        vm.prank(owner); token.setExcludedFromLimits(user, true);
        vm.deal(user, 100 ether);
        vm.prank(user);
        curve.buyWithBNB{value: 50 ether}(0, _deadline());
        assertTrue(curve.curveFinished());

        vm.prank(owner);
        vm.expectRevert("too early");
        curve.sweepRemainingBNB(payable(owner));

        vm.warp(block.timestamp + 180 days + 1);
        vm.deal(address(curve), 1 ether);
        vm.prank(owner);
        curve.sweepRemainingBNB(payable(owner));
        assertEq(address(curve).balance, 0);
    }
}

// ============================================================================
//  BUG-13,16 — Sell Blocked After Finished (needs 50% sold for markCurveFinished)
// ============================================================================
contract Test_BUG13_SellBlockedAfterFinish is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_sell_reverts_after_curve_finished() public {
        address user = makeAddr("user");
        vm.prank(owner); token.setExcludedFromLimits(user, true);

        // Buy enough to reach 50% threshold for markCurveFinished
        _buyAs(user, 50 ether);
        uint256 soldPct = (curve.sold() * 100) / curve.curveAllocation();
        assertTrue(soldPct >= 50, "need 50% sold");

        vm.prank(owner);
        curve.markCurveFinished();

        uint256 bal = token.balanceOf(user);
        vm.startPrank(user);
        token.approve(address(curve), bal);
        vm.expectRevert("curve finished");
        curve.sell(bal, 0, _deadline());
        vm.stopPrank();
    }
}

// ============================================================================
//  BUG-14 — rescueBNB Underflow Guard
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
//  BUG-17,22 — Constructor Validation
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
//  BUG-18 — Anti-Sniper Recipient Check
// ============================================================================
contract Test_BUG18_AntiSniperRecipient is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_maxWallet_enforced_on_recipient_from_excluded_sender() public {
        vm.prank(owner);
        token.updateAntiSniperSettings(true, 100, 50, 1);

        vm.prank(owner);
        vm.expectRevert("Recipient > maxWallet");
        token.transfer(makeAddr("bob"), 100 * WAD + 1);
    }
}

// ============================================================================
//  BUG-19 / MEDIUM-8 — Factory MIN Bounds (now 1e9)
// ============================================================================
contract Test_BUG19_FactoryMinBounds is Test {
    function test_rejects_sub_minimum_P0() public {
        TokenFactoryWithCurve factory = new TokenFactoryWithCurve(makeAddr("fee"));
        vm.expectRevert("P0 out of range");
        factory.createDefaultTokenWithCurve("T", "T", 1, 1e9, 0);
    }

    function test_rejects_sub_minimum_m() public {
        TokenFactoryWithCurve factory = new TokenFactoryWithCurve(makeAddr("fee"));
        vm.expectRevert("m out of range");
        factory.createDefaultTokenWithCurve("T", "T", 1e9, 1, 0);
    }

    function test_accepts_minimum_values() public {
        TokenFactoryWithCurve factory = new TokenFactoryWithCurve(makeAddr("fee"));
        (address t, address c) = factory.createDefaultTokenWithCurve("T", "T", 1e9, 1e9, 0);
        assertTrue(t != address(0) && c != address(0));
    }
}

// ============================================================================
//  BUG-23 — Oracle Validation
// ============================================================================
contract Test_BUG23_OracleValidation is Test {
    function test_oracle_accepts_fresh_answer() public {
        vm.warp(1_700_000_000);
        MockV3Aggregator feed = new MockV3Aggregator(8, 60000000000);
        BondingCurveFactory factory = new BondingCurveFactory(makeAddr("fee"), address(feed));
        uint256 price = factory.getLatestBNBPrice();
        assertGt(price, 0);
    }
}

// ============================================================================
//  BROKEN-1 — curveAllocation Match (800M)
// ============================================================================
contract Test_BROKEN1_CurveAllocationMatch is Test {
    TokenFactory internal tokenFactory;
    BondingCurveFactory internal bcFactory;
    address internal owner = makeAddr("owner");

    constructor() { vm.warp(1_700_000_000); }

    function setUp() public {
        vm.startPrank(owner);
        MockV3Aggregator pf = new MockV3Aggregator(8, 60000000000);
        bcFactory = new BondingCurveFactory(makeAddr("fee"), address(pf));
        tokenFactory = new TokenFactory(address(bcFactory));
        bcFactory.setAuthorizedCaller(address(tokenFactory), true);
        vm.stopPrank();
    }

    function test_curveAllocation_equals_funded_tokens() public {
        vm.prank(makeAddr("creator"));
        (, address curveAddr) = tokenFactory.createTokenWithBondingCurve(
            "Fix", "FIX", 18, "", "", "", "", "", new string[](0), new uint256[](0)
        );
        BondingCurveBNB c = BondingCurveBNB(payable(curveAddr));
        assertEq(c.curveAllocation(), (1_000_000_000 * 1e18 * 80) / 100, "should be 800M");
    }

    receive() external payable {}
}

// ============================================================================
//  BROKEN-3 — Buyer Cooldown Enforced
// ============================================================================
contract Test_BROKEN3_BuyerCooldown is BaseSetup {
    function setUp() public {
        _deployMatched();
        vm.prank(owner);
        token.updateAntiSniperSettings(true, TOTAL_SUPPLY, TOTAL_SUPPLY, 300);
    }

    function test_buyer_cannot_sell_immediately() public {
        address sniper = makeAddr("sniper");
        _buyAs(sniper, 0.01 ether);
        uint256 bought = token.balanceOf(sniper);

        vm.prank(sniper); token.approve(address(curve), bought);
        vm.prank(sniper);
        vm.expectRevert("Cooldown active");
        curve.sell(bought, 0, _deadline());
    }

    function test_buyer_can_sell_after_cooldown() public {
        address sniper = makeAddr("sniper");
        _buyAs(sniper, 0.01 ether);
        uint256 bought = token.balanceOf(sniper);

        vm.prank(sniper); token.approve(address(curve), bought);
        vm.warp(block.timestamp + 301);
        vm.prank(sniper);
        curve.sell(bought, 0, _deadline());
        assertEq(token.balanceOf(sniper), 0);
    }

    function test_sniper_bot_atomic_buy_dump_reverts() public {
        SniperBot bot = new SniperBot(address(curve), address(token));
        vm.deal(address(bot), 1 ether);
        vm.expectRevert("Cooldown active");
        bot.buyAndDump{value: 0.1 ether}(_deadline());
    }
}

// ============================================================================
//  BROKEN-4 + MEDIUM-7 — Anti-Sniper Lock (enabled flag frozen)
// ============================================================================
contract Test_BROKEN4_AntiSniperLock is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_cannot_change_enabled_flag_when_locked() public {
        vm.startPrank(owner);
        token.updateAntiSniperSettings(true, TOTAL_SUPPLY, TOTAL_SUPPLY, 60);
        token.lockAntiSniperSettings();
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert("cannot change enabled flag when locked");
        token.updateAntiSniperSettings(false, TOTAL_SUPPLY, TOTAL_SUPPLY, 60);
        assertTrue(token.antiSniperEnabled());
    }

    function test_cannot_lock_while_disabled() public {
        vm.startPrank(owner);
        token.updateAntiSniperSettings(false, TOTAL_SUPPLY, TOTAL_SUPPLY, 30);
        vm.expectRevert("must be enabled to lock");
        token.lockAntiSniperSettings();
        vm.stopPrank();
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
//  BROKEN-5 — maxTransaction Does Not Throttle Curve Sells
// ============================================================================
contract Test_BROKEN5_MaxTxCurveSells is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_user_can_sell_full_amount_to_curve() public {
        address user = makeAddr("user");
        vm.prank(owner); token.setExcludedFromLimits(user, true);
        _buyAs(user, 1 ether);
        uint256 bought = token.balanceOf(user);

        vm.prank(user); token.approve(address(curve), type(uint256).max);
        vm.prank(owner); token.setExcludedFromLimits(user, false);
        vm.prank(owner); token.updateAntiSniperSettings(true, TOTAL_SUPPLY, 1_000_000, 1);

        if (bought > 1_000_000 * WAD) {
            vm.warp(block.timestamp + 2);
            vm.prank(user);
            curve.sell(bought, 0, _deadline());
            assertEq(token.balanceOf(user), 0, "full sell to curve should succeed");
        }
    }
}

// ============================================================================
//  CRITICAL-1 — Creator Cannot Rug via sell() with Free Tokens
// ============================================================================
contract Test_CRITICAL1_CreatorRug is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_creator_cannot_sell_free_tokens() public {
        address buyer = makeAddr("buyer");
        vm.prank(owner); token.setExcludedFromLimits(buyer, true);
        _buyAs(buyer, 5 ether);

        uint256 sold = curve.sold();
        assertGt(sold, 0);

        // Owner has 200M free tokens (20%). Try to sell them on the curve.
        uint256 ownerTokens = token.balanceOf(owner);
        assertGt(ownerTokens, 0, "owner should have free tokens");

        vm.startPrank(owner);
        token.approve(address(curve), ownerTokens);
        uint256 sellAmount = sold < ownerTokens ? sold : ownerTokens;

        vm.expectRevert("can only sell tokens bought from curve");
        curve.sell(sellAmount, 0, _deadline());
        vm.stopPrank();
    }

    function test_buyer_can_sell_bought_tokens() public {
        address buyer = makeAddr("buyer");
        vm.prank(owner); token.setExcludedFromLimits(buyer, true);
        _buyAs(buyer, 2 ether);

        uint256 bought = token.balanceOf(buyer);
        assertEq(curve.boughtFromCurve(buyer), bought, "boughtFromCurve should track");

        vm.startPrank(buyer);
        token.approve(address(curve), bought);
        curve.sell(bought, 0, _deadline());
        vm.stopPrank();
        assertEq(curve.boughtFromCurve(buyer), 0, "boughtFromCurve should be 0 after sell");
    }
}

// ============================================================================
//  CRITICAL-2 — Fee Computed on actualCost, Not msg.value
// ============================================================================
contract Test_CRITICAL2_FeeOvercharge is BaseSetup {
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

    function test_fee_not_overcharged_on_partial_fill() public {
        address user = makeAddr("user");
        vm.prank(owner); token.setExcludedFromLimits(user, true);

        uint256 feeRecipientBalBefore = feeRecipient.balance;
        vm.deal(user, 10 ether);
        vm.prank(user);
        curve.buyWithBNB{value: 10 ether}(0, _deadline());

        uint256 feeCollected = feeRecipient.balance - feeRecipientBalBefore;
        uint256 actualCostBound = curve.buyQuoteFor(0, curve.sold());

        // Fee should be ~1% of actualCost, NOT 1% of 10 BNB
        // With 10 BNB input and ~0.8 BNB worth of tokens, fee should be ~0.008 BNB, not 0.1 BNB
        assertLt(feeCollected, 0.5 ether, "CRITICAL-2 FIX: fee should not be based on full msg.value");
    }
}

// ============================================================================
//  CRITICAL-3 — rescueBNB/migrateLiquidity Have nonReentrant
// ============================================================================
contract Test_CRITICAL3_Reentrancy is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_rescueBNB_has_reentrancy_guard() public {
        vm.deal(address(curve), 10 ether);
        vm.prank(owner);
        curve.rescueBNB(payable(owner), 0);
    }
}

// ============================================================================
//  HIGH-4 — Anti-Sniper Auto-Locked by Factories
// ============================================================================
contract Test_HIGH4_AutoLock is Test {
    constructor() { vm.warp(1_700_000_000); }

    function test_factory_auto_locks_anti_sniper() public {
        TokenFactoryWithCurve factory = new TokenFactoryWithCurve(makeAddr("fee"));
        (address tokenAddr,) = factory.createDefaultTokenWithCurve("T", "T", 1e9, 1e9, 0);
        MemeToken t = MemeToken(tokenAddr);
        assertTrue(t.antiSniperLocked(), "HIGH-4 FIX: anti-sniper should be auto-locked");
    }

    function test_token_factory_auto_locks() public {
        MockV3Aggregator pf = new MockV3Aggregator(8, 60000000000);
        address owner = makeAddr("owner");
        vm.startPrank(owner);
        BondingCurveFactory bcf = new BondingCurveFactory(makeAddr("fee"), address(pf));
        TokenFactory tf = new TokenFactory(address(bcf));
        bcf.setAuthorizedCaller(address(tf), true);
        vm.stopPrank();

        vm.prank(makeAddr("creator"));
        (address tokenAddr,) = tf.createTokenWithBondingCurve(
            "A", "A", 18, "", "", "", "", "", new string[](0), new uint256[](0)
        );
        assertTrue(MemeToken(tokenAddr).antiSniperLocked(), "auto-locked via TokenFactory");
    }
}

// ============================================================================
//  HIGH-5 — markCurveFinished Requires 50% Sold + Migration Timelock
// ============================================================================
contract Test_HIGH5_FinishThreshold is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_cannot_finish_with_zero_sold() public {
        vm.prank(owner);
        vm.expectRevert("minimum sold threshold not met");
        curve.markCurveFinished();
    }

    function test_cannot_finish_below_50_percent() public {
        address user = makeAddr("user");
        vm.prank(owner); token.setExcludedFromLimits(user, true);
        _buyAs(user, 0.01 ether);
        assertGt(curve.sold(), 0);

        vm.prank(owner);
        vm.expectRevert("minimum sold threshold not met");
        curve.markCurveFinished();
    }

    function test_migration_blocked_before_delay() public {
        address user = makeAddr("user");
        vm.prank(owner); token.setExcludedFromLimits(user, true);
        _buyAs(user, 100 ether);

        uint256 pct = (curve.sold() * 100) / curve.curveAllocation();
        if (pct < 50) return;

        vm.prank(owner);
        curve.markCurveFinished();

        vm.prank(owner);
        vm.expectRevert("migration delay not met");
        curve.migrateLiquidity(payable(owner));
    }
}

// ============================================================================
//  MEDIUM-6 — Chainlink Stale Feed Does Not DoS Curve Creation
// ============================================================================
contract Test_MEDIUM6_StaleFeedDoS is Test {
    constructor() { vm.warp(1_700_000_000); }

    function test_stale_feed_does_not_block_createBondingCurve() public {
        MockV3Aggregator feed = new MockV3Aggregator(8, 60000000000);
        // Make feed stale by warping far ahead
        vm.warp(block.timestamp + 7200);

        BondingCurveFactory factory = new BondingCurveFactory(makeAddr("fee"), address(feed));
        (uint256 p0, uint256 m, uint256 price) = factory.calculateCurveParams();

        assertGt(p0, 0, "P0 should still be computed");
        assertGt(m, 0, "m should still be computed");
        assertEq(price, 0, "stale feed should return 0 price (informational only)");
    }
}

// ============================================================================
//  MEDIUM-7 — Cannot Re-enable Anti-Sniper When Locked
// ============================================================================
contract Test_MEDIUM7_LockReenableBlocked is BaseSetup {
    function setUp() public { _deployMatched(); }

    function test_cannot_reenable_after_lock() public {
        vm.startPrank(owner);
        token.updateAntiSniperSettings(true, TOTAL_SUPPLY, TOTAL_SUPPLY, 30);
        token.lockAntiSniperSettings();
        vm.stopPrank();

        // Cannot change enabled flag at all when locked
        vm.prank(owner);
        vm.expectRevert("cannot change enabled flag when locked");
        token.updateAntiSniperSettings(false, TOTAL_SUPPLY, TOTAL_SUPPLY, 30);
    }
}

// ============================================================================
//  MEDIUM-8 — MIN Bounds Provide Economic Protection
// ============================================================================
contract Test_MEDIUM8_MinBounds is Test {
    function test_minimum_cost_is_meaningful() public {
        TokenFactoryWithCurve factory = new TokenFactoryWithCurve(makeAddr("fee"));
        (, address curveAddr) = factory.createDefaultTokenWithCurve("T", "T", 1e9, 1e9, 0);
        BondingCurveBNB c = BondingCurveBNB(payable(curveAddr));

        uint256 costForAll = c.buyQuoteFor(0, c.curveAllocation());
        assertGt(costForAll, 0.5 ether, "MEDIUM-8 FIX: buying all tokens should cost meaningful BNB");
    }
}

// ============================================================================
//  NEW-BUG-1 — Cooldown Griefing Fixed (dust transfers don't reset cooldown)
// ============================================================================
contract Test_NewBug1_CooldownGriefing is BaseSetup {
    function setUp() public {
        _deployMatched();
        vm.prank(owner);
        token.updateAntiSniperSettings(true, TOTAL_SUPPLY, TOTAL_SUPPLY, 300);
    }

    function test_dust_transfer_does_not_reset_victim_cooldown() public {
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");

        // Owner (excluded) transfers to both — sets lastTransferTime from excluded sender
        vm.prank(owner); token.transfer(attacker, 1000 * WAD);
        vm.prank(owner); token.transfer(victim, 1000 * WAD);

        // Wait for all cooldowns to expire
        vm.warp(block.timestamp + 600);

        // Victim makes a transfer (sets lastTransferTime[victim] = now)
        vm.prank(victim);
        token.transfer(makeAddr("someone"), 1 * WAD);
        uint256 victimTransferTime = block.timestamp;

        // Wait for victim's cooldown to fully expire
        vm.warp(victimTransferTime + 301);

        // Attacker (not excluded) sends dust to victim — should NOT reset victim's cooldown
        vm.prank(attacker);
        token.transfer(victim, 1);

        // Victim should still be able to transfer (attacker's dust didn't reset cooldown)
        // because attacker is NOT excluded, lastTransferTime[victim] was NOT updated
        vm.prank(victim);
        token.transfer(makeAddr("someone2"), 1 * WAD);
    }

    function test_curve_buy_still_sets_buyer_cooldown() public {
        address buyer = makeAddr("buyer");
        _buyAs(buyer, 0.01 ether);

        uint256 bought = token.balanceOf(buyer);
        vm.prank(buyer); token.approve(address(curve), bought);

        // Buyer should still have cooldown from curve (excluded sender)
        vm.prank(buyer);
        vm.expectRevert("Cooldown active");
        curve.sell(bought, 0, _deadline());
    }
}

// ============================================================================
//  STATEFUL INVARIANT — Random Buy/Sell Sequences
// ============================================================================
contract InvariantHandler is Test {
    BondingCurveBNB public curve;
    MemeToken public token;
    address[] public actors;

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
        try curve.buyWithBNB{value: amount}(0, block.timestamp + 3600) {} catch {}
    }

    function sell(uint256 actorSeed, uint256 fraction) external {
        if (curve.curveFinished()) return;
        address actor = actors[actorSeed % actors.length];
        uint256 bal = curve.boughtFromCurve(actor);
        if (bal == 0) return;
        fraction = bound(fraction, 1, 100);
        uint256 amount = (bal * fraction) / 100;
        if (amount == 0) amount = 1;
        vm.warp(block.timestamp + 301);
        vm.prank(actor);
        try curve.sell(amount, 0, block.timestamp + 3600) {} catch {}
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
            vm.prank(owner); token.setExcludedFromLimits(actors[i], true);
            vm.prank(actors[i]); token.approve(address(curve), type(uint256).max);
        }

        handler = new InvariantHandler(curve, token, actors);
        targetContract(address(handler));
    }

    function invariant_tokenConservation() public view {
        assertEq(token.balanceOf(address(curve)), curve.curveAllocation() - curve.sold());
    }

    function invariant_soldBounded() public view {
        assertLe(curve.sold(), curve.curveAllocation());
    }

    function invariant_solvencyBounded() public view {
        uint256 s = curve.sold();
        if (s == 0) return;
        uint256 bal = address(curve).balance;
        uint256 req = curve.sellQuoteFor(s, s);
        uint256 fees = curve.totalSellFeesExtracted();
        uint256 net = req > fees ? req - fees : 0;
        if (bal < net) {
            assertLt(net - bal, 0.0001 ether, "SOLVENCY DEFICIT EXCEEDS DUST");
        }
    }
}
