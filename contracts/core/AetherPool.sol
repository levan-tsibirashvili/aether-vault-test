// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAetherPool} from "../interfaces/IAetherPool.sol";
import {IFlashLiquidityReceiver} from "../interfaces/IFlashLiquidityReceiver.sol";
import {TickMath} from "../libraries/TickMath.sol";

/// @title AetherPool
/// @author Aether Protocol Core Team
/// @notice A custom Automated Market Maker (AMM) liquidity pool supporting Time-Weighted Average Price (TWAP), 
///         uncollateralized flash liquidity, and constant-product style token swaps.
contract AetherPool is IAetherPool {
    using SafeERC20 for IERC20;

    /// @notice The first ERC-20 token asset of the pool pair (token0).
    IERC20 public immutable token0;
    
    /// @notice The second ERC-20 token asset of the pool pair (token1).
    IERC20 public immutable token1;

    /// @notice The reserve balance tracking amount of token0 held in the pool.
    uint128 public reserve0;
    
    /// @notice The reserve balance tracking amount of token1 held in the pool.
    uint128 public reserve1;
    
    /// @notice The current discrete tick representing the price ratio of the pool.
    int24 public tick;
    
    /// @notice The current square root price ratio represented in Q96 fixed-point format.
    uint160 public sqrtPriceX96;
    
    /// @notice The fixed observation cardinality defining the ring buffer size for TWAP tracking.
    uint256 public constant OBSERVATION_CARDINALITY = 8;

    /// @notice Structure representing a single historical TWAP oracle observation point.
    struct Observation {
        uint32 timestamp;
        int56 tickCumulative;
    }

    /// @notice Circular ring buffer storing historical oracle observations.
    Observation[8] public observations;
    
    /// @notice The current index pointer within the observation ring buffer.
    uint32 public observationIndex;

    /// @notice Reentrancy lock flag; true when the pool is unlocked, false when locked.
    bool public unlocked = true;
    
    /// @notice Outstanding flash loan debt quantity for token0 during an active flash liquidity call.
    uint256 public flashDebt0;
    
    /// @notice Outstanding flash loan debt quantity for token1 during an active flash liquidity call.
    uint256 public flashDebt1;

    /// @notice Reverts when a reentrant or locked pool execution is attempted.
    error Locked();
    
    /// @notice Reverts when a flash liquidity loan is not fully repaid upon completion.
    error FlashUnpaid();

    /// @notice Initializes the pool with token pair addresses and sets initial price ratios and observation points.
    /// @param t0 The address of token0.
    /// @param t1 The address of token1.
    constructor(IERC20 t0, IERC20 t1) {
        token0 = t0;
        token1 = t1;
        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(0);
        observations[0] = Observation({
            timestamp: uint32(block.timestamp),
            tickCumulative: 0
        });
    }

    /// @dev Simple reentrancy guard modifier. Temporarily removed from `swap` to allow nested arbitrage callbacks during flash loans.
    modifier lock() {
        if (!unlocked) revert Locked();
        unlocked = false;
        _;
        unlocked = true;
    }

    /// @notice Updates the Time-Weighted Average Price (TWAP) accumulator ring buffer.
    /// @param currentTick The current discrete tick value before executing state changes.
    function _updateTwap(int24 currentTick) internal {
        uint32 time = uint32(block.timestamp);
        uint32 index = observationIndex;
        Observation storage latest = observations[index];
        
        if (latest.timestamp != time) {
            uint32 delta = time - latest.timestamp;
            uint32 nextIndex = (index + 1) % uint32(OBSERVATION_CARDINALITY);
            observations[nextIndex] = Observation({
                timestamp: time,
                tickCumulative: latest.tickCumulative + int24(int64(uint64(delta)) * int64(currentTick))
            });
            observationIndex = nextIndex;
        }
    }

    /// @notice Returns the raw unweighted sum of pool token reserves.
    /// @return The combined total of reserve0 and reserve1.
    function markValue(address) external view returns (uint256) {
        return uint256(reserve0) + uint256(reserve1);
    }

    /// @notice Calculates the arithmetic mean tick over a given time period in the past.
    /// @param secondsAgo The number of seconds in the past to start the TWAP calculation window.
    /// @return arithmeticMeanTick The time-weighted average tick over the specified duration.
    function observeTwap(uint32 secondsAgo) external view returns (int24 arithmeticMeanTick) {
        uint32 targetTime = uint32(block.timestamp) - secondsAgo;
        uint32 index = observationIndex;
        Observation memory latest = observations[index];

        if (targetTime >= latest.timestamp) return tick;

        uint32 oldestIndex = (index + 1) % uint32(OBSERVATION_CARDINALITY);
        Observation memory oldest = observations[oldestIndex];

        if (targetTime <= oldest.timestamp || oldest.timestamp == 0) {
            uint32 timeDelta = latest.timestamp - oldest.timestamp;
            if (timeDelta == 0) return tick;
            return int24((latest.tickCumulative - oldest.tickCumulative) / int56(uint56(timeDelta)));
        }

        uint32 currIndex = index;
        for (uint256 i = 0; i < OBSERVATION_CARDINALITY; i++) {
            Observation memory curr = observations[currIndex];
            uint32 prevIndex = currIndex == 0 ? uint32(OBSERVATION_CARDINALITY - 1) : currIndex - 1;
            Observation memory prev = observations[prevIndex];

            if (prev.timestamp <= targetTime && targetTime <= curr.timestamp) {
                uint32 timeDelta = curr.timestamp - prev.timestamp;
                if (timeDelta == 0) return tick;
                return int24((curr.tickCumulative - prev.tickCumulative) / int56(int32(timeDelta)));
            }
            currIndex = prevIndex;
        }
        return tick;
    }

    /// @notice Provides uncollateralized flash liquidity to a designated receiver address with callback support.
    /// @param amount0 The quantity of token0 to borrow.
    /// @param amount1 The quantity of token1 to borrow.
    /// @param receiver The receiver contract address implementing `IFlashLiquidityReceiver`.
    /// @param data Arbitrary payload data passed directly to the receiver's callback function.
    function flashLiquidity(uint256 amount0, uint256 amount1, address receiver, bytes calldata data) external lock {
        _updateTwap(tick);
        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        require(amount0 <= bal0 && amount1 <= bal1, "bal");

        flashDebt0 = amount0;
        flashDebt1 = amount1;

        if (amount0 > 0) reserve0 = uint128(bal0 - amount0);
        if (amount1 > 0) reserve1 = uint128(bal1 - amount1);

        if (amount0 > 0) token0.safeTransfer(receiver, amount0);
        if (amount1 > 0) token1.safeTransfer(receiver, amount1);

        IFlashLiquidityReceiver(receiver).onFlashLiquidity(msg.sender, amount0, amount1, data);

        uint256 bal0After = token0.balanceOf(address(this));
        uint256 bal1After = token1.balanceOf(address(this));
        if (bal0After < bal0 || bal1After < bal1) revert FlashUnpaid();

        reserve0 = uint128(bal0After);
        reserve1 = uint128(bal1After);
        flashDebt0 = 0;
        flashDebt1 = 0;
    }

    /// @notice Executes token swaps within the pool following constant-product AMM mechanics.
    /// @dev The reentrancy lock modifier is omitted to allow necessary arbitrage callbacks during flash loans.
    /// @param zeroForOne True if swapping token0 for token1, false if swapping token1 for token0.
    /// @param amountSpecified The exact input amount of tokens to swap.
    /// @param sqrtPriceLimitX96 The price limit restriction boundary for the swap execution.
    /// @return amount0 The balance delta for token0.
    /// @return amount1 The balance delta for token1.
    function swap(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata) external returns (int256 amount0, int256 amount1) {
        _updateTwap(tick);
        require(amountSpecified > 0, "AS"); // Only positive input amounts are supported
        
        uint256 amountIn = uint256(amountSpecified);
        IERC20 tokenIn = zeroForOne ? token0 : token1;
        IERC20 tokenOut = zeroForOne ? token1 : token0;

        uint256 balInBefore = tokenIn.balanceOf(address(this));
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 actualAmountIn = tokenIn.balanceOf(address(this)) - balInBefore;

        uint256 newReserve0;
        uint256 newReserve1;
        uint256 amountOut;

        if (zeroForOne) {
            uint256 numerator = uint256(reserve0) * uint256(reserve1);
            newReserve0 = uint256(reserve0) + actualAmountIn;
            newReserve1 = numerator / newReserve0;
            amount0 = int256(actualAmountIn);
            amountOut = uint256(reserve1) - newReserve1;
            amount1 = -int256(amountOut);
        } else {
            uint256 numerator = uint256(reserve0) * uint256(reserve1);
            newReserve1 = uint256(reserve1) + actualAmountIn;
            newReserve0 = numerator / newReserve1;
            amount1 = int256(actualAmountIn);
            amountOut = uint256(reserve0) - newReserve0;
            amount0 = -int256(amountOut);
        }

        reserve0 = uint128(newReserve0);
        reserve1 = uint128(newReserve1);
        
        _setTickFromReserves();
        sqrtPriceLimitX96; 
        
        tokenOut.safeTransfer(msg.sender, amountOut);
    }

    /// @notice Recalculates and updates the internal discrete tick and square root price based on current reserves.
    function _setTickFromReserves() internal {
        if (reserve0 == 0) return;
        
        uint256 p = (uint256(reserve1) * 1e18) / uint256(reserve0);
        
        if (p >= 1e18) {
            tick = int24(int256((p - 1e18) / 1e14));
        } else {
            tick = -int24(int256((1e18 - p) / 1e14));
        }
        
        if (tick > 50000) tick = 50000;
        if (tick < -50000) tick = -50000;
        
        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
    }

    /// @notice Deposits liquidity into the pool, increasing reserves and updating pricing metrics.
    /// @param amount0 The quantity of token0 liquidity to add.
    /// @param amount1 The quantity of token1 liquidity to add.
    function addLiquidity(uint256 amount0, uint256 amount1) external {
        _updateTwap(tick);
        
        uint256 b0 = token0.balanceOf(address(this));
        uint256 b1 = token1.balanceOf(address(this));
        
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);
        
        uint256 a0 = token0.balanceOf(address(this)) - b0;
        uint256 a1 = token1.balanceOf(address(this)) - b1;
        
        require(a0 > 0 && a1 > 0, "liq");
        
        reserve0 = uint128(uint256(reserve0) + a0);
        reserve1 = uint128(uint256(reserve1) + a1);
        
        _setTickFromReserves();
    }

    /// @notice Calculates the total value of pool reserves adjusted by the 5-minute TWAP price ratio.
    /// @return The adjusted TWAP mark value of the pool reserves.
    function twapMarkValue(address) external view returns (uint256) {
        int24 meanTick = this.observeTwap(300); // 5-minute TWAP window
        uint160 twapSqrtRatioX96 = TickMath.getSqrtRatioAtTick(meanTick);
        uint160 spotSqrtRatioX96 = sqrtPriceX96;

        uint256 baseVal = uint256(reserve0) + uint256(reserve1);
        
        // Linear ratio check prevents arithmetic overflow entirely
        if (spotSqrtRatioX96 > twapSqrtRatioX96) {
            uint256 ratio = (uint256(twapSqrtRatioX96) * 1e18) / uint256(spotSqrtRatioX96);
            return (baseVal * ratio) / 1e18;
        } else if (twapSqrtRatioX96 > spotSqrtRatioX96) {
            uint256 ratio = (uint256(spotSqrtRatioX96) * 1e18) / uint256(twapSqrtRatioX96);
            return (baseVal * ratio) / 1e18;
        }
        
        return baseVal;
    }
}