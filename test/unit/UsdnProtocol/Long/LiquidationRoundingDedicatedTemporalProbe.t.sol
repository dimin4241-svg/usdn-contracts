// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestLiquidationRoundingPostBootstrapRegression } from "./LiquidationRoundingPostBootstrapRegression.t.sol";

/// @notice Diagnostic-only strict probes for the dedicated-liquidation temporal transition.
/// @dev Each test starts from the same freshly-built vulnerable witness. A passing probe means the shifted retry
/// still reaches the exact production Rebalancer invariant revert; a failing probe, together with the green
/// characterization tests, means the endpoint has crossed into the valid progress case instead.
contract TestLiquidationRoundingDedicatedTemporalProbe is TestLiquidationRoundingPostBootstrapRegression {
    function test_probe_D40_expectExactInvariantRevert() public {
        _probeExactInvariantRevert(40 seconds);
    }

    function test_probe_D45_expectExactInvariantRevert() public {
        _probeExactInvariantRevert(45 seconds);
    }

    function test_probe_D50_expectExactInvariantRevert() public {
        _probeExactInvariantRevert(50 seconds);
    }

    function test_probe_D55_expectExactInvariantRevert() public {
        _probeExactInvariantRevert(55 seconds);
    }

    function _probeExactInvariantRevert(uint256 shift) internal {
        vm.warp(block.timestamp + shift);
        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(finalPrice));
    }
}
