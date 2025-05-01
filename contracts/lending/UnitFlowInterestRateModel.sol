// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./libraries/WadRayMath.sol";
import "./libraries/PercentageMath.sol";

/// @title UnitFlowInterestRateModel
/// @notice Two-slope interest rate model following Aave V3 conventions.
///         All rates are stored and returned in RAY (1e27).
///
///         Below optimal utilization:
///           borrowRate = baseRate + (utilization / optimalUtilization) * slope1
///
///         Above optimal utilization:
///           borrowRate = baseRate + slope1 + ((utilization - optimal) / (1 - optimal)) * slope2
///
///         Supply rate = borrowRate * utilization * (1 - reserveFactor)
contract UnitFlowInterestRateModel {
    using WadRayMath for uint256;
    using PercentageMath for uint256;

    // --- Constants ------------------------------------------------------------

    uint256 public constant RAY = WadRayMath.RAY;

    // --- Immutable parameters -------------------------------------------------

    /// @notice Optimal utilization ratio in RAY (80% = 0.8e27)
    uint256 public immutable OPTIMAL_UTILIZATION_RATE;

    /// @notice Excess utilization = 1 - optimal, in RAY
    uint256 public immutable EXCESS_UTILIZATION_RATE;

    /// @notice Base borrow rate at 0% utilization (in RAY)
    uint256 public immutable BASE_VARIABLE_BORROW_RATE;

    /// @notice Slope 1: rate increase per unit utilization below optimal (in RAY)
    uint256 public immutable VARIABLE_RATE_SLOPE1;

    /// @notice Slope 2: rate increase per unit utilization above optimal (in RAY)
    uint256 public immutable VARIABLE_RATE_SLOPE2;

    // --- Constructor ----------------------------------------------------------

    /// @param optimalUtilizationRate  Target utilization in RAY (e.g. 0.8e27 for 80%)
    /// @param baseVariableBorrowRate  Base rate in RAY (e.g. 0 for 0%)
    /// @param variableRateSlope1      Slope below optimal in RAY (e.g. 0.04e27 for 4%)
    /// @param variableRateSlope2      Slope above optimal in RAY (e.g. 0.75e27 for 75%)
    constructor(
        uint256 optimalUtilizationRate,
        uint256 baseVariableBorrowRate,
        uint256 variableRateSlope1,
        uint256 variableRateSlope2
    ) {
        require(optimalUtilizationRate < RAY, "IRM: optimal >= 100%");
        OPTIMAL_UTILIZATION_RATE  = optimalUtilizationRate;
        EXCESS_UTILIZATION_RATE   = RAY - optimalUtilizationRate;
        BASE_VARIABLE_BORROW_RATE = baseVariableBorrowRate;
        VARIABLE_RATE_SLOPE1      = variableRateSlope1;
        VARIABLE_RATE_SLOPE2      = variableRateSlope2;
    }

    // --- External view --------------------------------------------------------

    /// @notice Calculates the current variable borrow rate.
    /// @param utilizationRate Current utilization in RAY (totalBorrows / totalLiquidity)
    /// @return borrowRate Annual borrow rate in RAY
    function calculateBorrowRate(uint256 utilizationRate)
        external
        view
        returns (uint256 borrowRate)
    {
        if (utilizationRate <= OPTIMAL_UTILIZATION_RATE) {
            borrowRate =
                BASE_VARIABLE_BORROW_RATE +
                VARIABLE_RATE_SLOPE1.rayMul(
                    utilizationRate.rayDiv(OPTIMAL_UTILIZATION_RATE)
                );
        } else {
            // Excess utilization above optimal
            uint256 excessUtil = utilizationRate - OPTIMAL_UTILIZATION_RATE;
            borrowRate =
                BASE_VARIABLE_BORROW_RATE +
                VARIABLE_RATE_SLOPE1 +
                VARIABLE_RATE_SLOPE2.rayMul(
                    excessUtil.rayDiv(EXCESS_UTILIZATION_RATE)
                );
        }
    }

    /// @notice Calculates the current supply (deposit) rate.
    /// @param utilizationRate  Current utilization in RAY
    /// @param reserveFactor    Protocol reserve factor in basis points (e.g. 1000 = 10%)
    /// @return supplyRate Annual supply rate in RAY
    function calculateSupplyRate(uint256 utilizationRate, uint256 reserveFactor)
        external
        view
        returns (uint256 supplyRate)
    {
        uint256 borrowRate = this.calculateBorrowRate(utilizationRate);
        // supplyRate = borrowRate * utilization * (1 - reserveFactor)
        uint256 oneMinusReserveFactor = (PercentageMath.PERCENTAGE_FACTOR - reserveFactor) *
            (RAY / PercentageMath.PERCENTAGE_FACTOR);
        supplyRate = borrowRate.rayMul(utilizationRate).rayMul(oneMinusReserveFactor);
    }

    /// @notice Returns all rate model parameters for inspection.
    function getModelParameters()
        external
        view
        returns (
            uint256 optimalUtilization,
            uint256 baseRate,
            uint256 slope1,
            uint256 slope2
        )
    {
        return (
            OPTIMAL_UTILIZATION_RATE,
            BASE_VARIABLE_BORROW_RATE,
            VARIABLE_RATE_SLOPE1,
            VARIABLE_RATE_SLOPE2
        );
    }
}
