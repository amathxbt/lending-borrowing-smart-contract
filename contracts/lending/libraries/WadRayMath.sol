// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title WadRayMath
/// @notice Fixed-point arithmetic library ported from Aave V3.
///         WAD  = 1e18  (18-decimal fixed point)
///         RAY  = 1e27  (27-decimal fixed point, used for interest rates)
///         HALF_WAD / HALF_RAY used for rounding
library WadRayMath {
    uint256 internal constant WAD      = 1e18;
    uint256 internal constant HALF_WAD = 0.5e18;
    uint256 internal constant RAY      = 1e27;
    uint256 internal constant HALF_RAY = 0.5e27;
    uint256 internal constant WAD_RAY_RATIO = 1e9;

    /// @notice Multiplies two WAD numbers, rounding half up.
    function wadMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b + HALF_WAD) / WAD;
    }

    /// @notice Divides two WAD numbers, rounding half up.
    function wadDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * WAD + b / 2) / b;
    }

    /// @notice Multiplies two RAY numbers, rounding half up.
    function rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0 || b == 0) return 0;
        return (a * b + HALF_RAY) / RAY;
    }

    /// @notice Divides two RAY numbers, rounding half up.
    function rayDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a * RAY + b / 2) / b;
    }

    /// @notice Converts a RAY to WAD, rounding half up.
    function rayToWad(uint256 a) internal pure returns (uint256) {
        return (a + WAD_RAY_RATIO / 2) / WAD_RAY_RATIO;
    }

    /// @notice Converts a WAD to RAY.
    function wadToRay(uint256 a) internal pure returns (uint256) {
        return a * WAD_RAY_RATIO;
    }
}
