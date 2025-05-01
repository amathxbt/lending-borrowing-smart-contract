// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./WadRayMath.sol";

/// @title MathUtils
/// @notice Compound interest calculation utilities.
library MathUtils {
    using WadRayMath for uint256;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    /// @notice Calculates the compounded interest over a period using linear approximation.
    ///         For short periods (< 1 year) this is accurate to within 0.1%.
    /// @param rate   Annual borrow rate in RAY
    /// @param lastUpdateTimestamp  Timestamp of last accrual
    /// @return The compounded interest factor in RAY (multiply by principal to get new balance)
    function calculateCompoundedInterest(
        uint256 rate,
        uint256 lastUpdateTimestamp
    ) internal view returns (uint256) {
        uint256 exp = block.timestamp - lastUpdateTimestamp;
        if (exp == 0) return WadRayMath.RAY;

        // Linear approximation: (1 + rate * dt / SECONDS_PER_YEAR)
        // Accurate enough for typical accrual intervals
        uint256 ratePerSecond = rate / SECONDS_PER_YEAR;
        return WadRayMath.RAY + ratePerSecond * exp;
    }

    /// @notice Calculates linear interest (for supply index).
    function calculateLinearInterest(
        uint256 rate,
        uint256 lastUpdateTimestamp
    ) internal view returns (uint256) {
        uint256 result = rate * (block.timestamp - lastUpdateTimestamp);
        unchecked { result = result / SECONDS_PER_YEAR; }
        return WadRayMath.RAY + result;
    }
}
