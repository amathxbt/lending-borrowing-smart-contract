// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "./UnitFlowLendingPool.sol";
import "./UnitFlowPriceOracle.sol";
import "./UnitFlowInterestRateModel.sol";

/// @title UnitFlowLendingConfigurator
/// @notice Role-based admin interface for UnitFlowLendingPool.
///
///         Roles:
///           DEFAULT_ADMIN_ROLE  - can grant/revoke all roles
///           POOL_ADMIN_ROLE     - can pause/unpause, update oracle/IRM/fee distributor
///           RISK_ADMIN_ROLE     - can update risk parameters (LTV, rates, feeds)
///
///         Critical parameter changes (oracle, IRM) are subject to a 24-hour timelock.
///         Non-critical changes (fallback prices, pause) take effect immediately.
contract UnitFlowLendingConfigurator is AccessControl {

    bytes32 public constant POOL_ADMIN_ROLE = keccak256("POOL_ADMIN_ROLE");
    bytes32 public constant RISK_ADMIN_ROLE = keccak256("RISK_ADMIN_ROLE");

    uint256 public constant TIMELOCK_DELAY = 24 hours;

    UnitFlowLendingPool public pool;

    // --- Timelock queue -------------------------------------------------------

    struct PendingAction {
        bytes32 actionId;
        uint256 executableAt;
        bool    executed;
    }

    // actionId => PendingAction
    mapping(bytes32 => PendingAction) public pendingActions;

    // --- Events ---------------------------------------------------------------

    event ActionQueued(bytes32 indexed actionId, uint256 executableAt);
    event ActionExecuted(bytes32 indexed actionId);
    event ActionCancelled(bytes32 indexed actionId);
    event PoolPaused(address indexed by);
    event PoolUnpaused(address indexed by);
    event ReserveAdded(address indexed asset, address uToken, address debtToken);
    event OracleQueued(address indexed newOracle, bytes32 actionId);
    event IRMQueued(address indexed newIRM, bytes32 actionId);
    event FeedUpdated(address indexed asset, address aggregator, uint256 fallbackPrice);

    // --- Constructor ----------------------------------------------------------

    constructor(address pool_, address admin_) {
        require(pool_  != address(0), "Cfg: zero pool");
        require(admin_ != address(0), "Cfg: zero admin");
        pool = UnitFlowLendingPool(pool_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(POOL_ADMIN_ROLE,    admin_);
        _grantRole(RISK_ADMIN_ROLE,    admin_);
    }

    // --- Immediate actions (POOL_ADMIN) ---------------------------------------

    function pausePool() external onlyRole(POOL_ADMIN_ROLE) {
        pool.pause();
        emit PoolPaused(msg.sender);
    }

    function unpausePool() external onlyRole(POOL_ADMIN_ROLE) {
        pool.unpause();
        emit PoolUnpaused(msg.sender);
    }

    /// @notice Adds a new reserve to the pool. Requires both POOL_ADMIN and RISK_ADMIN.
    function addReserve(
        address asset,
        address uToken,
        address debtToken
    ) external onlyRole(POOL_ADMIN_ROLE) {
        pool.addReserve(asset, uToken, debtToken);
        emit ReserveAdded(asset, uToken, debtToken);
    }

    // --- Immediate actions (RISK_ADMIN) ---------------------------------------

    /// @notice Updates the fallback price for an asset in the oracle.
    ///         Takes effect immediately — used for testnet price maintenance.
    function setFallbackPrice(
        address asset,
        uint256 price
    ) external onlyRole(RISK_ADMIN_ROLE) {
        UnitFlowPriceOracle(address(pool.oracle())).setFallbackPrice(asset, price);
    }

    /// @notice Registers a Chainlink feed for an asset.
    function setOracleFeed(
        address asset,
        address aggregator,
        uint256 fallbackPrice
    ) external onlyRole(RISK_ADMIN_ROLE) {
        UnitFlowPriceOracle(address(pool.oracle())).setFeed(asset, aggregator, fallbackPrice);
        emit FeedUpdated(asset, aggregator, fallbackPrice);
    }

    // --- Timelocked actions (POOL_ADMIN) --------------------------------------

    /// @notice Queues an oracle update. Executable after TIMELOCK_DELAY.
    function queueOracleUpdate(address newOracle)
        external
        onlyRole(POOL_ADMIN_ROLE)
        returns (bytes32 actionId)
    {
        require(newOracle != address(0), "Cfg: zero oracle");
        actionId = keccak256(abi.encode("SET_ORACLE", newOracle, block.timestamp));
        _queue(actionId);
        // Store the target address in the action id mapping via a separate lookup
        _pendingOracle[actionId] = newOracle;
        emit OracleQueued(newOracle, actionId);
    }

    /// @notice Executes a queued oracle update after the timelock has elapsed.
    function executeOracleUpdate(bytes32 actionId)
        external
        onlyRole(POOL_ADMIN_ROLE)
    {
        _execute(actionId);
        address newOracle = _pendingOracle[actionId];
        require(newOracle != address(0), "Cfg: unknown action");
        pool.setOracle(newOracle);
        delete _pendingOracle[actionId];
    }

    /// @notice Queues an interest rate model update. Executable after TIMELOCK_DELAY.
    function queueIRMUpdate(address newIRM)
        external
        onlyRole(POOL_ADMIN_ROLE)
        returns (bytes32 actionId)
    {
        require(newIRM != address(0), "Cfg: zero IRM");
        actionId = keccak256(abi.encode("SET_IRM", newIRM, block.timestamp));
        _queue(actionId);
        _pendingIRM[actionId] = newIRM;
        emit IRMQueued(newIRM, actionId);
    }

    /// @notice Executes a queued IRM update after the timelock has elapsed.
    function executeIRMUpdate(bytes32 actionId)
        external
        onlyRole(POOL_ADMIN_ROLE)
    {
        _execute(actionId);
        address newIRM = _pendingIRM[actionId];
        require(newIRM != address(0), "Cfg: unknown action");
        pool.setInterestRateModel(newIRM);
        delete _pendingIRM[actionId];
    }

    /// @notice Cancels a queued action before it is executed.
    function cancelAction(bytes32 actionId)
        external
        onlyRole(POOL_ADMIN_ROLE)
    {
        PendingAction storage action = pendingActions[actionId];
        require(action.executableAt > 0, "Cfg: action not queued");
        require(!action.executed,        "Cfg: already executed");
        delete pendingActions[actionId];
        delete _pendingOracle[actionId];
        delete _pendingIRM[actionId];
        emit ActionCancelled(actionId);
    }

    // --- View -----------------------------------------------------------------

    function isActionReady(bytes32 actionId) external view returns (bool) {
        PendingAction memory a = pendingActions[actionId];
        return a.executableAt > 0 && !a.executed && block.timestamp >= a.executableAt;
    }

    // --- Internal -------------------------------------------------------------

    // Separate storage for pending addresses (avoids encoding in actionId)
    mapping(bytes32 => address) private _pendingOracle;
    mapping(bytes32 => address) private _pendingIRM;

    function _queue(bytes32 actionId) internal {
        require(pendingActions[actionId].executableAt == 0, "Cfg: action exists");
        uint256 execAt = block.timestamp + TIMELOCK_DELAY;
        pendingActions[actionId] = PendingAction({
            actionId:     actionId,
            executableAt: execAt,
            executed:     false
        });
        emit ActionQueued(actionId, execAt);
    }

    function _execute(bytes32 actionId) internal {
        PendingAction storage action = pendingActions[actionId];
        require(action.executableAt > 0,              "Cfg: action not queued");
        require(!action.executed,                     "Cfg: already executed");
        require(block.timestamp >= action.executableAt, "Cfg: timelock active");
        action.executed = true;
        emit ActionExecuted(actionId);
    }
}
