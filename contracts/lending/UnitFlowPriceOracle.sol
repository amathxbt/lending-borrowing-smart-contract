// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @dev Minimal Chainlink AggregatorV3 interface
interface IAggregatorV3 {
    function latestRoundData()
        external
        view
        returns (
            uint80  roundId,
            int256  answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80  answeredInRound
        );
    function decimals() external view returns (uint8);
}

/// @title UnitFlowPriceOracle
/// @notice Chainlink-compatible price oracle for USDC and EURC.
///         Returns USD prices in 8 decimals (Chainlink standard).
///         Rejects stale feeds older than MAX_STALENESS (1 hour).
///         Falls back to a manually-set fallback price if the feed is stale or unset.
contract UnitFlowPriceOracle is Ownable2Step {

    struct PriceFeed {
        address aggregator;    // Chainlink aggregator (address(0) = fallback only)
        uint256 fallbackPrice; // Manual price in 8 decimals
        bool    active;
    }

    uint256 public constant MAX_STALENESS  = 1 hours;
    uint256 public constant PRICE_DECIMALS = 8;

    mapping(address => PriceFeed) public priceFeeds;

    event FeedSet(address indexed asset, address aggregator, uint256 fallbackPrice);
    event FallbackPriceSet(address indexed asset, uint256 price);

    constructor(address owner_) Ownable(owner_) {}

    // --- Admin ----------------------------------------------------------------

    /// @notice Registers or updates a price feed for an asset.
    function setFeed(
        address asset,
        address aggregator,
        uint256 fallbackPrice
    ) external onlyOwner {
        require(asset != address(0), "Oracle: zero asset");
        require(fallbackPrice > 0,   "Oracle: zero fallback");
        priceFeeds[asset] = PriceFeed({
            aggregator:    aggregator,
            fallbackPrice: fallbackPrice,
            active:        true
        });
        emit FeedSet(asset, aggregator, fallbackPrice);
    }

    /// @notice Updates only the fallback price for an asset.
    function setFallbackPrice(address asset, uint256 price) external onlyOwner {
        require(priceFeeds[asset].active, "Oracle: feed not set");
        require(price > 0, "Oracle: zero price");
        priceFeeds[asset].fallbackPrice = price;
        emit FallbackPriceSet(asset, price);
    }

    // --- View -----------------------------------------------------------------

    /// @notice Returns the USD price of an asset in 8 decimals.
    ///         Tries the Chainlink feed first; falls back to manual price if the
    ///         feed is absent, stale (> 1 hour), or returns a non-positive answer.
    function getAssetPrice(address asset) external view returns (uint256) {
        PriceFeed memory feed = priceFeeds[asset];
        require(feed.active, "Oracle: asset not supported");

        if (feed.aggregator != address(0)) {
            try IAggregatorV3(feed.aggregator).latestRoundData() returns (
                uint80,
                int256  answer,
                uint256,
                uint256 updatedAt,
                uint80
            ) {
                bool fresh = (block.timestamp - updatedAt) <= MAX_STALENESS;
                if (answer > 0 && fresh) {
                    uint8 d = IAggregatorV3(feed.aggregator).decimals();
                    if (d == 8)      return uint256(answer);
                    else if (d < 8)  return uint256(answer) * (10 ** (8 - d));
                    else             return uint256(answer) / (10 ** (d - 8));
                }
            } catch {}
        }

        return feed.fallbackPrice;
    }

    function isSupported(address asset) external view returns (bool) {
        return priceFeeds[asset].active;
    }
}
