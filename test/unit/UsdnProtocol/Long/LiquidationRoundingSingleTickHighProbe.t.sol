// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice High-severity probe: test whether multiple ordinary-user positions
/// aggregated inside ONE populated tick can still leave a positive rounding residue
/// when liquidationIteration == 1.
///
/// This specifically tests the strongest recovery-counterargument: user actions process
/// only one liquidation tick. If a single tick containing multiple positions can itself
/// end with newLongBalance > totalExpo, liquidationIteration=1 does not recover safely.
contract TestLiquidationRoundingSingleTickHighProbe is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;

    // Build a large balanced vault through the normal fixture equilibrium path.
    uint128 internal constant INITIAL_LONG = 20_000 ether;

    // Two public-user positions. Together they remain below the default open-imbalance
    // limit in this large vault, while their combined exposure is large enough to make
    // sub-wei effective-price rounding observable at the asset-wei level.
    uint128 internal constant TARGET_AMOUNT = 500 ether;
    uint128 internal constant TARGET_DESIRED_LIQ = 1250 ether;

    address internal constant TRADER_A = address(0xBEEF);
    address internal constant TRADER_B = address(0xCAFE);

    PositionId internal targetPosA;
    PositionId internal targetPosB;

    event SingleTickWitness(
        uint256 oraclePrice,
        int24 tick,
        uint256 positionsInTick,
        uint256 totalExpoBefore,
        int256 tempLongBalance,
        int256 remainingCollateral,
        uint256 newLongBalance,
        uint256 totalExpoAfter
    );

    function setUp() public {
        params = DEFAULT_PARAMS;
        params.initialDeposit = 0; // exact equilibrium, calculated by the fixture
        params.initialLong = INITIAL_LONG;
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

        vm.deal(TRADER_A, 10 ether);
        vm.deal(TRADER_B, 10 ether);
        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "user-action liquidation iteration");
        assertGt(protocol.getMaxLeverage(), 10 ** 21, "max leverage must exceed 1x");
        assertEq(protocol.getSafetyMarginBps(), 200, "default safety margin");
        assertGt(protocol.getOpenExpoImbalanceLimitBps(), 0, "open imbalance limit must remain enabled");
        assertGt(protocol.getCloseExpoImbalanceLimitBps(), 0, "close imbalance limit must remain enabled");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "Rebalancer installed");

        // Remove the initialization-created long through the real liquidation endpoint.
        // This leaves a large vault side without bypassing the production imbalance limits.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap long must be gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap exposure must be gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap long balance must be gone");

        // Reset lastPrice to the normal entry price before opening public positions.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "price reset keeps empty long side");

        targetPosA = setUpUserPositionInLong(
            OpenParams(TRADER_A, ProtocolAction.ValidateOpenPosition, TARGET_AMOUNT, TARGET_DESIRED_LIQ, ENTRY_PRICE)
        );
        targetPosB = setUpUserPositionInLong(
            OpenParams(TRADER_B, ProtocolAction.ValidateOpenPosition, TARGET_AMOUNT, TARGET_DESIRED_LIQ, ENTRY_PRICE)
        );

        assertEq(protocol.getTotalLongPositions(), 2, "exactly two public-user long positions");
        assertEq(targetPosA.tick, targetPosB.tick, "both public positions must aggregate into the same tick");
        assertEq(protocol.getHighestPopulatedTick(), targetPosA.tick, "target must be highest/only populated tick");
        assertEq(targetPosA.tickVersion, targetPosB.tickVersion, "same active tick version");
        assertTrue(targetPosA.index != targetPosB.index, "positions must be distinct entries inside the tick");
        assertGt(protocol.getTotalExpo(), 2500 ether, "combined exposure must amplify sub-wei rounding");

        _waitBeforeLiquidation();
    }

    /// @dev Searches every whole-dollar oracle price inside the single aggregated tick's
    /// positive-collateral liquidation window. Every candidate is executed against the
    /// vulnerable liquidation helper with iteration=1, then rolled back.
    function test_probeMultiplePositionsInsideSingleTick() public {
        uint256 tickBoundary = protocol.getEffectivePriceForTick(targetPosA.tick);
        int24 noPenaltyTick = protocol.i_calcTickWithoutPenalty(targetPosA.tick);
        uint256 noPenaltyBoundary = protocol.getEffectivePriceForTick(noPenaltyTick);

        assertGt(tickBoundary, noPenaltyBoundary, "need positive-collateral liquidation window");

        uint256 firstDollar = noPenaltyBoundary / 1 ether + 1;
        uint256 lastDollar = (tickBoundary - 1) / 1 ether;
        assertLe(firstDollar, lastDollar, "need at least one whole-dollar price in window");

        uint256 totalExpoBefore = protocol.getTotalExpo();
        assertGt(totalExpoBefore, 2500 ether, "combined tick exposure must be large enough");

        for (uint256 dollars = firstDollar; dollars <= lastDollar; ++dollars) {
            uint256 snapshot = vm.snapshotState();
            uint128 price = uint128(dollars * 1 ether);

            Types.ApplyPnlAndFundingData memory pnl =
                protocol.i_applyPnlAndFunding(price, uint128(block.timestamp - 30 seconds));
            Types.LiquidationsEffects memory effects =
                protocol.i_liquidatePositions(price, 1, pnl.tempLongBalance, pnl.tempVaultBalance);

            if (
                effects.liquidatedTicks.length == 1
                    && effects.liquidatedTicks[0].totalPositions == 2
                    && protocol.getTotalExpo() == 0
                    && effects.newLongBalance > protocol.getTotalExpo()
            ) {
                emit SingleTickWitness(
                    price,
                    targetPosA.tick,
                    effects.liquidatedTicks[0].totalPositions,
                    totalExpoBefore,
                    pnl.tempLongBalance,
                    effects.liquidatedTicks[0].remainingCollateral,
                    effects.newLongBalance,
                    protocol.getTotalExpo()
                );
                assertGt(effects.newLongBalance, 0, "single-tick multi-position residue must be positive");
                return;
            }

            vm.revertToState(snapshot);
        }

        assertTrue(false, "no multi-position single-tick residue found");
    }
}
