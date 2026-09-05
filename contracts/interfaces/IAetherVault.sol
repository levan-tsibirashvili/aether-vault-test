// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IAetherVault {
    function totalAssets() external view returns (uint256);
    function realizeBadDebt(uint256 amount) external;
    function accountDebt(address account) external view returns (int256);
    function seizeCollateral(address token, address to, uint256 amount) external;
}