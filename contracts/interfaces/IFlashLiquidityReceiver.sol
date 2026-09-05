// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IFlashLiquidityReceiver {
    function onFlashLiquidity(
        address initiator,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external returns (bytes32);
}
