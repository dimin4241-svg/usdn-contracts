// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Deterministic regression frozen from a Foundry fuzz counterexample.
/// The initialization-created long is fully liquidated and accounting reaches
/// positions=0,totalExpo=0,balanceLong=0 before any position involved in the
/// witness is created. All later positions use ordinary public open/validate
/// flows under production economic flags, limits and role separation.
contract TestLiquidationRoundingPostBootstrapRegression is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;

    uint128 internal constant SUPPORT_AMOUNT = 20 ether;
    uint128 internal constant USER_AMOUNT = 2 ether;
    uint128 internal constant SUPPORT_DESIRED_LIQ = 1783 ether;
    uint128 internal constant A_DESIRED_LIQ = 1724 ether;
    uint128 internal constant B_DESIRED_LIQ = 1703 ether;

    int24 internal constant EXPECTED_SUPPORT_TICK = 74_800;
    int24 internal constant EXPECTED_A_TICK = 74_500;
    int24 internal constant EXPECTED_B_TICK = 74_400;

    uint256 internal constant EXPECTED_SUPPORT_BOUNDARY = 1_771_431_167_451_324_147_030;
    uint256 internal constant EXPECTED_FINAL_BOUNDARY = 1_701_942_303_173_288_776_979;

    uint256 internal constant EXPECTED_A_EXPO = 12_675_520_241_288_472_878;
    uint256 internal constant EXPECTED_B_EXPO = 12_034_709_889_783_951_966;
    uint256 internal constant EXPECTED_A_PRICE_WITHOUT_PENALTY = 1_684_916_553_638_498_409_790;
    uint256 internal constant EXPECTED_B_PRICE_WITHOUT_PENALTY = 1_668_152_187_831_301_125_432;
    int256 internal constant EXPECTED_A_REMAINING = 126_802_320_177_930_074;
    int256 internal constant EXPECTED_B_REMAINING = 238_935_382_547_897_344;
    int256 internal constant EXPECTED_TEMP_LONG_BALANCE = 365_737_702_725_827_419;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);
    address internal constant UNPRIVILEGED_LIQUIDATOR = address(0xA11CE);
    address internal constant UNPRIVILEGED_LIQUIDATOR_2 = address(0xA11CF);
    address internal constant UNPRIVILEGED_LIQUIDATOR_3 = address(0xA11D0);

    PositionId internal supportPos;
    PositionId internal posA;
    PositionId internal posB;
    uint128 internal finalPrice;

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
        vm.deal(UNPRIVILEGED_LIQUIDATOR, 1 ether);
        vm.deal(UNPRIVILEGED_LIQUIDATOR_2, 1 ether);
        vm.deal(UNPRIVILEGED_LIQUIDATOR_3, 1 ether);
        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "production action liquidation iteration");
        assertEq(protocol.getProtocolFeeBps(), 800, "production protocol fee");
        assertEq(protocol.getFundingSF(), 120, "production funding SF");
        assertEq(protocol.getMinLongPosition(), 2 ether, "production min long");
        assertGt(protocol.getCloseExpoImbalanceLimitBps(), 0, "close imbalance limit enabled");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer installed");
        assertTrue(managers.setExternalManager != managers.setProtocolParamsManager, "manager roles must be separated");
        assertTrue(managers.setExternalManager != protocol.defaultAdmin(), "external manager must not be admin");

        // Remove the initialization-created long completely. This is a hard
        // precondition of the witness, not merely an assumption.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap positions must be gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap totalExpo must be gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap balanceLong must be gone");

        // Return accounting to the $2000 market while there are no longs.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "price reset must not create positions");
        assertEq(protocol.getTotalExpo(), 0, "price reset must keep zero exposure");
        assertEq(protocol.getBalanceLong(), 0, "price reset must keep zero long balance");

        // Every position below is an ordinary user position created after the
        // bootstrap state has disappeared.
        supportPos = setUpUserPositionInLong(
            OpenParams({
                user: SUPPORT_USER,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: SUPPORT_AMOUNT,
                desiredLiqPrice: SUPPORT_DESIRED_LIQ,
                price: ENTRY_PRICE
            })
        );
        posA = setUpUserPositionInLong(
            OpenParams({
                user: USER_A,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: USER_AMOUNT,
                desiredLiqPrice: A_DESIRED_LIQ,
                price: ENTRY_PRICE
            })
        );
        posB = setUpUserPositionInLong(
            OpenParams({
                user: USER_B,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: USER_AMOUNT,
                desiredLiqPrice: B_DESIRED_LIQ,
                price: ENTRY_PRICE
            })
        );

        assertEq(supportPos.tick, EXPECTED_SUPPORT_TICK, "support tick");
        assertEq(posA.tick, EXPECTED_A_TICK, "ordinary tick A");
        assertEq(posB.tick, EXPECTED_B_TICK, "ordinary tick B");
        assertEq(protocol.getTotalLongPositions(), 3, "three ordinary positions expected");

        _waitDelay();
        _waitDelay();

        // Stage 1 occurs with the production Rebalancer installed. Exactly the
        // support tick is removed, leaving the two ordinary witness ticks.
        uint256 supportBoundary = protocol.getEffectivePriceForTick(supportPos.tick);
        assertEq(supportBoundary, EXPECTED_SUPPORT_BOUNDARY, "support boundary changed");
        Types.LiqTickInfo[] memory supportTicks =
            protocol.liquidate(abi.encode(uint128(supportBoundary - 1)));
        assertEq(supportTicks.length, 1, "support stage must liquidate one tick");
        assertGt(supportTicks[0].remainingCollateral, 0, "support collateral must be positive");
        assertEq(protocol.getTotalLongPositions(), 2, "only final ordinary positions remain");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "unexpected final highest tick");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "Rebalancer changed during construction");

        _waitDelay();
        _waitDelay();

        uint256 boundary = protocol.getEffectivePriceForTick(posB.tick);
        assertEq(boundary, EXPECTED_FINAL_BOUNDARY, "final boundary changed");
        finalPrice = uint128(boundary - 1);
    }

    function test_A_fullyPostBootstrapOrdinaryStateIsReachable() public view {
        assertEq(supportPos.tick, EXPECTED_SUPPORT_TICK, "support tick");
        assertEq(posA.tick, EXPECTED_A_TICK, "tick A");
        assertEq(posB.tick, EXPECTED_B_TICK, "tick B");
        assertEq(protocol.getTotalLongPositions(), 2, "two ordinary positions must remain");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "highest final tick");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "Rebalancer must remain enabled");
    }

    /// @dev Isolation control: remove only the downstream Rebalancer immediately
    /// before the final batch, allowing the source accounting state to commit.
    function test_B_finalTwoOrdinaryTicksCommitExactOneWeiResidueWithoutSink() public {
        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));

        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(finalPrice));

        assertEq(ticks.length, 2, "final batch must contain exactly two ordinary ticks");
        assertEq(ticks[0].totalPositions, 1, "tick A position count");
        assertEq(ticks[1].totalPositions, 1, "tick B position count");
        assertEq(ticks[0].totalExpo, EXPECTED_A_EXPO, "tick A expo");
        assertEq(ticks[1].totalExpo, EXPECTED_B_EXPO, "tick B expo");
        assertEq(ticks[0].remainingCollateral, EXPECTED_A_REMAINING, "tick A remaining collateral");
        assertEq(ticks[1].remainingCollateral, EXPECTED_B_REMAINING, "tick B remaining collateral");
        assertGt(ticks[0].remainingCollateral, 0, "tick A must not be bad debt");
        assertGt(ticks[1].remainingCollateral, 0, "tick B must not be bad debt");

        assertEq(protocol.getTotalLongPositions(), 0, "all ordinary positions must be liquidated");
        assertEq(protocol.getTotalExpo(), 0, "all long exposure must be removed");
        assertEq(protocol.getBalanceLong(), 1, "exact one-wei long balance residue");
        assertGt(protocol.getBalanceLong(), protocol.getTotalExpo(), "pre-sink invariant must be broken");
    }

    /// @dev Production control: on the identical pre-final state, leaving the
    /// Rebalancer enabled turns the +1 wei source state into the exact protocol
    /// custom-error revert and rolls the liquidation back.
    function test_C_productionRebalancerMakesDedicatedLiquidationRevert() public {
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "Rebalancer must be enabled");

        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(finalPrice));

        assertEq(protocol.getTotalLongPositions(), 2, "revert must roll final liquidation back");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "revert must preserve highest tick");
    }

    /// @dev Independent arithmetic control. The production liquidation path uses
    /// the liquidation oracle timestamp. The fixture oracle explicitly returns
    /// block.timestamp - 30 seconds for ProtocolAction.Liquidation, so we feed
    /// that exact timestamp into the exposed PnL/funding helper. The two tick
    /// values are then recomputed locally with separate floor divisions, without
    /// invoking `_tickValue` or the liquidation loop.
    function test_D_independentFloorSumLeavesExactlyOneWei() public {
        uint128 liquidationOracleTimestamp = uint128(block.timestamp - 30 seconds);
        Types.ApplyPnlAndFundingData memory pnl =
            protocol.i_applyPnlAndFunding(finalPrice, liquidationOracleTimestamp);
        assertEq(pnl.tempLongBalance, EXPECTED_TEMP_LONG_BALANCE, "pre-liquidation temp long balance");

        uint256 price = uint256(finalPrice);
        uint256 valueA = EXPECTED_A_EXPO * (price - EXPECTED_A_PRICE_WITHOUT_PENALTY) / price;
        uint256 valueB = EXPECTED_B_EXPO * (price - EXPECTED_B_PRICE_WITHOUT_PENALTY) / price;

        assertEq(valueA, uint256(EXPECTED_A_REMAINING), "independent tick A floor");
        assertEq(valueB, uint256(EXPECTED_B_REMAINING), "independent tick B floor");
        assertEq(valueA + valueB, uint256(EXPECTED_TEMP_LONG_BALANCE) - 1, "floor-sum must miss one wei");
        assertEq(uint256(EXPECTED_TEMP_LONG_BALANCE) - valueA - valueB, 1, "exact arithmetic residue");
    }

    /// @dev Reachability control: the failing dedicated liquidation is not an
    /// admin-only/internal path. A fresh EOA with no protocol role can call the
    /// public entrypoint and deterministically hit the same invariant revert.
    function test_E_unprivilegedEOACanReachExactProductionRevert() public {
        assertTrue(UNPRIVILEGED_LIQUIDATOR != managers.setExternalManager, "liquidator unexpectedly external manager");
        assertTrue(UNPRIVILEGED_LIQUIDATOR != managers.setProtocolParamsManager, "liquidator unexpectedly params manager");
        assertTrue(UNPRIVILEGED_LIQUIDATOR != protocol.defaultAdmin(), "liquidator unexpectedly admin");

        vm.startPrank(UNPRIVILEGED_LIQUIDATOR, UNPRIVILEGED_LIQUIDATOR);
        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(finalPrice));
        vm.stopPrank();

        assertEq(protocol.getTotalLongPositions(), 2, "EOA revert must roll final liquidation back");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "EOA revert must preserve highest tick");
    }

    /// @dev Retry control: dedicated liquidate() has no caller-supplied tick
    /// iteration. Its public path always requests MAX_LIQUIDATION_ITERATION.
    /// Since the invariant revert rolls the batch back, independent EOAs cannot
    /// make progress by simply retrying the same valid liquidation.
    function test_F_multipleUnprivilegedRetriesRemainSticky() public {
        address[3] memory callers =
            [UNPRIVILEGED_LIQUIDATOR, UNPRIVILEGED_LIQUIDATOR_2, UNPRIVILEGED_LIQUIDATOR_3];

        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i], callers[i]);
            vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
            protocol.liquidate(abi.encode(finalPrice));
            vm.stopPrank();

            assertEq(protocol.getTotalLongPositions(), 2, "retry must not consume a tick");
            assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "retry must preserve highest tick");
        }
    }
}
