// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PercentageMath
/// @notice Percentage arithmetic in basis points (1 = 0.01%, 10000 = 100%).
library PercentageMath {
    uint256 internal constant PERCENTAGE_FACTOR = 1e4; // 100.00%
    uint256 internal constant HALF_PERCENTAGE    = 0.5e4;

    /// @notice Executes a percentage multiplication, rounding half up.
    /// @param value The value to multiply
    /// @param percentage Percentage in basis points (e.g. 1500 = 15%)
    function percentMul(uint256 value, uint256 percentage) internal pure returns (uint256) {
        if (value == 0 || percentage == 0) return 0;
        return (value * percentage + HALF_PERCENTAGE) / PERCENTAGE_FACTOR;
    }

    /// @notice Executes a percentage division, rounding half up.
    function percentDiv(uint256 value, uint256 percentage) internal pure returns (uint256) {
        return (value * PERCENTAGE_FACTOR + percentage / 2) / percentage;
    }
}
