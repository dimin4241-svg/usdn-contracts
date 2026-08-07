// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";

/// @dev Diagnostic harness for the candidate invariant break:
///      after liquidating multiple ticks in one pass, rounding in per-tick values
///      may leave balanceLong > totalExpo by 1+ wei.
contract TestLiquidationRoundingInvariant is UsdnProtocolBaseFixture {
    error RoundingBreakFound(uint256 price, uint256 newLongBalance, uint256 newTotalExpo, int24 tick0, int24 tick1);

    PositionId internal secondPosition;

    function setUp() public {
        super._setUp(DEFAULT_PARAMS);

        // Initial position is around a 1000 USD liquidation price. Add a second
        // position in the adjacent liquidation band so both can be liquidated
        // while still carrying positive remaining collateral.
        secondPosition = setUpUserPositionInLong(
            OpenParams({
                user: address(this),
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 1 ether,
                desiredLiqPrice: 1010 ether,
                price: 2000 ether
            })
        );

        assertNotEq(secondPosition.tick, initialPosition.tick, "need two distinct ticks");
    }

    function test_probeMultiTickRoundingBreak() public {
        int24 tick0 = initialPosition.tick;
        int24 tick1 = secondPosition.tick;

        uint128 withPenalty0 = protocol.getEffectivePriceForTick(tick0);
        uint128 withPenalty1 = protocol.getEffectivePriceForTick(tick1);
        uint128 withoutPenalty0 = protocol.getEffectivePriceForTick(protocol.i_calcTickWithoutPenalty(tick0));
        uint128 withoutPenalty1 = protocol.getEffectivePriceForTick(protocol.i_calcTickWithoutPenalty(tick1));

        uint128 minWithPenalty = withPenalty0 < withPenalty1 ? withPenalty0 : withPenalty1;
        uint128 maxWithoutPenalty = withoutPenalty0 > withoutPenalty1 ? withoutPenalty0 : withoutPenalty1;

        // Both ticks must be liquidatable while both values remain positive.
        assertLt(maxWithoutPenalty, minWithPenalty, "no common positive-collateral liquidation window");

        // Search only 4096 consecutive wei. If the accounting identity is exact
        // after integer rounding this never fires; if per-tick floors accumulate,
        // a 1-wei residue should occur frequently in this window.
        uint256 end = uint256(maxWithoutPenalty) + 4096;
        if (end > minWithPenalty) end = minWithPenalty;

        for (uint256 p = uint256(maxWithoutPenalty) + 1; p <= end; ++p) {
            uint256 snapshot = vm.snapshotState();
            uint128 price = uint128(p);

            uint256 balanceLong = protocol.longAssetAvailableWithFunding(price, uint128(block.timestamp));
            uint256 balanceVault = protocol.vaultAssetAvailableWithFunding(price, uint128(block.timestamp));

            LiquidationsEffects memory effects =
                protocol.i_liquidatePositions(price, 2, int256(balanceLong), int256(balanceVault));
            uint256 newTotalExpo = protocol.getTotalExpo();

            if (effects.liquidatedTicks.length == 2 && effects.newLongBalance > newTotalExpo) {
                revert RoundingBreakFound(p, effects.newLongBalance, newTotalExpo, tick0, tick1);
            }

            vm.revertToState(snapshot);
        }

        fail("no multi-tick rounding break found in search window");
    }
}
