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

    /// @dev Time-shift controls answer the keeper-retry objection. Each Foundry test starts from the same freshly
    /// built witness, then advances wall-clock time before calling the dedicated endpoint. MockOracleMiddleware
    /// derives a fresh liquidation timestamp from the shifted block time, so funding/PnL are recomputed rather than
    /// replaying the original oracle snapshot. We only claim the concrete window that these tests actually prove.
    function test_D01_dedicatedLiquidationStillRevertsAfterOneSecond() public {
        _assertTimeShiftedDedicatedRetry(1 seconds);
    }

    function test_D05_dedicatedLiquidationStillRevertsAfterFiveSeconds() public {
        _assertTimeShiftedDedicatedRetry(5 seconds);
    }

    function test_D10_dedicatedLiquidationStillRevertsAfterTenSeconds() public {
        _assertTimeShiftedDedicatedRetry(10 seconds);
    }

    function test_D30_dedicatedLiquidationStillRevertsAfterThirtySeconds() public {
        _assertTimeShiftedDedicatedRetry(30 seconds);
    }

    /// @dev These intermediate points deliberately accept either of the two causally meaningful outcomes:
    /// (a) the same two-tick batch reaches the Rebalancer invariant and atomically rolls back, or
    /// (b) the liquidation set has changed and the endpoint makes real progress. The -vvvv trace tells us which.
    /// In either case the test proves that there is no third silent/corrupt state transition.
    function test_D40_characterizeDedicatedLiquidationAfterFortySeconds() public {
        _characterizeTimeShiftedDedicatedRetry(40 seconds);
    }

    function test_D45_characterizeDedicatedLiquidationAfterFortyFiveSeconds() public {
        _characterizeTimeShiftedDedicatedRetry(45 seconds);
    }

    function test_D50_characterizeDedicatedLiquidationAfterFiftySeconds() public {
        _characterizeTimeShiftedDedicatedRetry(50 seconds);
    }

    function test_D55_characterizeDedicatedLiquidationAfterFiftyFiveSeconds() public {
        _characterizeTimeShiftedDedicatedRetry(55 seconds);
    }

    /// @dev At +60s the funding-adjusted liquidation threshold moves enough that only the highest witness tick is
    /// liquidated. That shrinks the dedicated batch from two ticks to one, so the sum-of-per-tick-floors mismatch
    /// is no longer present and the public endpoint can finally commit progress.
    function test_D60_dedicatedLiquidationProgressesWhenBatchShrinksToOneTick() public {
        uint256 positionsBefore = protocol.getTotalLongPositions();
        uint256 liquidatorAssetBefore = wstETH.balanceOf(address(this));

        vm.warp(block.timestamp + 60 seconds);
        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(finalPrice));

        assertEq(ticks.length, 1, "sixty-second retry should liquidate exactly one tick");
        assertEq(protocol.getTotalLongPositions(), positionsBefore - 1, "sixty-second retry made wrong progress");
        assertEq(protocol.getHighestPopulatedTick(), posB.tick, "lower witness tick should remain populated");
        assertGt(wstETH.balanceOf(address(this)), liquidatorAssetBefore, "successful retry must pay liquidator");
        assertLe(protocol.getBalanceLong(), protocol.getTotalExpo(), "successful retry must preserve long/expo invariant");
    }

    function _assertTimeShiftedDedicatedRetry(uint256 shift) internal {
        uint256 positionsBefore = protocol.getTotalLongPositions();
        int24 highestBefore = protocol.getHighestPopulatedTick();
        uint256 expoBefore = protocol.getTotalExpo();
        uint256 longBalanceBefore = protocol.getBalanceLong();
        uint256 vaultBalanceBefore = protocol.getBalanceVault();
        int256 pendingVaultBefore = protocol.getPendingBalanceVault();
        uint256 pendingFeeBefore = protocol.getPendingProtocolFee();
        uint256 protocolAssetBefore = wstETH.balanceOf(address(protocol));
        uint256 liquidatorAssetBefore = wstETH.balanceOf(address(this));
        uint256 tickAVersionBefore = protocol.getTickVersion(posA.tick);
        uint256 tickBVersionBefore = protocol.getTickVersion(posB.tick);

        vm.warp(block.timestamp + shift);

        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(finalPrice));

        assertEq(protocol.getTotalLongPositions(), positionsBefore, "time-shift retry changed position count");
        assertEq(protocol.getHighestPopulatedTick(), highestBefore, "time-shift retry changed highest tick");
        assertEq(protocol.getTotalExpo(), expoBefore, "time-shift retry changed total exposure");
        assertEq(protocol.getBalanceLong(), longBalanceBefore, "time-shift retry changed long balance");
        assertEq(protocol.getBalanceVault(), vaultBalanceBefore, "time-shift retry changed vault balance");
        assertEq(protocol.getPendingBalanceVault(), pendingVaultBefore, "time-shift retry changed pending vault balance");
        assertEq(protocol.getPendingProtocolFee(), pendingFeeBefore, "time-shift retry changed pending protocol fee");
        assertEq(wstETH.balanceOf(address(protocol)), protocolAssetBefore, "time-shift retry changed protocol assets");
        assertEq(wstETH.balanceOf(address(this)), liquidatorAssetBefore, "time-shift retry paid liquidator");
        assertEq(protocol.getTickVersion(posA.tick), tickAVersionBefore, "time-shift retry changed tick A version");
        assertEq(protocol.getTickVersion(posB.tick), tickBVersionBefore, "time-shift retry changed tick B version");
    }

    function _characterizeTimeShiftedDedicatedRetry(uint256 shift) internal {
        uint256 positionsBefore = protocol.getTotalLongPositions();
        int24 highestBefore = protocol.getHighestPopulatedTick();
        uint256 expoBefore = protocol.getTotalExpo();
        uint256 longBalanceBefore = protocol.getBalanceLong();
        uint256 vaultBalanceBefore = protocol.getBalanceVault();
        int256 pendingVaultBefore = protocol.getPendingBalanceVault();
        uint256 pendingFeeBefore = protocol.getPendingProtocolFee();
        uint256 protocolAssetBefore = wstETH.balanceOf(address(protocol));
        uint256 liquidatorAssetBefore = wstETH.balanceOf(address(this));

        vm.warp(block.timestamp + shift);

        try protocol.liquidate(abi.encode(finalPrice)) returns (Types.LiqTickInfo[] memory ticks) {
            assertGt(ticks.length, 0, "successful characterization retry must liquidate at least one tick");
            assertLt(protocol.getTotalLongPositions(), positionsBefore, "successful characterization retry made no progress");
            assertGt(wstETH.balanceOf(address(this)), liquidatorAssetBefore, "successful characterization retry paid no reward");
            assertLe(protocol.getBalanceLong(), protocol.getTotalExpo(), "successful characterization retry broke invariant");
        } catch (bytes memory reason) {
            assertEq(
                keccak256(reason),
                keccak256(abi.encodeWithSelector(UsdnProtocolInvalidLongExpo.selector)),
                "characterization retry reverted for unexpected reason"
            );
            assertEq(protocol.getTotalLongPositions(), positionsBefore, "reverted characterization changed position count");
            assertEq(protocol.getHighestPopulatedTick(), highestBefore, "reverted characterization changed highest tick");
            assertEq(protocol.getTotalExpo(), expoBefore, "reverted characterization changed total exposure");
            assertEq(protocol.getBalanceLong(), longBalanceBefore, "reverted characterization changed long balance");
            assertEq(protocol.getBalanceVault(), vaultBalanceBefore, "reverted characterization changed vault balance");
            assertEq(protocol.getPendingBalanceVault(), pendingVaultBefore, "reverted characterization changed pending vault");
            assertEq(protocol.getPendingProtocolFee(), pendingFeeBefore, "reverted characterization changed pending fee");
            assertEq(wstETH.balanceOf(address(protocol)), protocolAssetBefore, "reverted characterization changed assets");
            assertEq(wstETH.balanceOf(address(this)), liquidatorAssetBefore, "reverted characterization paid liquidator");
        }
    }
}
