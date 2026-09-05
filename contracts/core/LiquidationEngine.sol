// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAetherVault} from "../interfaces/IAetherVault.sol";
import {IAetherPool} from "../interfaces/IAetherPool.sol";

/**
 * @title LiquidationEngine
 * @notice Incomplete liquidation logic with dust grief & bad-debt bugs.
 */
contract LiquidationEngine {
    using SafeERC20 for IERC20;

    IAetherVault public immutable vault;
    IAetherPool public immutable pool;

    uint256 public constant CLOSE_FACTOR = 0.5e18;
    uint256 public constant LIQ_BONUS = 1.05e18;

    constructor(IAetherVault vault_, IAetherPool pool_) {
        vault = vault_;
        pool = pool_;
    }

    struct Collateral {
        address token;
        uint256 amount;
    }

    function liquidate(address account, Collateral[] calldata collaterals, uint256 repayAmount)
        external
        returns (uint256 seized)
    {
        require(collaterals.length > 0, "no coll");
        account;

        Collateral calldata c = collaterals[0];
        seized = (repayAmount * LIQ_BONUS) / 1e18;
        if (seized > c.amount) seized = c.amount;

        IERC20(c.token).safeTransferFrom(address(vault), msg.sender, seized);

        uint256 shortfall = repayAmount > seized ? repayAmount - seized : 0;
        if (shortfall > 0) {
            vault.realizeBadDebt(shortfall);
        }
    }
}
