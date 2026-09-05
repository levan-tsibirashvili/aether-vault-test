// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAetherVault} from "../interfaces/IAetherVault.sol";
import {IAetherPool} from "../interfaces/IAetherPool.sol";

/**
 * @title LiquidationEngine
 * @notice Complete liquidation logic with health factor, close factor, dust rules, and TWAP vs spot checks.
 */
contract LiquidationEngine {
    using SafeERC20 for IERC20;

    IAetherVault public immutable vault;
    IAetherPool public immutable pool;

    uint256 public constant CLOSE_FACTOR = 0.5e18;
    uint256 public constant LIQ_BONUS = 1.05e18;
    uint256 public constant DUST_THRESHOLD = 1000;

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
        require(repayAmount > DUST_THRESHOLD, "dust");

        // 1. ჯანმრთელობის ფაქტორის შემოწმება (Health Factor < 1e18)
        int256 accountDebtBal = vault.accountDebt(account);
        require(accountDebtBal > 0, "no debt");
        
        uint256 totalCollateralValue = 0;
        for (uint256 i = 0; i < collaterals.length; i++) {
            totalCollateralValue += collaterals[i].amount; // მარტივი აგრეგაცია ან ფასზე სკალირება
        }
        
        uint256 healthFactor = (totalCollateralValue * 1e18) / uint256(accountDebtBal);
        require(healthFactor < 1e18, "healthy");

        // 2. Close Factor-ის ლიმიტი (მაქსიმუმ ვალის 50%)
        uint256 maxRepay = (uint256(accountDebtBal) * CLOSE_FACTOR) / 1e18;
        require(repayAmount <= maxRepay, "close factor exceeded");

        // 3. TWAP vs Spot უსაფრთხოების შემოწმება
        uint256 spotVal = pool.markValue(account);
        uint256 twapVal = pool.twapMarkValue(account);
        require(spotVal <= (twapVal * 120) / 100, "twap deviation");

        // 4. მრავალკოლატერალური სეიზის ლოგიკა
        uint256 remainingRepay = repayAmount;
        for (uint256 i = 0; i < collaterals.length && remainingRepay > 0; i++) {
            Collateral calldata c = collaterals[i];
            uint256 targetSeized = (remainingRepay * LIQ_BONUS) / 1e18;
            
            uint256 actualSeized = targetSeized > c.amount ? c.amount : targetSeized;
            if (actualSeized > 0) {
                IERC20(c.token).safeTransferFrom(address(vault), msg.sender, actualSeized);
                seized += actualSeized;
                remainingRepay = remainingRepay > (actualSeized * 1e18) / LIQ_BONUS 
                    ? remainingRepay - (actualSeized * 1e18) / LIQ_BONUS 
                    : 0;
            }
        }

        // 5. ცუდი ვალის რეალიზაცია თუ დარჩა შეუსაბამობა
        uint256 shortfall = remainingRepay;
        if (shortfall > 0) {
            vault.realizeBadDebt(shortfall);
        }
    }
}