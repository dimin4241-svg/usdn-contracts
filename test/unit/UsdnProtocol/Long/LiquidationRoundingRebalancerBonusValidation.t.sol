// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Adversarial validation for the interaction between liquidation-rounding reconciliation
/// and the production Rebalancer bonus.
///
/// The exact whole-dollar A+B witness has a one-wei aggregate reconciliation. With the production
/// 80% Rebalancer bonus, that one wei crosses an integer-division boundary and increases the actual
/// bonus by one wei. The Rebalancer deposit is initiated immediately after the support liquidation
/// and validated during the first of the two delays that already exist in the original witness.
/// Therefore the final liquidation runs at the exact same timestamp/funding state as the original
/// whole-dollar proof instead of perturbing it by waiting an extra validation period.
contract TestLiquidationRoundingRebalancerBonusValidation is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;

    uint128 internal constant SUPPORT_AMOUNT = 20 ether;
    uint128 internal constant USER_AMOUNT = 2 ether;
    uint128 internal constant SUPPORT_DESIRED_LIQ = 1652 ether;
    uint128 internal constant A_DESIRED_LIQ = 1619 ether;
    uint128 internal constant B_DESIRED_LIQ = 1587 ether;

    uint128 internal constant STAGE_PRICE = 1651 ether;
    uint128 internal constant FINAL_PRICE = 1586 ether;

    int24 internal constant EXPECTED_SUPPORT_TICK = 74_100;
    int24 internal constant EXPECTED_A_TICK = 73_800;
    int24 internal constant EXPECTED_B_TICK = 73_700;

    uint256 internal constant EXPECTED_SUPPORT_BOUNDARY = 1_651_618_152_449_355_129_548;
    uint256 internal constant EXPECTED_FINAL_BOUNDARY = 1_586_817_316_249_371_051_367;

    uint256 internal constant EXPECTED_A_EXPO = 9_313_831_717_478_013_209;
    uint256 internal constant EXPECTED_B_EXPO = 8_985_646_383_796_193_288;
    uint256 internal constant EXPECTED_A_PRICE_WITHOUT_PENALTY = 1_570_940_589_550_844_323_032;
    uint256 internal constant EXPECTED_B_PRICE_WITHOUT_PENALTY = 1_555_310_247_117_722_907_022;
    uint256 internal constant EXPECTED_A_REMAINING = 88_436_831_455_148_774;
    uint256 internal constant EXPECTED_B_REMAINING = 173_875_956_498_254_704;
    int256 internal constant EXPECTED_TEMP_LONG_BALANCE = 262_312_787_953_403_479;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);
    address internal constant PUBLIC_LIQUIDATOR = address(0xA11CE);
    address internal constant REBALANCER_DEPOSITOR = address(0xB0A5);
    uint88 internal constant PENDING_ASSETS = 2 ether;

    PositionId internal supportPos;
    PositionId internal posA;
    PositionId internal posB;

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
        vm.deal(PUBLIC_LIQUIDATOR, 1 ether);
        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "production action liquidation iteration");
        assertEq(protocol.getProtocolFeeBps(), 800, "production protocol fee");
        assertEq(protocol.getFundingSF(), 120, "production funding SF");
        assertEq(protocol.getMinLongPosition(), 2 ether, "production minimum long");
        assertGt(protocol.getCloseExpoImbalanceLimitBps(), 0, "production close imbalance limit");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer installed");
        assertEq(protocol.getRebalancerBonusBps(), 8000, "production Rebalancer bonus");
        assertTrue(managers.setExternalManager != managers.setProtocolParamsManager, "manager roles separated");
        assertTrue(managers.setExternalManager != protocol.defaultAdmin(), "external manager is not admin");

        // Destroy the initialization-created position and reset price exactly as in the
        // original whole-dollar witness.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap positions gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap exposure gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap long balance gone");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "price reset keeps no positions");
        assertEq(protocol.getTotalExpo(), 0, "price reset keeps zero exposure");
        assertEq(protocol.getBalanceLong(), 0, "price reset keeps zero long balance");

        supportPos = setUpUserPositionInLong(
            OpenParams(SUPPORT_USER, ProtocolAction.ValidateOpenPosition, SUPPORT_AMOUNT, SUPPORT_DESIRED_LIQ, ENTRY_PRICE)
        );
        posA = setUpUserPositionInLong(
            OpenParams(USER_A, ProtocolAction.ValidateOpenPosition, USER_AMOUNT, A_DESIRED_LIQ, ENTRY_PRICE)
        );
        posB = setUpUserPositionInLong(
            OpenParams(USER_B, ProtocolAction.ValidateOpenPosition, USER_AMOUNT, B_DESIRED_LIQ, ENTRY_PRICE)
        );

        assertEq(supportPos.tick, EXPECTED_SUPPORT_TICK, "support tick");
        assertEq(posA.tick, EXPECTED_A_TICK, "tick A");
        assertEq(posB.tick, EXPECTED_B_TICK, "tick B");

        _waitDelay();
        _waitDelay();

        uint256 supportBoundary = protocol.getEffectivePriceForTick(supportPos.tick);
        assertEq(supportBoundary, EXPECTED_SUPPORT_BOUNDARY, "support boundary changed");
        assertEq(uint256(STAGE_PRICE) % 1 ether, 0, "stage price must be whole-dollar");
        assertGt(supportBoundary - uint256(STAGE_PRICE), 0.5 ether, "stage price is not boundary-minus-one-wei");

        Types.LiqTickInfo[] memory staged = protocol.liquidate(abi.encode(STAGE_PRICE));
        assertEq(staged.length, 1, "stage must consume only support tick");
        assertGt(staged[0].remainingCollateral, 0, "support collateral positive");
        assertEq(protocol.getTotalLongPositions(), 2, "only A+B remain");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "A highest remaining tick");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "Rebalancer remains enabled");

        // Arm the real Rebalancer without adding any time to the original witness.
        // The original proof already waits twice between STAGE_PRICE and FINAL_PRICE.
        // We use the first existing delay to satisfy the Rebalancer validation delay.
        wstETH.mintAndApprove(REBALANCER_DEPOSITOR, PENDING_ASSETS, address(rebalancer), type(uint256).max);
        vm.prank(REBALANCER_DEPOSITOR);
        rebalancer.initiateDepositAssets(PENDING_ASSETS, REBALANCER_DEPOSITOR);

        _waitDelay();
        vm.prank(REBALANCER_DEPOSITOR);
        rebalancer.validateDepositAssets();
        assertEq(rebalancer.getPendingAssetsAmount(), PENDING_ASSETS, "pending assets armed");
        _waitDelay();

        uint256 finalBoundary = protocol.getEffectivePriceForTick(posB.tick);
        assertEq(finalBoundary, EXPECTED_FINAL_BOUNDARY, "final boundary changed");
        assertEq(uint256(FINAL_PRICE) % 1 ether, 0, "final price must be whole-dollar");
        assertGt(finalBoundary - uint256(FINAL_PRICE), 0.8 ether, "final price is not boundary-minus-one-wei");
    }

    function test_A_exactWitnessStillHasOneWeiGapWithPendingRebalancerAssets() public {
        uint128 liquidationOracleTimestamp = uint128(block.timestamp - 30 seconds);
        Types.ApplyPnlAndFundingData memory pnl =
            protocol.i_applyPnlAndFunding(FINAL_PRICE, liquidationOracleTimestamp);
        assertEq(pnl.tempLongBalance, EXPECTED_TEMP_LONG_BALANCE, "temporary long balance unchanged");

        uint256 price = uint256(FINAL_PRICE);
        uint256 valueA = EXPECTED_A_EXPO * (price - EXPECTED_A_PRICE_WITHOUT_PENALTY) / price;
        uint256 valueB = EXPECTED_B_EXPO * (price - EXPECTED_B_PRICE_WITHOUT_PENALTY) / price;

        assertEq(valueA, EXPECTED_A_REMAINING, "independent tick A floor");
        assertEq(valueB, EXPECTED_B_REMAINING, "independent tick B floor");
        assertEq(valueA + valueB, uint256(EXPECTED_TEMP_LONG_BALANCE) - 1, "source floors miss one wei");
        assertEq(rebalancer.getPendingAssetsAmount(), PENDING_ASSETS, "Rebalancer is actually armed");
    }

    function test_B_reconciliationBonusCarryIsExactlyFundedAndAssetConserving() public {
        uint256 rawRemaining = EXPECTED_A_REMAINING + EXPECTED_B_REMAINING;
        uint256 reconciliation = uint256(EXPECTED_TEMP_LONG_BALANCE) - rawRemaining;
        assertEq(reconciliation, 1, "exact whole-dollar witness reconciliation");

        uint256 bonusBps = protocol.getRebalancerBonusBps();
        uint256 bonusWithoutReconciliation = rawRemaining * bonusBps / 10_000;
        uint256 bonusWithReconciliation = (rawRemaining + reconciliation) * bonusBps / 10_000;
        assertEq(
            bonusWithReconciliation - bonusWithoutReconciliation,
            1,
            "one-wei reconciliation must cross the 80-percent bonus rounding boundary"
        );
        assertEq(bonusWithReconciliation, 209_850_230_362_722_783, "exact funded bonus");

        // Include every address among which this call can move physical wstETH:
        // Rebalancer -> protocol for pending assets and protocol -> liquidator for rewards.
        // Reconciliation is an accounting transfer and must not increase this total.
        uint256 physicalBefore = wstETH.balanceOf(address(protocol)) + wstETH.balanceOf(address(rebalancer))
            + wstETH.balanceOf(PUBLIC_LIQUIDATOR);

        vm.prank(PUBLIC_LIQUIDATOR);
        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(FINAL_PRICE));

        assertEq(ticks.length, 2, "same final batch must liquidate A+B");
        assertEq(ticks[0].totalExpo, EXPECTED_A_EXPO, "tick A expo unchanged");
        assertEq(ticks[1].totalExpo, EXPECTED_B_EXPO, "tick B expo unchanged");
        assertEq(uint256(ticks[0].remainingCollateral), EXPECTED_A_REMAINING, "tick A floor unchanged");
        assertEq(uint256(ticks[1].remainingCollateral), EXPECTED_B_REMAINING, "tick B floor unchanged");
        assertEq(rebalancer.getPendingAssetsAmount(), 0, "pending assets consumed into new position");

        (,, Types.PositionId memory rebalancerPosId) = rebalancer.getCurrentStateData();
        (Types.Position memory reboundPosition,) = protocol.getLongPosition(rebalancerPosId);
        assertEq(reboundPosition.user, address(rebalancer), "new long must belong to Rebalancer");
        assertEq(
            uint256(reboundPosition.amount),
            uint256(PENDING_ASSETS) + bonusWithReconciliation,
            "new position collateral = pending principal + reconciled funded bonus"
        );
        assertEq(
            uint256(reboundPosition.amount) - uint256(PENDING_ASSETS),
            bonusWithReconciliation,
            "no bonus exists beyond reconciled liquidation collateral"
        );

        uint256 physicalAfter = wstETH.balanceOf(address(protocol)) + wstETH.balanceOf(address(rebalancer))
            + wstETH.balanceOf(PUBLIC_LIQUIDATOR);
        assertEq(physicalAfter, physicalBefore, "reconciliation must not mint physical wstETH");

        assertEq(protocol.getTotalLongPositions(), 1, "only the new Rebalancer long remains");
        assertLe(protocol.getBalanceLong(), protocol.getTotalExpo(), "post-Rebalancer long/expo invariant");
        assertGt(protocol.getTotalExpo(), 0, "new Rebalancer long creates exposure");
        assertGt(protocol.getBalanceLong(), 0, "new Rebalancer long carries collateral");
    }
}
