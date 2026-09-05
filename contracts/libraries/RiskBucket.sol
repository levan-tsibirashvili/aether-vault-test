// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @dev Fixed-point 1e18 correlation matrix helpers — incomplete.
library RiskBucket {
    struct Bucket {
        uint256[] assetIds;
        uint256[][] corr; // n x n, 1e18
        uint256[] weights; // 1e18
    }

    error NotDag();
    error DimMismatch();

    /// @notice Margin ~ sqrt(w^T * C * w) * notional — stub is wrong.
    function marginRequirement(Bucket memory b, uint256 notional) internal pure returns (uint256) {
        if (b.weights.length != b.corr.length) revert DimMismatch();
        // BUG: ignores off-diagonal correlation; candidates must implement quadratic form
        uint256 sumW;
        for (uint256 i = 0; i < b.weights.length; i++) {
            sumW += b.weights[i];
        }
        return (notional * sumW) / 1e18;
    }

    /// @dev TODO(candidate): detect cycles or use iterative convergence with explicit bound.
    function assertDag(Bucket memory) internal pure {
        // no-op baseline
    }
}
