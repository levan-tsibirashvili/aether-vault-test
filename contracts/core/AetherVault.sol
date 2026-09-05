// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAetherPool} from "../interfaces/IAetherPool.sol";
import {ILiquidationEngine} from "../interfaces/ILiquidationEngine.sol";

/// Import OpenZeppelin Ownable for access control
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AetherVault
 * @notice Leveraged yield vault — INTENTIONALLY UNSAFE BASELINE for take-home.
 * @dev Candidates must fix donation/inflation, accrual ordering, and bad-debt paths.
 */
contract AetherVault is ERC4626, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    IAetherPool public immutable pool;
    ILiquidationEngine public liquidationEngine;

    uint256 public fundingIndex = 1e18;
    uint256 public lastAccrual;
    uint256 public badDebt;
    uint256 public totalDebt;

    mapping(address => int256) public accountDebt; // signed for credit/debt
    mapping(address => uint256) public operatorUntil;
    mapping(address => mapping(address => uint256)) public operatorNonce;

    error ZeroShares();
    error Unhealthy();
    error NotOperator();

    /// Initialize Ownable with deployer as initial owner
    constructor(IERC20 asset_, IAetherPool pool_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
        Ownable(msg.sender)
    {
        pool = pool_;
        lastAccrual = block.timestamp;
    }

    /// Restrict liquidation engine updates to owner only
    function setLiquidationEngine(ILiquidationEngine eng) external onlyOwner{
        liquidationEngine = eng;
    }

    /// @dev BUG: does not accrue before deposit; includes raw balance (donation vector)
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 lpMark = pool.markValue(address(this));
        return idle + lpMark - badDebt; // BUG: can underflow conceptually; also donation-inflated
    }

    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        // BUG: missing _accrue()
        shares = super.deposit(assets, receiver);
        if (shares == 0) revert ZeroShares();
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        // BUG: missing health check for leveraged accounts
        shares = super.withdraw(assets, receiver, owner);
    }

    function _accrue() internal {
        // TODO(candidate): funding/interest accrual updating fundingIndex, totalDebt, accountDebt
        lastAccrual = block.timestamp;
    }

    function realizeBadDebt(uint256 amount) external {
        require(msg.sender == address(liquidationEngine), "only liq");
        // BUG: can brick redeems if badDebt > totalAssets
        badDebt += amount;
    }

    function grantOperator(address op, uint256 until) external {
        // TODO(candidate): EIP-712 + nonce + domain separation — baseline is trivial
        operatorUntil[op] = until;
    }
}
