// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestLiquidationRoundingPostBootstrapWholeDollarFixValidation } from
    "./LiquidationRoundingPostBootstrapWholeDollarFixValidation.t.sol";
import { IRebalancerTypes } from "../../../../src/interfaces/Rebalancer/IRebalancerTypes.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Adversarial validation for the interaction between liquidation-rounding reconciliation
/// and the production Rebalancer bonus. The exact whole-dollar A+B witness has a one-wei
/// aggregate reconciliation. With the production 80% bonus, that one wei crosses an integer
/// division boundary and increases the actual bonus by one wei. This regression proves that
/// the extra bonus is funded by the same reconciled collateral moved from long to vault
/// accounting and does not create any physical asset.
contract TestLiquidationRoundingRebalancerBonusValidation
    is TestLiquidationRoundingPostBootstrapWholeDollarFixValidation
{
    address internal constant REBALANCER_DEPOSITOR = address(0xB0A5);
    uint88 internal constant PENDING_ASSETS = 2 ether;

    function test_C_reconciliationBonusCarryIsExactlyFundedAndAssetConserving() public {
        uint256 rawRemaining = EXPECTED_A_REMAINING + EXPECTED_B_REMAINING;
        uint256 reconciliation = uint256(EXPECTED_TEMP_LONG_BALANCE) - rawRemaining;
        assertEq(reconciliation, 1, "exact whole-dollar witness reconciliation");

        uint256 bonusBps = protocol.getRebalancerBonusBps();
        assertEq(bonusBps, 8000, "production Rebalancer bonus must be 80 percent");

        uint256 bonusWithoutReconciliation = rawRemaining * bonusBps / 10_000;
        uint256 bonusWithReconciliation = (rawRemaining + reconciliation) * bonusBps / 10_000;
        assertEq(
            bonusWithReconciliation - bonusWithoutReconciliation,
            1,
            "the one-wei reconciliation must exercise the bonus rounding carry"
        );

        // Arm the real Rebalancer with validated pending assets. This forces the final
        // A+B liquidation to travel past the bonus calculation and actually open a new
        // Rebalancer position instead of returning through the empty-Rebalancer shortcut.
        wstETH.mintAndApprove(
            REBALANCER_DEPOSITOR, PENDING_ASSETS, address(rebalancer), type(uint256).max
        );
        vm.prank(REBALANCER_DEPOSITOR);
        rebalancer.initiateDepositAssets(PENDING_ASSETS, REBALANCER_DEPOSITOR);

        IRebalancerTypes.TimeLimits memory limits = rebalancer.getTimeLimits();
        skip(uint256(limits.validationDelay) + 1);

        vm.prank(REBALANCER_DEPOSITOR);
        rebalancer.validateDepositAssets();
        assertEq(rebalancer.getPendingAssetsAmount(), PENDING_ASSETS, "pending assets armed");

        // Include every address among which the final call is expected to move wstETH:
        // pending assets move Rebalancer -> protocol and liquidation rewards move
        // protocol -> liquidator. Reconciliation itself must not increase this sum.
        uint256 physicalBefore = wstETH.balanceOf(address(protocol)) + wstETH.balanceOf(address(rebalancer))
            + wstETH.balanceOf(PUBLIC_LIQUIDATOR);

        vm.prank(PUBLIC_LIQUIDATOR);
        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(FINAL_PRICE));

        assertEq(ticks.length, 2, "same final batch must liquidate A+B");
        assertEq(
            uint256(ticks[0].remainingCollateral) + uint256(ticks[1].remainingCollateral),
            rawRemaining,
            "per-tick liquidation outputs stay at their original floors"
        );
        assertEq(rebalancer.getPendingAssetsAmount(), 0, "pending assets consumed into new position");

        (,, Types.PositionId memory rebalancerPosId) = rebalancer.getCurrentStateData();
        (Types.Position memory reboundPosition,) = protocol.getLongPosition(rebalancerPosId);
        assertEq(reboundPosition.user, address(rebalancer), "new long must belong to Rebalancer");
        assertEq(
            uint256(reboundPosition.amount),
            uint256(PENDING_ASSETS) + bonusWithReconciliation,
            "new position collateral must equal pending principal plus funded bonus"
        );
        assertEq(
            uint256(reboundPosition.amount) - uint256(PENDING_ASSETS),
            bonusWithReconciliation,
            "no bonus exists beyond reconciled liquidation collateral"
        );

        uint256 physicalAfter = wstETH.balanceOf(address(protocol)) + wstETH.balanceOf(address(rebalancer))
            + wstETH.balanceOf(PUBLIC_LIQUIDATOR);
        assertEq(physicalAfter, physicalBefore, "reconciliation must not mint physical wstETH");

        assertLe(protocol.getBalanceLong(), protocol.getTotalExpo(), "post-Rebalancer long/expo invariant");
        assertGt(protocol.getTotalExpo(), 0, "new Rebalancer long should create exposure");
        assertGt(protocol.getBalanceLong(), 0, "new Rebalancer position should carry collateral");
    }
}
