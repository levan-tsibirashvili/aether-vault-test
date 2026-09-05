// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @dev Minimal interface for vault wiring. Full liquidation API lives on the engine contract.
interface ILiquidationEngine {
    function vault() external view returns (address);
}
