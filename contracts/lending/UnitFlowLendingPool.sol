// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./libraries/WadRayMath.sol";
import "./libraries/PercentageMath.sol";
import "./libraries/MathUtils.sol";
import "./UnitFlowUToken.sol";
import "./UnitFlowDebtToken.sol";
import "./UnitFlowInterestRateModel.sol";
import "./UnitFlowPriceOracle.sol";

/// @title UnitFlowLendingPool
/// @notice Core lending and borrowing contract for USDC and EURC on Arc Testnet.
///         Inspired by Aave V3 with a stablecoin-first design.
///
///         Key mechanics:
///         - Supply: deposit USDC/EURC, receive uTokens (interest-bearing)
///         - Borrow: lock collateral, borrow up to LTV limit
///         - Repay: repay debt + accrued interest
///         - Withdraw: burn uTokens, receive underlying + interest
///         - Liquidate: repay undercollateralised debt, seize collateral + bonus
///
///         Collateralisation:
///         - Minimum collateral ratio: 150% (LTV = 66.67%)
///         - Liquidation threshold: health factor < 1.0
///         - Liquidation bonus: 5% (paid to liquidator)
contract UnitFlowLendingPool is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20     for IERC20;
    using WadRayMath    for uint256;
    using PercentageMath for uint256;
    using MathUtils     for uint256;

    // --- Constants ------------------------------------------------------------

    uint256 public constant RAY                    = WadRayMath.RAY;
    uint256 public constant WAD                    = WadRayMath.WAD;
    /// @notice Minimum collateral ratio in basis points (150% = 15000)
    uint256 public constant MIN_COLLATERAL_RATIO   = 15_000;
    /// @notice LTV in basis points (66.67% ? 6667)
    uint256 public constant MAX_LTV_BPS            = 6_667;
    /// @notice Liquidation threshold: health factor below 1.0 triggers liquidation
    uint256 public constant LIQUIDATION_THRESHOLD  = WAD; // 1e18
    /// @notice Liquidation bonus for liquidators (5% = 500 bps)
    uint256 public constant LIQUIDATION_BONUS_BPS  = 500;
    /// @notice Maximum fraction of debt that can be liquidated in one call (50%)
    uint256 public constant CLOSE_FACTOR_BPS       = 5_000;
    /// @notice Protocol reserve factor (10% of interest goes to reserves)
    uint256 public constant RESERVE_FACTOR_BPS     = 1_000;

    // --- Types ----------------------------------------------------------------

    struct ReserveData {
        // Tokens
        address uToken;          // Interest-bearing supply token
        address debtToken;       // Variable debt token
        address underlyingAsset;

        // Indices (RAY)
        uint256 liquidityIndex;       // Cumulative supply interest index
        uint256 variableBorrowIndex;  // Cumulative borrow interest index
        uint256 currentLiquidityRate; // Current supply APR (RAY)
        uint256 currentBorrowRate;    // Current borrow APR (RAY)

        // Accounting
        uint256 totalLiquidity;  // Total underlying supplied (including interest)
        uint256 totalBorrows;    // Total outstanding borrows (including interest)
        uint256 reserveBalance;  // Accumulated protocol reserves

        uint256 lastUpdateTimestamp;
        bool    active;
        bool    borrowingEnabled;
    }

    struct UserAccountData {
        uint256 totalCollateralUSD;  // 8-decimal USD value of all collateral
        uint256 totalDebtUSD;        // 8-decimal USD value of all debt
        uint256 healthFactor;        // WAD-scaled (1e18 = healthy threshold)
        uint256 availableBorrowsUSD; // How much more the user can borrow
    }

    // --- State ----------------------------------------------------------------

    /// @notice Supported reserve assets
    address[] public reserveList;
    mapping(address => ReserveData) public reserves;

    /// @notice user ? asset ? collateral amount deposited
    mapping(address => mapping(address => uint256)) public userCollateral;

    /// @notice External contracts
    UnitFlowPriceOracle    public oracle;
    UnitFlowInterestRateModel public interestRateModel;
    address                public feeDistributor;
    address                public liquidationEngine;

    // --- Events ---------------------------------------------------------------

    event Supply(address indexed asset, address indexed user, uint256 amount, uint256 index);
    event Withdraw(address indexed asset, address indexed user, uint256 amount, uint256 index);
    event Borrow(address indexed asset, address indexed user, uint256 amount, uint256 borrowRate, uint256 index);
    event Repay(address indexed asset, address indexed user, address indexed repayer, uint256 amount, uint256 index);
    event WithdrawCollateral(address indexed asset, address indexed user, uint256 amount);
    event Liquidate(
        address indexed collateralAsset,
        address indexed debtAsset,
        address indexed borrower,
        uint256 debtCovered,
        uint256 collateralSeized,
        address liquidator
    );
    event ReserveAdded(address indexed asset, address uToken, address debtToken);
    event ReserveUpdated(address indexed asset, uint256 liquidityRate, uint256 borrowRate, uint256 liquidityIndex, uint256 borrowIndex);
    event OracleUpdated(address indexed newOracle);
    event InterestRateModelUpdated(address indexed newModel);
    event FeeDistributorUpdated(address indexed newDistributor);
    event LiquidationEngineUpdated(address indexed newEngine);

    // --- Constructor ----------------------------------------------------------

    constructor(
        address oracle_,
        address interestRateModel_,
        address feeDistributor_,
        address liquidationEngine_,
        address owner_
    ) Ownable(owner_) {
        require(oracle_             != address(0), "Pool: zero oracle");
        require(interestRateModel_  != address(0), "Pool: zero IRM");
        require(feeDistributor_     != address(0), "Pool: zero fee distributor");
        require(liquidationEngine_  != address(0), "Pool: zero liquidation engine");
        oracle            = UnitFlowPriceOracle(oracle_);
        interestRateModel = UnitFlowInterestRateModel(interestRateModel_);
        feeDistributor    = feeDistributor_;
        liquidationEngine = liquidationEngine_;
    }

    // --- Admin ----------------------------------------------------------------

    /// @notice Adds a new reserve (USDC or EURC).
    function addReserve(
        address asset,
        address uToken_,
        address debtToken_
    ) external onlyOwner {
        require(asset     != address(0), "Pool: zero asset");
        require(uToken_   != address(0), "Pool: zero uToken");
        require(debtToken_ != address(0), "Pool: zero debtToken");
        require(!reserves[asset].active, "Pool: reserve exists");

        reserves[asset] = ReserveData({
            uToken:               uToken_,
            debtToken:            debtToken_,
            underlyingAsset:      asset,
            liquidityIndex:       RAY,
            variableBorrowIndex:  RAY,
            currentLiquidityRate: 0,
            currentBorrowRate:    0,
            totalLiquidity:       0,
            totalBorrows:         0,
            reserveBalance:       0,
            lastUpdateTimestamp:  block.timestamp,
            active:               true,
            borrowingEnabled:     true
        });
        reserveList.push(asset);
        emit ReserveAdded(asset, uToken_, debtToken_);
    }

    function setOracle(address oracle_) external onlyOwner {
        require(oracle_ != address(0), "Pool: zero oracle");
        oracle = UnitFlowPriceOracle(oracle_);
        emit OracleUpdated(oracle_);
    }

    function setInterestRateModel(address irm_) external onlyOwner {
        require(irm_ != address(0), "Pool: zero IRM");
        interestRateModel = UnitFlowInterestRateModel(irm_);
        emit InterestRateModelUpdated(irm_);
    }

    function setFeeDistributor(address fd_) external onlyOwner {
        require(fd_ != address(0), "Pool: zero fee distributor");
        feeDistributor = fd_;
        emit FeeDistributorUpdated(fd_);
    }

    function setLiquidationEngine(address le_) external onlyOwner {
        require(le_ != address(0), "Pool: zero liquidation engine");
        liquidationEngine = le_;
        emit LiquidationEngineUpdated(le_);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // --- Core: Supply ---------------------------------------------------------

    /// @notice Supplies `amount` of `asset` to the pool.
    ///         Mints uTokens to `onBehalfOf` representing their share.
    /// @param asset        USDC or EURC address
    /// @param amount       Amount to supply (in asset decimals)
    /// @param onBehalfOf   Address that receives the uTokens
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) external nonReentrant whenNotPaused {
        require(amount > 0, "Pool: zero amount");
        ReserveData storage reserve = _getActiveReserve(asset);

        // -- Checks-Effects-Interactions ---------------------------------------
        _updateReserveState(reserve, asset);

        reserve.totalLiquidity += amount;
        userCollateral[onBehalfOf][asset] += amount;

        UnitFlowUToken(reserve.uToken).mint(onBehalfOf, amount, reserve.liquidityIndex);

        _updateInterestRates(reserve, asset, amount, 0);

        // Interactions last
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        emit Supply(asset, onBehalfOf, amount, reserve.liquidityIndex);
    }

    // --- Core: Withdraw -------------------------------------------------------

    /// @notice Withdraws `amount` of `asset` from the pool, burning uTokens.
    /// @param asset    Asset to withdraw
    /// @param amount   Amount to withdraw (use type(uint256).max for full balance)
    /// @param to       Address that receives the underlying
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external nonReentrant whenNotPaused returns (uint256) {
        ReserveData storage reserve = _getActiveReserve(asset);
        _updateReserveState(reserve, asset);

        uint256 userBalance = UnitFlowUToken(reserve.uToken)
            .balanceOfWithIndex(msg.sender, reserve.liquidityIndex);

        uint256 amountToWithdraw = amount == type(uint256).max ? userBalance : amount;
        require(amountToWithdraw > 0,              "Pool: zero withdraw");
        require(amountToWithdraw <= userBalance,   "Pool: exceeds balance");
        require(amountToWithdraw <= reserve.totalLiquidity - reserve.totalBorrows,
                                                   "Pool: insufficient liquidity");

        // -- Effects -----------------------------------------------------------
        reserve.totalLiquidity -= amountToWithdraw;
        userCollateral[msg.sender][asset] = userCollateral[msg.sender][asset] > amountToWithdraw
            ? userCollateral[msg.sender][asset] - amountToWithdraw
            : 0;

        UnitFlowUToken(reserve.uToken).burn(msg.sender, amountToWithdraw, reserve.liquidityIndex);
        _updateInterestRates(reserve, asset, 0, amountToWithdraw);

        // Validate health factor after withdrawal
        _requireHealthy(msg.sender);

        // -- Interactions ------------------------------------------------------
        IERC20(asset).safeTransfer(to, amountToWithdraw);

        emit Withdraw(asset, msg.sender, amountToWithdraw, reserve.liquidityIndex);
        return amountToWithdraw;
    }

    // --- Core: Borrow ---------------------------------------------------------

    /// @notice Borrows `amount` of `asset` against existing collateral.
    /// @param asset        Asset to borrow
    /// @param amount       Amount to borrow
    /// @param onBehalfOf   Address that incurs the debt
    function borrow(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) external nonReentrant whenNotPaused {
        require(amount > 0, "Pool: zero amount");
        ReserveData storage reserve = _getActiveReserve(asset);
        require(reserve.borrowingEnabled, "Pool: borrowing disabled");

        _updateReserveState(reserve, asset);

        // -- Checks ------------------------------------------------------------
        require(
            reserve.totalLiquidity - reserve.totalBorrows >= amount,
            "Pool: insufficient liquidity"
        );

        // Validate LTV before borrow
        _requireBorrowAllowed(onBehalfOf, asset, amount);

        // -- Effects -----------------------------------------------------------
        reserve.totalBorrows += amount;

        UnitFlowDebtToken(reserve.debtToken).mint(
            onBehalfOf,
            amount,
            reserve.variableBorrowIndex
        );

        _updateInterestRates(reserve, asset, 0, amount);

        // -- Interactions ------------------------------------------------------
        IERC20(asset).safeTransfer(onBehalfOf, amount);

        emit Borrow(asset, onBehalfOf, amount, reserve.currentBorrowRate, reserve.variableBorrowIndex);
    }

    // --- Core: Repay ----------------------------------------------------------

    /// @notice Repays `amount` of debt for `onBehalfOf`.
    /// @param asset        Asset to repay
    /// @param amount       Amount to repay (use type(uint256).max for full debt)
    /// @param onBehalfOf   Borrower whose debt is being repaid
    function repay(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) external nonReentrant whenNotPaused returns (uint256) {
        ReserveData storage reserve = _getActiveReserve(asset);
        _updateReserveState(reserve, asset);

        uint256 currentDebt = UnitFlowDebtToken(reserve.debtToken)
            .balanceOf(onBehalfOf, reserve.variableBorrowIndex);
        require(currentDebt > 0, "Pool: no debt");

        uint256 amountToRepay = amount == type(uint256).max ? currentDebt : amount;
        if (amountToRepay > currentDebt) amountToRepay = currentDebt;

        // -- Effects -----------------------------------------------------------
        reserve.totalBorrows = reserve.totalBorrows > amountToRepay
            ? reserve.totalBorrows - amountToRepay
            : 0;

        UnitFlowDebtToken(reserve.debtToken).burn(
            onBehalfOf,
            amountToRepay,
            reserve.variableBorrowIndex
        );

        _updateInterestRates(reserve, asset, amountToRepay, 0);

        // -- Interactions ------------------------------------------------------
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amountToRepay);

        emit Repay(asset, onBehalfOf, msg.sender, amountToRepay, reserve.variableBorrowIndex);
        return amountToRepay;
    }

    // --- Core: Liquidate ------------------------------------------------------

    /// @notice Liquidates an undercollateralised position.
    ///         Called by LiquidationEngine or directly by liquidators.
    /// @param borrower         Address of the undercollateralised borrower
    /// @param collateralAsset  Asset to seize as collateral
    /// @param debtAsset        Asset to repay
    /// @param debtToCover      Amount of debt to repay (max 50% of total debt)
    function liquidate(
        address borrower,
        address collateralAsset,
        address debtAsset,
        uint256 debtToCover
    ) external nonReentrant whenNotPaused {
        require(
            msg.sender == liquidationEngine || msg.sender == owner(),
            "Pool: not liquidation engine"
        );

        ReserveData storage debtReserve       = _getActiveReserve(debtAsset);
        ReserveData storage collateralReserve = _getActiveReserve(collateralAsset);

        _updateReserveState(debtReserve, debtAsset);
        _updateReserveState(collateralReserve, collateralAsset);

        // -- Checks ------------------------------------------------------------
        UserAccountData memory accountData = getUserAccountData(borrower);
        require(accountData.healthFactor < LIQUIDATION_THRESHOLD, "Pool: position healthy");

        uint256 totalDebt = UnitFlowDebtToken(debtReserve.debtToken)
            .balanceOf(borrower, debtReserve.variableBorrowIndex);
        uint256 maxDebtToCover = totalDebt.percentMul(CLOSE_FACTOR_BPS);
        if (debtToCover > maxDebtToCover) debtToCover = maxDebtToCover;

        // Calculate collateral to seize (debt value + 5% bonus)
        uint256 collateralToSeize = _calculateCollateralToSeize(
            debtAsset,
            collateralAsset,
            debtToCover
        );

        uint256 availableCollateral = userCollateral[borrower][collateralAsset];
        if (collateralToSeize > availableCollateral) {
            collateralToSeize = availableCollateral;
            // Recalculate debt to cover based on available collateral
            debtToCover = _calculateDebtFromCollateral(
                collateralAsset,
                debtAsset,
                collateralToSeize
            );
        }

        // -- Effects -----------------------------------------------------------
        // Reduce borrower's collateral
        userCollateral[borrower][collateralAsset] -= collateralToSeize;
        collateralReserve.totalLiquidity          -= collateralToSeize;

        // Burn debt tokens
        debtReserve.totalBorrows = debtReserve.totalBorrows > debtToCover
            ? debtReserve.totalBorrows - debtToCover
            : 0;
        UnitFlowDebtToken(debtReserve.debtToken).burn(
            borrower,
            debtToCover,
            debtReserve.variableBorrowIndex
        );

        _updateInterestRates(debtReserve, debtAsset, debtToCover, 0);
        _updateInterestRates(collateralReserve, collateralAsset, 0, collateralToSeize);

        // -- Interactions ------------------------------------------------------
        // Liquidator pays debt
        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), debtToCover);
        // Liquidator receives collateral + bonus
        IERC20(collateralAsset).safeTransfer(msg.sender, collateralToSeize);

        emit Liquidate(collateralAsset, debtAsset, borrower, debtToCover, collateralToSeize, msg.sender);
    }

    // --- View: Account data ---------------------------------------------------

    /// @notice Returns the full account health summary for a user.
    function getUserAccountData(address user)
        public
        view
        returns (UserAccountData memory data)
    {
        for (uint256 i = 0; i < reserveList.length; i++) {
            address asset = reserveList[i];
            ReserveData storage reserve = reserves[asset];
            if (!reserve.active) continue;

            uint256 price = oracle.getAssetPrice(asset); // 8 decimals

            // Collateral value
            uint256 collateral = userCollateral[user][asset];
            if (collateral > 0) {
                // Convert 6-decimal token amount to 8-decimal USD
                data.totalCollateralUSD += (collateral * price) / 1e6;
            }

            // Debt value
            uint256 debt = UnitFlowDebtToken(reserve.debtToken)
                .balanceOf(user, reserve.variableBorrowIndex);
            if (debt > 0) {
                data.totalDebtUSD += (debt * price) / 1e6;
            }
        }

        if (data.totalDebtUSD == 0) {
            data.healthFactor = type(uint256).max;
        } else {
            // healthFactor = (collateral * liquidationThreshold) / debt
            // liquidationThreshold = 1/1.5 = 66.67% ? use MAX_LTV_BPS
            uint256 collateralAtThreshold = data.totalCollateralUSD.percentMul(MAX_LTV_BPS);
            data.healthFactor = (collateralAtThreshold * WAD) / data.totalDebtUSD;
        }

        // Available borrows = collateral * LTV - existing debt
        uint256 maxBorrow = data.totalCollateralUSD.percentMul(MAX_LTV_BPS);
        data.availableBorrowsUSD = maxBorrow > data.totalDebtUSD
            ? maxBorrow - data.totalDebtUSD
            : 0;
    }

    /// @notice Returns the current utilization rate for a reserve in RAY.
    function getUtilizationRate(address asset) public view returns (uint256) {
        ReserveData storage reserve = reserves[asset];
        if (reserve.totalLiquidity == 0) return 0;
        return reserve.totalBorrows.rayDiv(reserve.totalLiquidity);
    }

    /// @notice Returns the number of supported reserves.
    function getReserveCount() external view returns (uint256) {
        return reserveList.length;
    }

    // --- Internal: Interest accrual -------------------------------------------

    /// @dev Updates the liquidity and borrow indices for a reserve.
    function _updateReserveState(ReserveData storage reserve, address /*asset*/) internal {
        if (reserve.lastUpdateTimestamp == block.timestamp) return;

        uint256 liquidityFactor = MathUtils.calculateLinearInterest(
            reserve.currentLiquidityRate,
            reserve.lastUpdateTimestamp
        );
        uint256 borrowFactor = MathUtils.calculateCompoundedInterest(
            reserve.currentBorrowRate,
            reserve.lastUpdateTimestamp
        );

        uint256 prevBorrowIndex = reserve.variableBorrowIndex;
        reserve.liquidityIndex      = reserve.liquidityIndex.rayMul(liquidityFactor);
        reserve.variableBorrowIndex = reserve.variableBorrowIndex.rayMul(borrowFactor);

        // Accrue interest to reserves (reserve factor portion)
        if (reserve.totalBorrows > 0) {
            uint256 interestAccrued = reserve.totalBorrows.rayMul(borrowFactor) - reserve.totalBorrows;
            uint256 toReserve = interestAccrued.percentMul(RESERVE_FACTOR_BPS);
            reserve.reserveBalance  += toReserve;
            reserve.totalLiquidity  += interestAccrued - toReserve;
            reserve.totalBorrows    = reserve.totalBorrows.rayMul(
                reserve.variableBorrowIndex.rayDiv(prevBorrowIndex)
            );
        }

        reserve.lastUpdateTimestamp = block.timestamp;
    }

    /// @dev Recalculates and stores current borrow and supply rates.
    function _updateInterestRates(
        ReserveData storage reserve,
        address asset,
        uint256 liquidityAdded,
        uint256 liquidityTaken
    ) internal {
        uint256 availableLiquidity = IERC20(asset).balanceOf(address(this))
            + liquidityAdded
            - liquidityTaken;

        uint256 totalLiq = availableLiquidity + reserve.totalBorrows;
        uint256 utilization = totalLiq == 0 ? 0 : reserve.totalBorrows.rayDiv(totalLiq);

        reserve.currentBorrowRate    = interestRateModel.calculateBorrowRate(utilization);
        reserve.currentLiquidityRate = interestRateModel.calculateSupplyRate(
            utilization,
            RESERVE_FACTOR_BPS
        );

        emit ReserveUpdated(
            asset,
            reserve.currentLiquidityRate,
            reserve.currentBorrowRate,
            reserve.liquidityIndex,
            reserve.variableBorrowIndex
        );
    }

    // --- Internal: Validation -------------------------------------------------

    function _getActiveReserve(address asset) internal view returns (ReserveData storage) {
        ReserveData storage reserve = reserves[asset];
        require(reserve.active, "Pool: reserve not active");
        return reserve;
    }

    /// @dev Reverts if the user's health factor would drop below 1.0 after an action.
    function _requireHealthy(address user) internal view {
        UserAccountData memory data = getUserAccountData(user);
        require(data.healthFactor >= LIQUIDATION_THRESHOLD, "Pool: health factor too low");
    }

    /// @dev Reverts if borrowing `amount` of `asset` would breach LTV.
    function _requireBorrowAllowed(address user, address asset, uint256 amount) internal view {
        uint256 price = oracle.getAssetPrice(asset);
        uint256 borrowValueUSD = (amount * price) / 1e6;

        UserAccountData memory data = getUserAccountData(user);
        require(
            borrowValueUSD <= data.availableBorrowsUSD,
            "Pool: borrow exceeds LTV"
        );
    }

    /// @dev Calculates collateral to seize for a given debt amount (includes 5% bonus).
    function _calculateCollateralToSeize(
        address debtAsset,
        address collateralAsset,
        uint256 debtAmount
    ) internal view returns (uint256) {
        uint256 debtPrice       = oracle.getAssetPrice(debtAsset);
        uint256 collateralPrice = oracle.getAssetPrice(collateralAsset);

        // debtValueUSD = debtAmount * debtPrice / 1e6
        // collateralToSeize = debtValueUSD * (1 + bonus) / collateralPrice * 1e6
        uint256 debtValueUSD = (debtAmount * debtPrice) / 1e6;
        uint256 withBonus    = debtValueUSD.percentMul(
            PercentageMath.PERCENTAGE_FACTOR + LIQUIDATION_BONUS_BPS
        );
        return (withBonus * 1e6) / collateralPrice;
    }

    /// @dev Inverse of _calculateCollateralToSeize ? used when collateral is capped.
    function _calculateDebtFromCollateral(
        address collateralAsset,
        address debtAsset,
        uint256 collateralAmount
    ) internal view returns (uint256) {
        uint256 collateralPrice = oracle.getAssetPrice(collateralAsset);
        uint256 debtPrice       = oracle.getAssetPrice(debtAsset);

        uint256 collateralValueUSD = (collateralAmount * collateralPrice) / 1e6;
        uint256 debtValueUSD = collateralValueUSD.percentMul(
            PercentageMath.PERCENTAGE_FACTOR * PercentageMath.PERCENTAGE_FACTOR /
            (PercentageMath.PERCENTAGE_FACTOR + LIQUIDATION_BONUS_BPS)
        );
        return (debtValueUSD * 1e6) / debtPrice;
    }
}
