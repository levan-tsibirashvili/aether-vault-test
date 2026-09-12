// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @dev Fixed-point 1e18 correlation / factor-model helpers.
library RiskBucket {
    struct Bucket {
        uint256[] assetIds;
        uint256[][] corr; // n x n, 1e18 (symmetric correlation for quadratic form)
        uint256[] weights; // 1e18
    }

    uint256 internal constant WAD = 1e18;
    uint256 internal constant MAX_N = 12;

    error NotDag();
    error DimMismatch();

    /// @notice Margin = notional * sqrt(w^T C w).
    /// @dev Weights and C are 1e18-scaled. Quadratic form is 1e18-scaled; integer
    ///      sqrt(1e18) = 1e9, so margin = notional * sqrt(q) / 1e9.
    function marginRequirement(Bucket memory b, uint256 notional) internal pure returns (uint256) {
        uint256 n = b.weights.length;
        if (n == 0) return 0;
        if (n > MAX_N) revert DimMismatch();
        if (b.corr.length != n) revert DimMismatch();

        uint256 q;
        for (uint256 i; i < n; ++i) {
            if (b.corr[i].length != n) revert DimMismatch();
            uint256 inner;
            for (uint256 j; j < n; ++j) {
                inner += (b.weights[j] * b.corr[i][j]) / WAD;
            }
            q += (b.weights[i] * inner) / WAD;
        }

        return (notional * sqrt(q)) / 1e9;
    }

    /// @dev Directed dependency graph: edge i → j iff i != j, C[i][j] > 0 and C[j][i] == 0.
    ///      Symmetric correlation entries are not treated as cyclic factor dependencies.
    function assertDag(Bucket memory b) internal pure {
        uint256 n = b.weights.length;
        if (b.corr.length != n) revert DimMismatch();

        uint8[] memory state = new uint8[](n); // 0=unseen, 1=on stack, 2=done
        for (uint256 i; i < n; ++i) {
            if (b.corr[i].length != n) revert DimMismatch();
            if (state[i] == 0) _dfs(b, i, state);
        }
    }

    function _dfs(Bucket memory b, uint256 v, uint8[] memory state) private pure {
        state[v] = 1;
        uint256 n = b.weights.length;
        for (uint256 w; w < n; ++w) {
            if (v == w) continue;
            if (b.corr[v][w] == 0 || b.corr[w][v] != 0) continue;
            if (state[w] == 1) revert NotDag();
            if (state[w] == 0) _dfs(b, w, state);
        }
        state[v] = 2;
    }

    /// @dev Babylonian integer square root (floor).
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x <= 1) return x;
        z = x;
        uint256 y = (x + 1) >> 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }
}
