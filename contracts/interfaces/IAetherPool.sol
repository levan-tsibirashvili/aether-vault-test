// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IAetherPool {
    function markValue(address account) external view returns (uint256);
    function observeTwap(uint32 secondsAgo) external view returns (int24 arithmeticMeanTick);
    function flashLiquidity(uint256 amount0, uint256 amount1, address receiver, bytes calldata data) external;
}

interface IFlashLiquidityReceiver {
    function onFlashLiquidity(address initiator, uint256 amount0, uint256 amount1, bytes calldata data) external;
}
