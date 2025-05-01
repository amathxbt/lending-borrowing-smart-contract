// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./libraries/WadRayMath.sol";

/// @title UnitFlowDebtToken
/// @notice Non-transferable variable debt tracking token.
///         Tracks borrowed principal + accrued interest per user via a borrow index.
///
///         scaledDebt = principal / borrowIndexAtBorrowTime
///         currentDebt = scaledDebt * currentBorrowIndex
///
///         Only the LendingPool can mint (on borrow) and burn (on repay/liquidation).
contract UnitFlowDebtToken is Ownable2Step {
    using WadRayMath for uint256;

    // --- State ----------------------------------------------------------------

    string  public name;
    string  public symbol;
    uint8   public constant decimals = 6;

    /// @notice The underlying asset (USDC or EURC)
    address public immutable UNDERLYING_ASSET;

    /// @notice The LendingPool ? only address allowed to mint/burn
    address public pool;

    /// @notice Scaled debt balances (debt / borrow index at borrow time)
    mapping(address => uint256) private _scaledBalances;

    /// @notice Total scaled debt supply
    uint256 private _totalScaledSupply;

    // --- Events ---------------------------------------------------------------

    event Mint(address indexed from, uint256 amount, uint256 index);
    event Burn(address indexed from, uint256 amount, uint256 index);
    event PoolUpdated(address indexed newPool);

    // --- Constructor ----------------------------------------------------------

    constructor(
        string memory name_,
        string memory symbol_,
        address underlyingAsset_,
        address owner_
    ) Ownable(owner_) {
        require(underlyingAsset_ != address(0), "DebtToken: zero underlying");
        name             = name_;
        symbol           = symbol_;
        UNDERLYING_ASSET = underlyingAsset_;
    }

    // --- Admin ----------------------------------------------------------------

    function setPool(address pool_) external onlyOwner {
        require(pool_ != address(0), "DebtToken: zero pool");
        pool = pool_;
        emit PoolUpdated(pool_);
    }

    // --- Pool-only ------------------------------------------------------------

    modifier onlyPool() {
        require(msg.sender == pool, "DebtToken: caller not pool");
        _;
    }

    /// @notice Mints debt tokens when a user borrows.
    /// @param onBehalfOf  The borrower
    /// @param amount      Amount borrowed in underlying decimals
    /// @param index       Current variable borrow index in RAY
    function mint(
        address onBehalfOf,
        uint256 amount,
        uint256 index
    ) external onlyPool {
        require(amount != 0, "DebtToken: zero amount");
        uint256 scaledAmount = amount.rayDiv(index);
        _scaledBalances[onBehalfOf] += scaledAmount;
        _totalScaledSupply          += scaledAmount;
        emit Mint(onBehalfOf, amount, index);
    }

    /// @notice Burns debt tokens when a user repays.
    /// @param from    The borrower repaying
    /// @param amount  Amount repaid in underlying decimals
    /// @param index   Current variable borrow index in RAY
    function burn(
        address from,
        uint256 amount,
        uint256 index
    ) external onlyPool {
        require(amount != 0, "DebtToken: zero amount");
        uint256 scaledAmount = amount.rayDiv(index);
        // Cap to avoid underflow on full repay with rounding
        if (scaledAmount > _scaledBalances[from]) {
            scaledAmount = _scaledBalances[from];
        }
        _scaledBalances[from]  -= scaledAmount;
        _totalScaledSupply     -= scaledAmount;
        emit Burn(from, amount, index);
    }

    // --- View -----------------------------------------------------------------

    /// @notice Returns the current debt including accrued interest.
    function balanceOf(address account, uint256 index) external view returns (uint256) {
        return _scaledBalances[account].rayMul(index);
    }

    /// @notice Returns the scaled (principal-only) debt balance.
    function scaledBalanceOf(address account) external view returns (uint256) {
        return _scaledBalances[account];
    }

    function scaledTotalSupply() external view returns (uint256) {
        return _totalScaledSupply;
    }

    function totalSupply(uint256 index) external view returns (uint256) {
        return _totalScaledSupply.rayMul(index);
    }
}
