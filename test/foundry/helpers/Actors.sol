// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "../../../contracts/BondingCurve.sol";
import "../../../contracts/MemeToken.sol";

contract SniperBot {
    BondingCurveBNB public curve;
    MemeToken public token;

    constructor(address _curve, address _token) {
        curve = BondingCurveBNB(payable(_curve));
        token = MemeToken(_token);
        token.approve(address(curve), type(uint256).max);
    }

    function buyAndDump(uint256 deadline) external payable {
        curve.buyWithBNB{value: msg.value}(0, deadline);
        uint256 bal = token.balanceOf(address(this));
        if (bal > 0) {
            curve.sell(bal, 0, deadline);
        }
    }

    receive() external payable {}
}
