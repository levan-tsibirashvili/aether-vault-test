// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IAetherVault {
    function totalAssets() external view returns (uint256);
    function realizeBadDebt(address account, uint256 amount) external;
    function accountDebt(address account) external view returns (int256);
    function seizeCollateral(address token, address to, uint256 amount) external;
    function accrue() external;
    function takeRepayment(address from, uint256 amount) external returns (uint256 received);
    function applyRepayment(address account, uint256 amount) external;
    function getAccountHealth(address account) external view returns (uint256);
    function collateralOf(address account, address token) external view returns (uint256);
    function collateralTokenAt(uint256 index) external view returns (address);
    function collateralTokenCount() external view returns (uint256);
    function beginLiquidation() external;
    function endLiquidation() external;
}
