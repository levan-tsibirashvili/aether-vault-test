// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

interface IAetherVault {
    function realizeBadDebt(uint256 amount) external;
    function asset() external view returns (address);
}
