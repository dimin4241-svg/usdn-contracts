// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestLiquidationRoundingPostBootstrapWholeDollarFixValidation } from "./LiquidationRoundingPostBootstrapWholeDollarFixValidation.t.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Green-side symmetry control for the exact vulnerable whole-dollar fixture.
/// Pins the same prestate values as the vulnerable branch, then proves that changing
/// only the liquidation accounting code turns the atomic revert into committed progress.
contract TestLiquidationRoundingPostBootstrapWholeDollarFixSymmetry is
    TestLiquidationRoundingPostBootstrapWholeDollarFixValidation
{
    uint256 internal constant EXPECTED_PRESTATE_POSITIONS = 2;
    uint256 internal constant EXPECTED_PRESTATE_EXPO = 18_299_478_101_274_206_497;
    uint256 internal constant EXPECTED_PRESTATE_LONG = 971_462_201_938_421_127;
    uint256 internal constant EXPECTED_PRESTATE_TIMESTAMP = 1_704_092_721;

    function test_exactPrestateThenPatchedBatchCommitsAndPaysReward() public {
        assertEq(protocol.getTotalLongPositions(), EXPECTED_PRESTATE_POSITIONS, "same prestate positions");
        assertEq(protocol.getTotalExpo(), EXPECTED_PRESTATE_EXPO, "same prestate exposure");
        assertEq(protocol.getBalanceLong(), EXPECTED_PRESTATE_LONG, "same prestate long balance");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "same prestate highest tick");
        assertEq(block.timestamp, EXPECTED_PRESTATE_TIMESTAMP, "same prestate timestamp");
        assertEq(uint256(FINAL_PRICE), 1_586 ether, "same final whole-dollar price");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "same production Rebalancer");

        uint256 liquidatorBefore = wstETH.balanceOf(PUBLIC_LIQUIDATOR);
        assertEq(liquidatorBefore, 0, "same liquidator prestate");

        vm.startPrank(PUBLIC_LIQUIDATOR, PUBLIC_LIQUIDATOR);
        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(FINAL_PRICE));
        vm.stopPrank();

        uint256 liquidatorAfter = wstETH.balanceOf(PUBLIC_LIQUIDATOR);
        assertEq(ticks.length, 2, "patched exact batch commits A+B");
        assertEq(ticks[0].totalExpo, EXPECTED_A_EXPO, "same tick A expo");
        assertEq(ticks[1].totalExpo, EXPECTED_B_EXPO, "same tick B expo");
        assertEq(uint256(ticks[0].remainingCollateral), EXPECTED_A_REMAINING, "same tick A floor");
        assertEq(uint256(ticks[1].remainingCollateral), EXPECTED_B_REMAINING, "same tick B floor");
        assertEq(protocol.getTotalLongPositions(), 0, "patched batch removes both positions");
        assertEq(protocol.getTotalExpo(), 0, "patched batch removes all exposure");
        assertEq(protocol.getBalanceLong(), 0, "patched batch reconciles residue");
        assertGt(liquidatorAfter, liquidatorBefore, "patched batch pays public liquidator reward");
    }
}
