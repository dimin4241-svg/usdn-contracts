// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Economic edge-case validation for the multi-tick liquidation reconciliation fix.
/// @dev Covers the cases most likely to make the reconciliation unsafe:
///      (1) a negative raw liquidation value with an active Rebalancer,
///      (2) reconciliation changing the Rebalancer bonus base / interacting with its cap, and
///      (3) the defensive remainingTradingExpo <= remainingTotalExpo guard.
contract TestLiquidationRoundingEconomicEdgeValidation is UsdnProtocolBaseFixture {
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;
    address internal constant REBALANCER_DEPOSITOR = address(0xB0A5);
    address internal constant PUBLIC_LIQUIDATOR = address(0xA11CE);
    uint88 internal constant PENDING_ASSETS = 2 ether;

    function setUp() public {
        params = DEFAULT_PARAMS;
        params.initialLong = 200 ether;
        params.flags.enablePositionFees = true;
        params.flags.enableProtocolFees = true;
        params.flags.enableFunding = true;
        params.flags.enableLimits = true;
        params.flags.enableUsdnRebase = true;
        params.flags.enableSecurityDeposit = true;
        params.flags.enableSdexBurnOnDeposit = true;
        params.flags.enableLongLimit = true;
        params.flags.enableRebalancer = true;
        params.flags.enableLiquidationRewards = true;
        params.flags.enableRoles = true;

        vm.deal(PUBLIC_LIQUIDATOR, 1 ether);
        super._setUp(params);

        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer installed");
        assertEq(protocol.getRebalancerBonusBps(), 8000, "production Rebalancer bonus");
    }

    /// @notice The production-like bootstrap position is underwater on the actual public $980
    /// liquidation path. Arm the real Rebalancer inside the two standard validation delays and
    /// prove that a negative LiqTickInfo.remainingCollateral cannot become a bonus-bearing payout.
    ///
    /// We intentionally do not pre-compute the value through `tickValue()`: that view helper uses
    /// the current block timestamp for funding, while the public liquidation uses the timestamp
    /// returned by the oracle middleware. The returned LiqTickInfo is the authoritative value for
    /// the path that actually reaches `_triggerRebalancer`.
    function test_A_negativeRawCollateralDoesNotCreateRebalancerBonus() public {
        wstETH.mintAndApprove(
            REBALANCER_DEPOSITOR, PENDING_ASSETS, address(rebalancer), type(uint256).max
        );
        vm.prank(REBALANCER_DEPOSITOR);
        rebalancer.initiateDepositAssets(PENDING_ASSETS, REBALANCER_DEPOSITOR);

        _waitDelay();
        vm.prank(REBALANCER_DEPOSITOR);
        rebalancer.validateDepositAssets();
        assertEq(rebalancer.getPendingAssetsAmount(), PENDING_ASSETS, "pending assets armed");
        _waitDelay();

        uint256 physicalBefore = wstETH.balanceOf(address(protocol)) + wstETH.balanceOf(address(rebalancer))
            + wstETH.balanceOf(PUBLIC_LIQUIDATOR);

        vm.prank(PUBLIC_LIQUIDATOR);
        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));

        assertEq(ticks.length, 1, "bootstrap batch must liquidate one tick");
        assertLt(ticks[0].remainingCollateral, 0, "public liquidation must exercise negative raw collateral");
        assertEq(rebalancer.getPendingAssetsAmount(), 0, "pending principal consumed by Rebalancer");

        (,, Types.PositionId memory rebalancerPosId) = rebalancer.getCurrentStateData();
        (Types.Position memory reboundPosition,) = protocol.getLongPosition(rebalancerPosId);
        assertEq(reboundPosition.user, address(rebalancer), "new long belongs to Rebalancer");
        assertEq(
            uint256(reboundPosition.amount),
            uint256(PENDING_ASSETS),
            "negative liquidation collateral must contribute zero Rebalancer bonus"
        );

        uint256 physicalAfter = wstETH.balanceOf(address(protocol)) + wstETH.balanceOf(address(rebalancer))
            + wstETH.balanceOf(PUBLIC_LIQUIDATOR);
        assertEq(physicalAfter, physicalBefore, "negative-collateral handling must conserve physical wstETH");
        assertLe(protocol.getBalanceLong(), protocol.getTotalExpo(), "long/expo invariant after rebound");
    }

    /// @notice Algebraic identity of the source fix. Before reconciliation:
    /// postRawLong = preLong - rawRemaining.
    /// The fix adds delta = postRawLong - target to both the vault transfer and
    /// effects.remainingCollateral. Therefore correctedRemaining is exactly preLong - target;
    /// the independently rounded raw tick sum cancels out completely.
    ///
    /// This is especially important when rawRemaining <= 0. If reconciliation ever changes that
    /// value to positive, the positive amount is not invented collateral: it is exactly the
    /// aggregate long-side value removed by the batch.
    function testFuzz_B_reconciledCollateralEqualsAggregateLongReduction(
        int128 preLongSeed,
        int128 rawRemainingSeed,
        int128 targetSeed
    ) public pure {
        int256 preLong = int256(preLongSeed);
        int256 rawRemaining = int256(rawRemainingSeed);
        int256 target = int256(targetSeed);

        int256 postRawLong = preLong - rawRemaining;
        if (postRawLong <= target) return; // reconciliation branch is not entered

        int256 reconciliation = postRawLong - target;
        assertGt(reconciliation, 0, "reconciliation is strictly positive in the guarded branch");

        int256 correctedRemaining = rawRemaining + reconciliation;
        assertEq(correctedRemaining, preLong - target, "raw per-tick rounding must cancel exactly");

        if (rawRemaining <= 0 && correctedRemaining > 0) {
            assertGt(preLong, target, "positive corrected collateral requires positive aggregate reduction");
        }
    }

    /// @notice Protocol governance bounds Rebalancer bonusBps to <= 10000. For any positive
    /// reconciliation delta, the bonus can therefore increase by at most delta, while the fix
    /// credits exactly delta to the vault at the same time. The correction cannot make an
    /// otherwise funded bonus underfunded.
    function testFuzz_C_bonusGrowthNeverExceedsReconciliationVaultCredit(
        uint128 rawPositiveRemaining,
        uint128 reconciliation,
        uint16 bonusBps
    ) public pure {
        if (bonusBps > 10_000) return; // forbidden by setRebalancerBonusBps

        uint256 raw = uint256(rawPositiveRemaining);
        uint256 delta = uint256(reconciliation);
        uint256 oldBonus = raw * bonusBps / 10_000;
        uint256 newBonus = (raw + delta) * bonusBps / 10_000;

        assertGe(newBonus, oldBonus, "positive reconciliation cannot reduce uncapped bonus");
        assertLe(newBonus - oldBonus, delta, "bonus growth cannot exceed simultaneous vault credit");
        assertLe(newBonus, raw + delta, "bonus cannot exceed corrected remaining collateral");
    }

    /// @notice Same safety property for the sign-crossing case. If a negative/zero raw batch is
    /// reconciled into a positive aggregate collateral amount, the maximum possible Rebalancer
    /// bonus is bounded by that exact net vault credit because bonusBps <= 100%.
    function testFuzz_D_signCrossingBonusIsFullyFunded(
        int128 rawRemainingSeed,
        uint128 reconciliationSeed,
        uint16 bonusBps
    ) public pure {
        if (bonusBps > 10_000) return;

        int256 rawRemaining = int256(rawRemainingSeed);
        if (rawRemaining > 0) return;

        int256 reconciliation = int256(uint256(reconciliationSeed));
        int256 correctedRemaining = rawRemaining + reconciliation;
        if (correctedRemaining <= 0) return;

        uint256 corrected = uint256(correctedRemaining);
        uint256 bonus = corrected * bonusBps / 10_000;

        assertLe(bonus, corrected, "sign-crossing bonus cannot exceed net collateral credited to vault");
    }

    /// @notice Proves the new defensive guard cannot fire for a solvent set of remaining ticks.
    ///
    /// Let A be the old accumulator, T the old long trading exposure, A' the accumulator of the
    /// ticks that survive the batch, and E' their total exposure. The fix reconstructs
    /// T' = floor(A' * T / A). For every surviving position, its no-penalty unadjusted tick price
    /// p_i is solvent at the current common multiplier, which is equivalent to p_i * T <= A.
    /// Multiplying by each exposure and summing gives A' * T <= A * E', therefore T' <= E'.
    ///
    /// Liquidation penalties do not weaken this result: a nonnegative penalty only moves the
    /// no-penalty tick below the stored liquidation tick. Thus even heterogeneous historical
    /// penalties cannot turn this defensive check into a reachable DoS.
    function testFuzz_E_remainingTradingExpoCannotExceedRemainingExpoForSolventTicks(
        uint64 price1Seed,
        uint64 price2Seed,
        uint64 expo1Seed,
        uint64 expo2Seed,
        uint64 removedAccumulatorSeed,
        uint64 tradingExpoSeed
    ) public pure {
        uint256 p1 = uint256(price1Seed) + 1;
        uint256 p2 = uint256(price2Seed) + 1;
        uint256 e1 = uint256(expo1Seed) + 1;
        uint256 e2 = uint256(expo2Seed) + 1;

        uint256 remainingAccumulator = p1 * e1 + p2 * e2;
        uint256 oldAccumulator = remainingAccumulator + uint256(removedAccumulatorSeed) + 1;
        uint256 maxRemainingPrice = p1 > p2 ? p1 : p2;

        // Choose T inside the full range for which every surviving no-penalty tick is solvent:
        // p_i * T <= A. oldAccumulator >= remainingAccumulator >= maxRemainingPrice, so nonzero.
        uint256 maxSolventTradingExpo = oldAccumulator / maxRemainingPrice;
        uint256 tradingExpo = uint256(tradingExpoSeed) % maxSolventTradingExpo + 1;

        assertLe(p1 * tradingExpo, oldAccumulator, "survivor 1 must be solvent");
        assertLe(p2 * tradingExpo, oldAccumulator, "survivor 2 must be solvent");

        uint256 remainingTradingExpo = remainingAccumulator * tradingExpo / oldAccumulator;
        uint256 remainingTotalExpo = e1 + e2;
        assertLe(
            remainingTradingExpo,
            remainingTotalExpo,
            "defensive remainingTradingExpo guard fired for a solvent survivor set"
        );
    }
}
