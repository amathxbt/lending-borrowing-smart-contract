// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./UnitFlowLendingPool.sol";

/// @title UnitFlowLiquidationEngine
/// @notice Permissionless liquidation entry point for UnitFlowLendingPool.
///
///         Liquidators call `liquidate()` here rather than directly on the pool.
///         This contract:
///           1. Validates the position is undercollateralised (health factor < 1)
///           2. Approves the pool to pull the debt repayment from the liquidator
///           3. Calls pool.liquidate() which transfers collateral to this contract
///           4. Forwards collateral to the liquidator
///
///         The 5% liquidation bonus and 50% close factor are enforced by the pool.
contract UnitFlowLiquidationEngine is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    UnitFlowLendingPool public pool;

    event LiquidationExecuted(
        address indexed liquidator,
        address indexed borrower,
        address collateralAsset,
        address debtAsset,
        uint256 debtCovered,
        uint256 collateralReceived
    );
    event PoolUpdated(address indexed newPool);

    constructor(address pool_, address owner_) Ownable(owner_) {
        require(pool_ != address(0), "LE: zero pool");
        pool = UnitFlowLendingPool(pool_);
    }

    function setPool(address pool_) external onlyOwner {
        require(pool_ != address(0), "LE: zero pool");
        pool = UnitFlowLendingPool(pool_);
        emit PoolUpdated(pool_);
    }

    // --- Core -----------------------------------------------------------------

    /// @notice Liquidates an undercollateralised borrower.
    ///
    ///         The caller must have approved this contract to spend at least
    ///         `debtToCover` of `debtAsset` before calling.
    ///
    /// @param borrower        Address of the undercollateralised borrower
    /// @param collateralAsset Asset to seize (must be a supported reserve)
    /// @param debtAsset       Asset to repay (must be a supported reserve)
    /// @param debtToCover     Amount of debt to repay (capped at 50% by pool)
    function liquidate(
        address borrower,
        address collateralAsset,
        address debtAsset,
        uint256 debtToCover
    ) external nonReentrant {
        require(debtToCover > 0, "LE: zero debt");

        // Validate health factor before pulling funds
        UnitFlowLendingPool.UserAccountData memory data = pool.getUserAccountData(borrower);
        require(data.healthFactor < 1e18, "LE: position healthy");

        // Pull debt from liquidator into this contract
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), debtToCover);

        // Approve pool to pull the debt repayment
        IERC20(debtAsset).forceApprove(address(pool), debtToCover);

        // Record collateral balance before liquidation
        uint256 collateralBefore = IERC20(collateralAsset).balanceOf(address(this));

        // Execute liquidation — pool pulls debtToCover, sends collateral here
        pool.liquidate(borrower, collateralAsset, debtAsset, debtToCover);

        // Forward all received collateral to the liquidator
        uint256 collateralReceived = IERC20(collateralAsset).balanceOf(address(this)) - collateralBefore;
        require(collateralReceived > 0, "LE: no collateral received");
        IERC20(collateralAsset).safeTransfer(msg.sender, collateralReceived);

        // Refund any unused debt approval (pool may have capped debtToCover)
        uint256 remaining = IERC20(debtAsset).balanceOf(address(this));
        if (remaining > 0) {
            IERC20(debtAsset).safeTransfer(msg.sender, remaining);
        }

        emit LiquidationExecuted(
            msg.sender,
            borrower,
            collateralAsset,
            debtAsset,
            debtToCover,
            collateralReceived
        );
    }

    // --- View -----------------------------------------------------------------

    /// @notice Returns the health factor for a borrower.
    ///         Convenience wrapper so liquidators can check before calling liquidate().
    function getHealthFactor(address borrower) external view returns (uint256) {
        return pool.getUserAccountData(borrower).healthFactor;
    }

    /// @notice Returns true if a borrower can be liquidated.
    function isLiquidatable(address borrower) external view returns (bool) {
        return pool.getUserAccountData(borrower).healthFactor < 1e18;
    }
}
