// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockV3Aggregator {
    uint8 public decimals;
    int256 public latestAnswer;
    uint256 public latestTimestamp;
    uint80 public latestRoundId;

    constructor(uint8 _decimals, int256 _initialAnswer) {
        decimals = _decimals;
        latestAnswer = _initialAnswer;
        latestTimestamp = block.timestamp;
        latestRoundId = 1;
    }

    function updateAnswer(int256 _answer) external {
        latestAnswer = _answer;
        latestTimestamp = block.timestamp;
        latestRoundId++;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (latestRoundId, latestAnswer, latestTimestamp, latestTimestamp, latestRoundId);
    }
}
