// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAetherPool} from "../interfaces/IAetherPool.sol";
import {ILiquidationEngine} from "../interfaces/ILiquidationEngine.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// Import OpenZeppelin Ownable for access control
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AetherVault
 * @notice Leveraged yield vault — INTENTIONALLY UNSAFE BASELINE for take-home.
 * @dev Candidates must fix donation/inflation, accrual ordering, and bad-debt paths.
 */
contract AetherVault is ERC4626, ReentrancyGuard, Ownable, EIP712 {
    using SafeERC20 for IERC20;

    IAetherPool public immutable pool;
    ILiquidationEngine public liquidationEngine;

    uint256 public fundingIndex = 1e18;
    uint256 public lastAccrual;
    uint256 public badDebt;
    uint256 public totalDebt;

    bytes32 public constant GRANT_OPERATOR_TYPEHASH = keccak256(
    "GrantOperator(address operator,uint256 until,uint256 nonce,uint256 deadline)"
    );

    mapping(address => mapping(address => uint256)) public operatorUntil;
    mapping(address => mapping(address => uint256)) public operatorNonce;
    mapping(address => int256) public accountDebt; // signed for credit/debt

    error ZeroShares();
    error Unhealthy();
    error NotOperator();
    error Expired();
    error InvalidSignature();

    event OperatorGranted(address indexed owner, address indexed operator, uint256 until, uint256 nonce);
    event OperatorCancelled(address indexed owner, address indexed operator);

    /// Initialize Ownable with deployer as initial owner
    constructor(IERC20 asset_, IAetherPool pool_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
        Ownable(msg.sender)
        EIP712(name_, "1")
    {
        pool = pool_;
        lastAccrual = block.timestamp;
    }

    function grantOperator(
        address owner,
        address operator,
        uint256 until,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert Expired();

        uint256 currentNonce = operatorNonce[owner][operator];

        bytes32 structHash = keccak256(
            abi.encode(
                GRANT_OPERATOR_TYPEHASH,
                operator,
                until,
                currentNonce,
                deadline
            )
        );

        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, v, r, s);
        if (signer != owner) revert InvalidSignature();

        operatorNonce[owner][operator] = currentNonce + 1;
        operatorUntil[owner][operator] = until;

        emit OperatorGranted(owner, operator, until, currentNonce);
    }

    function cancelOperator(address operator) external {
        operatorUntil[msg.sender][operator] = 0;
        emit OperatorCancelled(msg.sender, operator);
    }

    /// Restrict liquidation engine updates to owner only
    function setLiquidationEngine(ILiquidationEngine eng) external onlyOwner{
        liquidationEngine = eng;
    }

    /// @notice Overridden totalAssets includes virtual (uncommitted) interest 
    /// so ERC-4626 preview functions match actual execution within 1 wei.
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 lpMark = pool.twapMarkValue(address(this));
        
        (uint256 interest,) = _calculateAccrual();
        uint256 currentTotalDebt = totalDebt + interest;
                
        uint256 grossAssets = idle + lpMark + currentTotalDebt;
        if (grossAssets < badDebt) {
            return 0;
        }
        
        return grossAssets - badDebt;
    }
    
    /// @notice Enables a virtual offset (offset = 3) to neutralize first-depositor inflation attacks and donation vectors.
    function _decimalsOffset() internal view virtual override returns (uint8) {
        return 3; 
    }

    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        /// Critical ordering: accrue interest/funding before calculations
        _accrue(); 

        // Fee-on-Transfer support: measure actually received tokens
        uint256 balanceBefore = IERC20(asset()).balanceOf(address(this));
        SafeERC20.safeTransferFrom(IERC20(asset()), msg.sender, address(this), assets);
        uint256 balanceAfter = IERC20(asset()).balanceOf(address(this));
        uint256 actualAssets = balanceAfter - balanceBefore;

        require(actualAssets > 0, "Zero assets received");

        /// Calculate shares based on actually received (actualAssets) rather than requested tokens
        shares = previewDeposit(actualAssets);
        if (shares == 0) revert ZeroShares();

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, actualAssets, shares);
    }

    
    ///////

    /// @notice Integrates _accrue() into the mint operation.
    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        _accrue();
        assets = super.mint(shares, receiver);
        if (assets == 0) revert ZeroShares();
    }

    ///////


    /// @notice Integrates _accrue() into the redeem operation.
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        _accrue();
        assets = super.redeem(shares, receiver, owner);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _accrue();
        shares = super.withdraw(assets, receiver, owner);
    }

    function _accrue() internal {
        (uint256 interest, uint256 newFundingIndex) = _calculateAccrual();
        if (block.timestamp == lastAccrual) return;
        
        if (interest > 0) {
            totalDebt += interest;
            fundingIndex = newFundingIndex;
        }
        lastAccrual = block.timestamp;
    } 
    
    function _calculateAccrual() internal view returns (uint256 interest, uint256 newFundingIndex) {
        uint256 timeDelta = block.timestamp - lastAccrual;
        if (timeDelta == 0 || totalDebt == 0) {
            return (0, fundingIndex);
        }
        
        // Example rate calculation per second (e.g., target APR scaled to 1e18)
        uint256 interestRatePerSecond = 317097929; // ~1% annual rate per second
        interest = (totalDebt * interestRatePerSecond * timeDelta) / 1e18;
        
        uint256 supply = totalSupply();
        uint256 indexDelta = supply == 0 ? 0 : (interest * 1e18) / supply;
        newFundingIndex = fundingIndex + indexDelta;
    }

    function realizeBadDebt(uint256 amount) external {
        require(msg.sender == address(liquidationEngine), "only liq");
        // BUG: can brick redeems if badDebt > totalAssets
        badDebt += amount;
    }
}
