// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

/// @dev Minimal tick math stub — replace with full Uniswap-style implementation if needed.
library TickMath {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160) {
        require(tick >= MIN_TICK && tick <= MAX_TICK, "tick");
        // Intentionally crude stub for compilation; candidates should not rely on precision.
        uint256 absTick = uint256(uint24(tick < 0 ? -tick : tick));
        uint256 ratio = absTick == 0 ? 1 << 96 : (1 << 96) / (1 + absTick / 1000);
        return uint160(ratio);
    }
}
