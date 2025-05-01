// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title UnitFlowFeeDistributor
/// @notice Receives protocol reserve fees from the LendingPool and splits them
///         across three destinations:
///
///           - LP_SHARE (60%)  : returned to liquidity providers via the pool
///           - TREASURY_SHARE (20%) : sent to the treasury address
///           - STAKER_SHARE (20%)   : held in pendingStakerReserve until a
///                                    staking contract is deployed, then forwarded
///
///         Shares are expressed in basis points (10000 = 100%).
///         The owner can update the treasury address and, once a staking contract
///         is live, register it to receive the staker reserve.
contract UnitFlowFeeDistributor is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Constants ------------------------------------------------------------

    uint256 public constant PERCENTAGE_FACTOR = 10_000; // 100% in bps

    uint256 public constant LP_SHARE       = 6_000; // 60%
    uint256 public constant TREASURY_SHARE = 2_000; // 20%
    uint256 public constant STAKER_SHARE   = 2_000; // 20%

    // --- State ----------------------------------------------------------------

    address public treasury;
    address public stakingContract; // address(0) until staking is deployed
    address public lendingPool;

    /// @notice Accumulated staker fees not yet forwarded (staking contract not set)
    mapping(address => uint256) public pendingStakerReserve;

    // --- Events ---------------------------------------------------------------

    event FeesDistributed(
        address indexed asset,
        uint256 totalAmount,
        uint256 toLPs,
        uint256 toTreasury,
        uint256 toStakers
    );
    event StakerReserveForwarded(address indexed asset, uint256 amount, address stakingContract);
    event TreasuryUpdated(address indexed newTreasury);
    event StakingContractUpdated(address indexed newStaking);
    event LendingPoolUpdated(address indexed newPool);

    // --- Constructor ----------------------------------------------------------

    constructor(
        address treasury_,
        address lendingPool_,
        address owner_
    ) Ownable(owner_) {
        require(treasury_ != address(0), "FD: zero treasury");
        // lendingPool_ may be address(0) at deploy time; set via setLendingPool()
        treasury    = treasury_;
        lendingPool = lendingPool_;
    }

    // --- Admin ----------------------------------------------------------------

    function setTreasury(address treasury_) external onlyOwner {
        require(treasury_ != address(0), "FD: zero treasury");
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setStakingContract(address staking_) external onlyOwner {
        require(staking_ != address(0), "FD: zero staking");
        stakingContract = staking_;
        emit StakingContractUpdated(staking_);
    }

    function setLendingPool(address pool_) external onlyOwner {
        require(pool_ != address(0), "FD: zero pool");
        lendingPool = pool_;
        emit LendingPoolUpdated(pool_);
    }

    // --- Core -----------------------------------------------------------------

    /// @notice Distributes `amount` of `asset` fees according to the split.
    ///         Called by the LendingPool when it sweeps reserve balances.
    ///         The pool must have already transferred `amount` to this contract.
    /// @param asset  Token address (USDC or EURC)
    /// @param amount Total fee amount to distribute
    function distribute(address asset, uint256 amount) external nonReentrant {
        require(msg.sender == lendingPool || msg.sender == owner(), "FD: not pool");
        require(amount > 0, "FD: zero amount");

        uint256 toLPs       = (amount * LP_SHARE)       / PERCENTAGE_FACTOR;
        uint256 toTreasury  = (amount * TREASURY_SHARE) / PERCENTAGE_FACTOR;
        uint256 toStakers   = amount - toLPs - toTreasury; // remainder avoids rounding loss

        // LP share: send back to the lending pool to increase liquidity index
        IERC20(asset).safeTransfer(lendingPool, toLPs);

        // Treasury share: direct transfer
        IERC20(asset).safeTransfer(treasury, toTreasury);

        // Staker share: forward if staking contract is set, otherwise accumulate
        if (stakingContract != address(0)) {
            IERC20(asset).safeTransfer(stakingContract, toStakers);
        } else {
            pendingStakerReserve[asset] += toStakers;
        }

        emit FeesDistributed(asset, amount, toLPs, toTreasury, toStakers);
    }

    /// @notice Forwards accumulated staker reserves once the staking contract is set.
    ///         Anyone can call this to flush the pending reserve.
    function flushStakerReserve(address asset) external nonReentrant {
        require(stakingContract != address(0), "FD: no staking contract");
        uint256 pending = pendingStakerReserve[asset];
        require(pending > 0, "FD: nothing to flush");
        pendingStakerReserve[asset] = 0;
        IERC20(asset).safeTransfer(stakingContract, pending);
        emit StakerReserveForwarded(asset, pending, stakingContract);
    }

    // --- View -----------------------------------------------------------------

    /// @notice Returns the current balance of `asset` held by this contract.
    function balance(address asset) external view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }
}
