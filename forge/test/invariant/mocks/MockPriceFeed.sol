// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.15;

/// @notice Minimal Chainlink-style 8-decimal price feed with a settable answer.
contract MockPriceFeed {
    uint8 public constant decimals = 8;
    string public constant description = "MockPriceFeed";
    uint256 public constant version = 1;

    int256 public answer;
    uint80 public roundId = 1;

    constructor(int256 _initialAnswer) {
        answer = _initialAnswer;
    }

    function setAnswer(int256 _answer) external {
        answer = _answer;
        roundId++;
    }

    function latestRoundData()
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, answer, block.timestamp, block.timestamp, roundId);
    }
}
