// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAetherPool} from "../interfaces/IAetherPool.sol";
import {IFlashLiquidityReceiver} from "../interfaces/IFlashLiquidityReceiver.sol";
import {TickMath} from "../libraries/TickMath.sol";

/**
 * @title AetherPool
 * @notice Simplified CLMM pool with flash liquidity — UNSAFE baseline.
 */
contract AetherPool is IAetherPool {
    using SafeERC20 for IERC20;

    IERC20 public immutable token0;
    IERC20 public immutable token1;

    uint128 public reserve0;
    uint128 public reserve1;
    int24 public tick;
    uint160 public sqrtPriceX96;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    uint32[8] public twapTicks; // ring buffer stub
    uint32 public twapIndex;
    bool public unlocked = true;

    uint256 public flashDebt0;
    uint256 public flashDebt1;

    error Locked();
    error FlashUnpaid();

    constructor(IERC20 t0, IERC20 t1) {
        token0 = t0;
        token1 = t1;
        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(0);
    }

    modifier lock() {
        if (!unlocked) revert Locked();
        unlocked = false;
        _;
        unlocked = true;
    }

    function markValue(address) external view returns (uint256) {
        // BUG: uses spot only — flash-manipulable
        return uint256(reserve0) + uint256(reserve1); // nonsense units on purpose
    }

    function observeTwap(uint32 /* secondsAgo */) external view returns (int24 arithmeticMeanTick) {
        // TODO(candidate): real TWAP; stub returns current tick
        return tick;
    }

    /// @dev BUG: updates reserves AFTER callback — classic reentrancy / read-only reentrancy vector
    function flashLiquidity(uint256 amount0, uint256 amount1, address receiver, bytes calldata data)
        external
        lock
    {
        uint256 bal0 = token0.balanceOf(address(this));
        uint256 bal1 = token1.balanceOf(address(this));
        require(amount0 <= bal0 && amount1 <= bal1, "bal");

        if (amount0 > 0) token0.safeTransfer(receiver, amount0);
        if (amount1 > 0) token1.safeTransfer(receiver, amount1);

        flashDebt0 = amount0; // fee omitted in baseline
        flashDebt1 = amount1;

        IFlashLiquidityReceiver(receiver).onFlashLiquidity(msg.sender, amount0, amount1, data);

        // BUG: reserve accounting after callback
        uint256 bal0After = token0.balanceOf(address(this));
        uint256 bal1After = token1.balanceOf(address(this));
        if (bal0After < bal0 || bal1After < bal1) revert FlashUnpaid();

        reserve0 = uint128(bal0After);
        reserve1 = uint128(bal1After);
        flashDebt0 = 0;
        flashDebt1 = 0;
    }

    function swap(bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        lock
        returns (int256 amount0, int256 amount1)
    {
        // TODO(candidate): real swap math — stub moves spot naively
        tick = zeroForOne ? tick - 1 : tick + 1;
        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        amount0 = amountSpecified;
        amount1 = -amountSpecified;
        sqrtPriceLimitX96;
    }
}
