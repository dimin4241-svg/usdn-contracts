// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestLiquidationRoundingPostBootstrapRegression } from "./LiquidationRoundingPostBootstrapRegression.t.sol";
import { IRebalancer as RebalancerInterface } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Focused liveness validation for the public dedicated liquidation endpoint.
/// @dev The inherited fixture creates the fully post-bootstrap, ordinary-position witness using only public lifecycle
/// actions. At the final state exactly two liquidatable ticks remain and the production Rebalancer is installed.
contract TestLiquidationRoundingDedicatedLiveness is TestLiquidationRoundingPostBootstrapRegression {
    function test_A_repeatedDedicatedLiquidationRetriesMakeZeroProgress() public {
        assertEq(protocol.getLiquidationIteration(), 1, "production user-action liquidation iteration");
        assertEq(protocol.getTotalLongPositions(), 2, "two liquidatable witness positions");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "expected highest tick before retries");

        uint256 positionsBefore = protocol.getTotalLongPositions();
        uint256 expoBefore = protocol.getTotalExpo();
        uint256 longBalanceBefore = protocol.getBalanceLong();
        uint256 vaultBalanceBefore = protocol.getBalanceVault();
        int256 pendingVaultBefore = protocol.getPendingBalanceVault();
        uint256 pendingFeeBefore = protocol.getPendingProtocolFee();
        uint256 protocolAssetBefore = wstETH.balanceOf(address(protocol));
        uint256 liquidatorAssetBefore = wstETH.balanceOf(address(this));
        uint256 tickAVersionBefore = protocol.getTickVersion(posA.tick);
        uint256 tickBVersionBefore = protocol.getTickVersion(posB.tick);

        // dedicated liquidate() has no caller-supplied iteration parameter and internally uses the compile-time
        // MAX_LIQUIDATION_ITERATION (= 10). The same two-tick batch deterministically reaches the +1 wei state
        // and the production Rebalancer invariant reverts the entire transaction.
        for (uint256 i; i < 3; ++i) {
            vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
            protocol.liquidate(abi.encode(finalPrice));

            // Atomic rollback: a keeper/liquidator retry cannot commit even the first liquidated tick.
            assertEq(protocol.getTotalLongPositions(), positionsBefore, "retry changed position count");
            assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "retry changed highest tick");
            assertEq(protocol.getTotalExpo(), expoBefore, "retry changed total exposure");
            assertEq(protocol.getBalanceLong(), longBalanceBefore, "retry changed long balance");
            assertEq(protocol.getBalanceVault(), vaultBalanceBefore, "retry changed vault balance");
            assertEq(protocol.getPendingBalanceVault(), pendingVaultBefore, "retry changed pending vault balance");
            assertEq(protocol.getPendingProtocolFee(), pendingFeeBefore, "retry changed pending protocol fee");
            assertEq(wstETH.balanceOf(address(protocol)), protocolAssetBefore, "retry changed protocol assets");
            assertEq(wstETH.balanceOf(address(this)), liquidatorAssetBefore, "retry paid liquidator despite revert");
            assertEq(protocol.getTickVersion(posA.tick), tickAVersionBefore, "retry changed tick A version");
            assertEq(protocol.getTickVersion(posB.tick), tickBVersionBefore, "retry changed tick B version");
        }
    }

    function test_B_userActionIterationParameterCannotReduceDedicatedBatch() public {
        // The configurable storage parameter already equals 1 in production defaults. Re-setting it to 1 through
        // the authorized options-manager path does not alter dedicated liquidate(), which uses the hard-coded 10.
        vm.prank(managers.setOptionsManager);
        protocol.setLiquidationIteration(1);
        assertEq(protocol.getLiquidationIteration(), 1, "user-action iteration not set to one");

        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(finalPrice));

        assertEq(protocol.getTotalLongPositions(), 2, "dedicated batch unexpectedly made progress");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "dedicated batch changed highest tick");
    }

    function test_C_isolationControlRemovingOnlyRebalancerLetsSameBatchCommit() public {
        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(RebalancerInterface(address(0)));

        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(finalPrice));
        assertEq(ticks.length, 2, "same dedicated batch must contain both witness ticks");
        assertEq(protocol.getTotalLongPositions(), 0, "same batch did not clear positions");
        assertEq(protocol.getTotalExpo(), 0, "same batch did not clear exposure");
        assertEq(protocol.getBalanceLong(), 1, "source must commit exact one-wei residue without sink");
    }
}
