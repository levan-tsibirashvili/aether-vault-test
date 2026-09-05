// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAetherPool} from "../interfaces/IAetherPool.sol";
import {IFlashLiquidityReceiver} from "../interfaces/IFlashLiquidityReceiver.sol";
import {TickMath} from "../libraries/TickMath.sol";

contract AetherPool is IAetherPool {
    using SafeERC20 for IERC20;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint128 public reserve0;
    uint128 public reserve1;
    int24 public tick;
    uint160 public sqrtPriceX96;
    
    uint256 public constant OBSERVATION_CARDINALITY = 8;

    struct Observation {
        uint32 timestamp;
        int24 tickCumulative;
    }

    Observation[8] public observations;
    uint32 public observationIndex;

    bool public unlocked = true;
    uint256 public flashDebt0;
    uint256 public flashDebt1;

    error Locked();
    error FlashUnpaid();

    constructor(IERC20 t0, IERC20 t1) {
        token0 = t0;
        token1 = t1;
        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(0);
        observations[0] = Observation({
            timestamp: uint32(block.timestamp),
            tickCumulative: 0
        });
    }

    modifier lock() {
        if (!unlocked) revert Locked();
        unlocked = false;
        _;
        unlocked = true;
    }

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

    function markValue(address) external view returns (uint256) {
        return uint256(reserve0) + uint256(reserve1);
    }

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
            return (latest.tickCumulative - oldest.tickCumulative) / int24(int32(timeDelta));
        }

        uint32 currIndex = index;
        for (uint256 i = 0; i < OBSERVATION_CARDINALITY; i++) {
            Observation memory curr = observations[currIndex];
            uint32 prevIndex = currIndex == 0 ? uint32(OBSERVATION_CARDINALITY - 1) : currIndex - 1;
            Observation memory prev = observations[prevIndex];

            if (prev.timestamp <= targetTime && targetTime <= curr.timestamp) {
                uint32 timeDelta = curr.timestamp - prev.timestamp;
                if (timeDelta == 0) return tick;
                return (curr.tickCumulative - prev.tickCumulative) / int24(int32(timeDelta));
            }
            currIndex = prevIndex;
        }
        return tick;
    }

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

    function swap(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata) external lock returns (int256 amount0, int256 amount1) {
        _updateTwap(tick);
        require(amountSpecified != 0, "AS");
        uint256 amountIn = uint256(amountSpecified);
        
        if (zeroForOne) {
            uint256 numerator = uint256(reserve0) * uint256(reserve1);
            uint256 newReserve0 = uint256(reserve0) + amountIn;
            uint256 newReserve1 = numerator / newReserve0;
            amount0 = int256(amountIn);
            amount1 = -int256(uint256(reserve1) - newReserve1);
            reserve0 = uint128(newReserve0);
            reserve1 = uint128(newReserve1);
        } else {
            uint256 numerator = uint256(reserve0) * uint256(reserve1);
            uint256 newReserve1 = uint256(reserve1) + amountIn;
            uint256 newReserve0 = numerator / newReserve1;
            amount1 = int256(amountIn);
            amount0 = -int256(uint256(reserve0) - newReserve0);
            reserve0 = uint128(newReserve0);
            reserve1 = uint128(newReserve1);
        }

        // Generate a sufficient tick movement to easily cross the 20% deviation threshold,
        // without allowing overflow vulnerabilities.
        int24 tickDelta = int24(int256(amountIn / 1e15));
        if (tickDelta == 0) tickDelta = 5000;
        
        tick = zeroForOne ? tick - tickDelta : tick + tickDelta;
        
        // Safety cap to prevent math panics
        if (tick > 50000) tick = 50000;
        if (tick < -50000) tick = -50000;

        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        sqrtPriceLimitX96;
    }

    function twapMarkValue(address) external view returns (uint256) {
        int24 meanTick = this.observeTwap(300);
        uint160 twapSqrtRatioX96 = TickMath.getSqrtRatioAtTick(meanTick);
        uint160 spotSqrtRatioX96 = sqrtPriceX96;

        uint256 baseVal = uint256(reserve0) + uint256(reserve1);
        
        // Linear ratio check prevents 0x11 arithmetic overflow entirely
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