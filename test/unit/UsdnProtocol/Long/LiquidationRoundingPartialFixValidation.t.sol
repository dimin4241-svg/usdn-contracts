// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Adversarial safety test for the fix when liquidation is NON-terminal.
/// Two top ticks are removed but a lower ordinary tick remains. This targets the
/// strongest fix-specific objection: reconciliation must not merely zero dust on
/// final batches; it must reconstruct the correct balance from the remaining
/// accumulator/exposure without over-transferring to the vault.
contract TestLiquidationRoundingPartialFixValidation is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;
    uint128 internal constant STAGE_PRICE = 1771 ether;
    uint128 internal constant PARTIAL_PRICE = 1725 ether;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);
    address internal constant USER_C = address(0xC0DE);
    address internal constant PUBLIC_LIQUIDATOR = address(0xA11CE);

    PositionId internal posA;
    PositionId internal posB;
    PositionId internal posC;

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

        vm.deal(SUPPORT_USER, 10 ether);
        vm.deal(USER_A, 10 ether);
        vm.deal(USER_B, 10 ether);
        vm.deal(USER_C, 10 ether);
        vm.deal(PUBLIC_LIQUIDATOR, 1 ether);
        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "production action iteration");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer installed");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap positions gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap expo gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap balance gone");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));

        PositionId memory support = setUpUserPositionInLong(
            OpenParams(SUPPORT_USER, ProtocolAction.ValidateOpenPosition, 20 ether, 1772 ether, ENTRY_PRICE)
        );
        posA = setUpUserPositionInLong(
            OpenParams(USER_A, ProtocolAction.ValidateOpenPosition, 2 ether, 1760 ether, ENTRY_PRICE)
        );
        posB = setUpUserPositionInLong(
            OpenParams(USER_B, ProtocolAction.ValidateOpenPosition, 2 ether, 1740 ether, ENTRY_PRICE)
        );
        posC = setUpUserPositionInLong(
            OpenParams(USER_C, ProtocolAction.ValidateOpenPosition, 2 ether, 1728 ether, ENTRY_PRICE)
        );

        assertEq(support.tick, 74_800, "support tick");
        assertEq(posA.tick, 74_700, "A tick");
        assertEq(posB.tick, 74_600, "B tick");
        assertEq(posC.tick, 74_500, "C tick");

        _waitDelay();
        _waitDelay();
        Types.LiqTickInfo[] memory staged = protocol.liquidate(abi.encode(STAGE_PRICE));
        assertEq(staged.length, 1, "support staged alone");
        assertGt(staged[0].remainingCollateral, 0, "support stage not bad debt");
        assertEq(protocol.getTotalLongPositions(), 3, "A+B+C remain");

        _waitDelay();
        _waitDelay();

        assertLt(protocol.getEffectivePriceForTick(posA.tick), 1800 ether, "sanity A boundary");
        assertGt(protocol.getEffectivePriceForTick(posA.tick), PARTIAL_PRICE, "A liquidatable");
        assertGt(protocol.getEffectivePriceForTick(posB.tick), PARTIAL_PRICE, "B liquidatable");
        assertLt(protocol.getEffectivePriceForTick(posC.tick), PARTIAL_PRICE, "C must remain");
    }

    function test_A_publicNonterminalLiquidationSucceedsWithProductionRebalancer() public {
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer enabled");
        assertTrue(PUBLIC_LIQUIDATOR != protocol.defaultAdmin(), "caller not admin");
        assertTrue(PUBLIC_LIQUIDATOR != managers.setExternalManager, "caller not external manager");

        vm.startPrank(PUBLIC_LIQUIDATOR, PUBLIC_LIQUIDATOR);
        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(PARTIAL_PRICE));
        vm.stopPrank();

        assertEq(ticks.length, 2, "exactly A+B liquidated");
        assertGt(ticks[0].remainingCollateral, 0, "A not bad debt");
        assertGt(ticks[1].remainingCollateral, 0, "B not bad debt");
        assertEq(protocol.getTotalLongPositions(), 1, "C remains");
        assertEq(protocol.getHighestPopulatedTick(), posC.tick, "C is highest remaining tick");
        assertGt(protocol.getTotalExpo(), 0, "remaining exposure is nonzero");
        assertLe(protocol.getBalanceLong(), protocol.getTotalExpo(), "production invariant preserved");
    }

    function test_B_reconciledBalanceEqualsIndependentValueOfSoleRemainingPosition() public {
        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));

        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(PARTIAL_PRICE));
        assertEq(ticks.length, 2, "exactly A+B liquidated");
        assertEq(protocol.getTotalLongPositions(), 1, "only C remains");

        (Types.Position memory remaining,) = protocol.getLongPosition(posC);
        assertTrue(remaining.validated, "C remains validated");
        assertEq(protocol.getTotalExpo(), remaining.totalExpo, "global exposure equals sole remaining position");

        int24 tickWithoutPenalty = protocol.i_calcTickWithoutPenalty(posC.tick);
        uint256 liqPriceWithoutPenalty = protocol.getEffectivePriceForTick(tickWithoutPenalty);
        int256 independentValue = protocol.i_positionValue(
            remaining.totalExpo, PARTIAL_PRICE, uint128(liqPriceWithoutPenalty)
        );
        assertGt(independentValue, 0, "remaining position has positive value");
        assertEq(
            protocol.getBalanceLong(),
            uint256(independentValue),
            "reconciled long balance equals independent value of sole remaining position"
        );
        assertLt(protocol.getBalanceLong(), protocol.getTotalExpo(), "remaining trading exposure stays positive");
    }

    function test_C_reconciliationPreservesAggregateAccountingIncludingFeesAndLiquidatorReward() public {
        // PnL/funding redistributes between long and vault. Funding protocol fee
        // is removed from the two side balances but accumulated separately in
        // pendingProtocolFee. Liquidation rewards are a real external wstETH
        // outflow, so they must be added back when comparing the internal
        // accounting total across the call.
        uint256 totalBefore =
            protocol.getBalanceLong() + protocol.getBalanceVault() + protocol.getPendingProtocolFee();
        uint256 liquidatorBalanceBefore = wstETH.balanceOf(address(this));
        uint256 protocolAssetBefore = wstETH.balanceOf(address(protocol));

        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));
        protocol.liquidate(abi.encode(PARTIAL_PRICE));

        uint256 totalAfter =
            protocol.getBalanceLong() + protocol.getBalanceVault() + protocol.getPendingProtocolFee();
        uint256 liquidatorReward = wstETH.balanceOf(address(this)) - liquidatorBalanceBefore;
        uint256 protocolAssetAfter = wstETH.balanceOf(address(protocol));

        assertGt(liquidatorReward, 0, "liquidation reward must be nonzero in production-like config");
        assertEq(
            protocolAssetBefore - protocolAssetAfter,
            liquidatorReward,
            "liquidator reward is the only external asset outflow"
        );
        assertEq(
            totalAfter + liquidatorReward,
            totalBefore,
            "reconciliation conserves long+vault+accrued-fee accounting net of reward"
        );
    }

    function testFuzz_D_partialBatchLeavesExactValueForSoleRemainingPosition(uint16 wholeDollarPrice) public {
        // Search the entire coarse-price interval where A+B are liquidatable but C is not.
        // This challenges a subtler failure mode: a partial multi-tick batch could keep
        // balanceLong <= totalExpo (so the safety sink does not fire) while still leaving
        // a latent one-wei accounting drift that only surfaces in a later batch.
        wholeDollarPrice = uint16(bound(wholeDollarPrice, 1720, 1735));
        uint128 price = uint128(uint256(wholeDollarPrice) * 1 ether);

        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));

        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(price));
        assertEq(ticks.length, 2, "coarse price must liquidate exactly A+B");
        assertEq(protocol.getTotalLongPositions(), 1, "C must be sole remaining position");

        (Types.Position memory remaining,) = protocol.getLongPosition(posC);
        assertTrue(remaining.validated, "C remains validated");
        assertEq(protocol.getTotalExpo(), remaining.totalExpo, "aggregate expo equals C");

        int24 tickWithoutPenalty = protocol.i_calcTickWithoutPenalty(posC.tick);
        uint256 liqPriceWithoutPenalty = protocol.getEffectivePriceForTick(tickWithoutPenalty);
        int256 independentValue =
            protocol.i_positionValue(remaining.totalExpo, price, uint128(liqPriceWithoutPenalty));

        assertGt(independentValue, 0, "C value remains positive");
        assertEq(
            protocol.getBalanceLong(),
            uint256(independentValue),
            "partial multi-tick batch left latent long-balance rounding drift"
        );
    }

    function testFuzz_E_partialBatchArbitraryPriceLeavesNoLatentDrift(uint128 rawPrice) public {
        // The coarse-dollar witness above addresses oracle realism. This second search removes
        // that restriction and adversarially samples the full 18-decimal interval between
        // C's and B's liquidation boundaries. If independent per-tick flooring can leave a
        // hidden balance error while the global `balanceLong <= totalExpo` invariant still
        // holds, this assertion should expose it.
        uint128 price = uint128(bound(uint256(rawPrice), 1720 ether, 1736 ether));

        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));

        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(price));
        assertEq(ticks.length, 2, "arbitrary price must liquidate exactly A+B");
        assertEq(protocol.getTotalLongPositions(), 1, "C must remain");

        (Types.Position memory remaining,) = protocol.getLongPosition(posC);
        int24 tickWithoutPenalty = protocol.i_calcTickWithoutPenalty(posC.tick);
        uint256 liqPriceWithoutPenalty = protocol.getEffectivePriceForTick(tickWithoutPenalty);
        int256 independentValue =
            protocol.i_positionValue(remaining.totalExpo, price, uint128(liqPriceWithoutPenalty));

        assertGt(independentValue, 0, "C value remains positive");
        assertEq(
            protocol.getBalanceLong(),
            uint256(independentValue),
            "18-decimal partial batch left latent long-balance rounding drift"
        );
    }

    function test_F_partialThenFinalLiquidationDoesNotSurfaceLatentCorruption() public {
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer enabled");

        vm.prank(PUBLIC_LIQUIDATOR);
        Types.LiqTickInfo[] memory firstBatch = protocol.liquidate(abi.encode(PARTIAL_PRICE));
        assertEq(firstBatch.length, 2, "first batch liquidates A+B");
        assertEq(protocol.getTotalLongPositions(), 1, "C remains after first batch");
        assertLe(protocol.getBalanceLong(), protocol.getTotalExpo(), "state healthy after partial batch");

        _waitDelay();
        _waitDelay();

        // Stay below C's liquidation boundary but above its no-penalty price so the
        // final position is liquidated with positive collateral instead of bad debt.
        uint128 finalPrice = 1700 ether;
        assertGt(protocol.getEffectivePriceForTick(posC.tick), finalPrice, "C liquidatable at final price");
        int24 tickWithoutPenalty = protocol.i_calcTickWithoutPenalty(posC.tick);
        assertLt(protocol.getEffectivePriceForTick(tickWithoutPenalty), finalPrice, "C still has positive collateral");

        vm.prank(PUBLIC_LIQUIDATOR);
        Types.LiqTickInfo[] memory finalBatch = protocol.liquidate(abi.encode(finalPrice));

        assertEq(finalBatch.length, 1, "final batch liquidates only C");
        assertGt(finalBatch[0].remainingCollateral, 0, "C final liquidation is not bad debt");
        assertEq(protocol.getTotalLongPositions(), 0, "all ordinary positions removed");
        assertEq(protocol.getTotalExpo(), 0, "all exposure removed");
        assertEq(protocol.getBalanceLong(), 0, "no latent long-balance dust survives final batch");
        assertEq(protocol.getHighestPopulatedTick(), protocol.minTick(), "no populated long tick remains");
    }
}
