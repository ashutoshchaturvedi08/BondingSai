// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title MockPriceFeed
 * @notice Mock Chainlink Price Feed for local testing
 * @dev Returns a fixed BNB price of $875 USD (8 decimals)
 */
contract MockPriceFeed is AggregatorV3Interface {
    uint256 public constant MOCK_BNB_PRICE_USD = 875 * 1e8; // $875 with 8 decimals

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function description() external pure override returns (string memory) {
        return "Mock BNB/USD Price Feed";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_roundId, int256(MOCK_BNB_PRICE_USD), 0, block.timestamp, _roundId);
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, int256(MOCK_BNB_PRICE_USD), 0, block.timestamp, 1);
    }
}


