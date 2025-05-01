// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "./libraries/WadRayMath.sol";

/// @title UnitFlowUToken
/// @notice Interest-bearing receipt token minted 1:1 on supply.
///         Balances accrue interest over time via a rebasing liquidity index.
///         Only the LendingPool (set as `pool`) can mint and burn.
///
///         scaledBalance = rawBalance / liquidityIndex
///         actualBalance = scaledBalance * currentLiquidityIndex
///
///         This means as the index grows, every holder's balance grows proportionally.
contract UnitFlowUToken is ERC20, Ownable2Step {
    using WadRayMath for uint256;

    // --- State ----------------------------------------------------------------

    /// @notice The underlying asset (USDC or EURC)
    address public immutable UNDERLYING_ASSET;

    /// @notice The LendingPool ? only address allowed to mint/burn
    address public pool;

    /// @notice Scaled balances (balance / index at mint time)
    mapping(address => uint256) private _scaledBalances;

    /// @notice Total scaled supply
    uint256 private _totalScaledSupply;

    // --- Events ---------------------------------------------------------------

    event Mint(address indexed caller, address indexed onBehalfOf, uint256 amount, uint256 index);
    event Burn(address indexed from, address indexed target, uint256 amount, uint256 index);
    event PoolUpdated(address indexed newPool);

    // --- Constructor ----------------------------------------------------------

    /// @param name_            Token name (e.g. "UnitFlow USDC")
    /// @param symbol_          Token symbol (e.g. "uUSDC")
    /// @param underlyingAsset_ The underlying ERC-20 (USDC or EURC)
    /// @param owner_           Initial owner (LendingConfigurator / deployer)
    constructor(
        string memory name_,
        string memory symbol_,
        address underlyingAsset_,
        address owner_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        require(underlyingAsset_ != address(0), "UToken: zero underlying");
        UNDERLYING_ASSET = underlyingAsset_;
    }

    // --- Admin ----------------------------------------------------------------

    /// @notice Sets the LendingPool address. Can only be called once by owner.
    function setPool(address pool_) external onlyOwner {
        require(pool_ != address(0), "UToken: zero pool");
        pool = pool_;
        emit PoolUpdated(pool_);
    }

    // --- Pool-only ------------------------------------------------------------

    modifier onlyPool() {
        require(msg.sender == pool, "UToken: caller not pool");
        _;
    }

    /// @notice Mints uTokens to `onBehalfOf` when they supply `amount` of underlying.
    /// @param onBehalfOf   Recipient of the uTokens
    /// @param amount       Amount of underlying supplied (in underlying decimals)
    /// @param index        Current liquidity index in RAY
    function mint(
        address onBehalfOf,
        uint256 amount,
        uint256 index
    ) external onlyPool {
        require(amount != 0, "UToken: zero amount");
        uint256 scaledAmount = amount.rayDiv(index);
        _scaledBalances[onBehalfOf] += scaledAmount;
        _totalScaledSupply          += scaledAmount;
        emit Mint(msg.sender, onBehalfOf, amount, index);
        // Emit ERC-20 Transfer for indexers
        emit Transfer(address(0), onBehalfOf, amount);
    }

    /// @notice Burns uTokens from `from` when they withdraw `amount` of underlying.
    /// @param from     Address whose uTokens are burned
    /// @param amount   Amount of underlying withdrawn
    /// @param index    Current liquidity index in RAY
    function burn(
        address from,
        uint256 amount,
        uint256 index
    ) external onlyPool {
        require(amount != 0, "UToken: zero amount");
        uint256 scaledAmount = amount.rayDiv(index);
        require(_scaledBalances[from] >= scaledAmount, "UToken: burn exceeds balance");
        _scaledBalances[from]  -= scaledAmount;
        _totalScaledSupply     -= scaledAmount;
        emit Burn(from, from, amount, index);
        emit Transfer(from, address(0), amount);
    }

    // --- ERC-20 overrides -----------------------------------------------------

    /// @notice Returns the actual balance including accrued interest.
    ///         Requires the pool to provide the current index via `balanceOfWithIndex`.
    ///         Standard `balanceOf` returns scaled balance (use `balanceOfWithIndex` for UI).
    function balanceOf(address account) public view override returns (uint256) {
        return _scaledBalances[account];
    }

    /// @notice Returns the actual balance at a given liquidity index.
    function balanceOfWithIndex(address account, uint256 index) external view returns (uint256) {
        return _scaledBalances[account].rayMul(index);
    }

    /// @notice Returns the scaled balance (principal without interest).
    function scaledBalanceOf(address account) external view returns (uint256) {
        return _scaledBalances[account];
    }

    function totalSupply() public view override returns (uint256) {
        return _totalScaledSupply;
    }

    function scaledTotalSupply() external view returns (uint256) {
        return _totalScaledSupply;
    }

    /// @dev Transfers are disabled ? uTokens are non-transferable.
    function transfer(address, uint256) public pure override returns (bool) {
        revert("UToken: non-transferable");
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("UToken: non-transferable");
    }

    function approve(address, uint256) public pure override returns (bool) {
        revert("UToken: non-transferable");
    }
}
