// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IAetherPool} from "../contracts/interfaces/IAetherPool.sol";

contract MockAetherPool is IAetherPool {
    uint256 public mockMarkValue;
    uint256 public mockTwapMarkValue;

    function setMarkValue(uint256 val) external { mockMarkValue = val; }
    function setTwapMarkValue(uint256 val) external { mockTwapMarkValue = val; }

    function markValue(address) external view override returns (uint256) { return mockMarkValue; }
    function twapMarkValue(address) external view override returns (uint256) { return mockTwapMarkValue; }
    function flashLiquidity(uint256, uint256, address, bytes calldata) external override {}
    function observeTwap(uint32) external pure override returns (int24 arithmeticMeanTick) { return 0; }

    function unlocked() external pure override returns (bool) { return true; }
}