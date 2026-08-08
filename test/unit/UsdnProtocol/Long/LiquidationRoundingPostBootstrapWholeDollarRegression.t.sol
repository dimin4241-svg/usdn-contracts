// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Deterministic regression frozen from the whole-dollar Foundry fuzz counterexample.
/// The initialization-created long is fully removed before any witness position is opened.
/// All witness positions are then created through ordinary public open/validate flows with
/// production economic flags, production role separation and the production Rebalancer installed.
/// Both staged liquidation prices are exact whole-dollar oracle prices.
contract TestLiquidationRoundingPostBootstrapWholeDollarRegression is UsdnProtocolBaseFixture {
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
    int256 internal constant EXPECTED_A_REMAINING = 88_436_831_455_148_774;
    int256 internal constant EXPECTED_B_REMAINING = 173_875_956_498_254_704;
    int256 internal constant EXPECTED_TEMP_LONG_BALANCE = 262_312_787_953_403_479;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);
    address internal constant PUBLIC_LIQUIDATOR = address(0xA11CE);
    address internal constant PUBLIC_LIQUIDATOR_2 = address(0xA11CF);
    address internal constant PUBLIC_LIQUIDATOR_3 = address(0xA11D0);

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
        vm.deal(PUBLIC_LIQUIDATOR_2, 1 ether);
        vm.deal(PUBLIC_LIQUIDATOR_3, 1 ether);
        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "production action liquidation iteration");
        assertEq(protocol.getProtocolFeeBps(), 800, "production protocol fee");
        assertEq(protocol.getFundingSF(), 120, "production funding SF");
        assertEq(protocol.getMinLongPosition(), 2 ether, "production minimum long");
        assertGt(protocol.getCloseExpoImbalanceLimitBps(), 0, "production close imbalance limit");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer installed");
        assertTrue(managers.setExternalManager != managers.setProtocolParamsManager, "manager roles separated");
        assertTrue(managers.setExternalManager != protocol.defaultAdmin(), "external manager is not admin");

        // Completely erase the initialization-created long and prove a clean zero-long state.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap positions gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap exposure gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap long balance gone");

        // Reset accounting price while the long side is empty.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "price reset keeps no positions");
        assertEq(protocol.getTotalExpo(), 0, "price reset keeps zero exposure");
        assertEq(protocol.getBalanceLong(), 0, "price reset keeps zero long balance");

        // Every position involved in the witness is now an ordinary post-bootstrap user position.
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
        assertEq(protocol.getTotalLongPositions(), 3, "three ordinary positions");

        _waitDelay();
        _waitDelay();

        uint256 supportBoundary = protocol.getEffectivePriceForTick(supportPos.tick);
        assertEq(supportBoundary, EXPECTED_SUPPORT_BOUNDARY, "support boundary changed");
        assertEq(uint256(STAGE_PRICE) % 1 ether, 0, "stage oracle price must be an exact whole dollar");
        assertGt(supportBoundary - uint256(STAGE_PRICE), 0.5 ether, "stage price is not a boundary-wei needle");

        Types.LiqTickInfo[] memory staged = protocol.liquidate(abi.encode(STAGE_PRICE));
        assertEq(staged.length, 1, "stage must consume only support tick");
        assertGt(staged[0].remainingCollateral, 0, "support tick has positive collateral");
        assertEq(protocol.getTotalLongPositions(), 2, "only A+B remain");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "A must be highest remaining tick");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "Rebalancer stays enabled during construction");

        _waitDelay();
        _waitDelay();

        uint256 finalBoundary = protocol.getEffectivePriceForTick(posB.tick);
        assertEq(finalBoundary, EXPECTED_FINAL_BOUNDARY, "final boundary changed");
        assertEq(uint256(FINAL_PRICE) % 1 ether, 0, "final oracle price must be an exact whole dollar");
        assertGt(finalBoundary - uint256(FINAL_PRICE), 0.8 ether, "final price is not a boundary-wei needle");
    }

    function test_A_fullyPostBootstrapWholeDollarStateIsReachable() public view {
        assertEq(protocol.getTotalLongPositions(), 2, "two ordinary positions remain");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "highest remaining tick");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "Rebalancer enabled");
        assertEq(uint256(STAGE_PRICE) % 1 ether, 0, "whole-dollar stage price");
        assertEq(uint256(FINAL_PRICE) % 1 ether, 0, "whole-dollar final price");
    }

    /// @dev Source isolation: remove only the downstream Rebalancer immediately before the final
    /// batch so the vulnerable accounting state can commit and be inspected directly.
    function test_B_wholeDollarFinalBatchCommitsExactOneWeiWithoutSink() public {
        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));

        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(FINAL_PRICE));
        assertEq(ticks.length, 2, "final batch contains exactly A+B");
        assertEq(ticks[0].totalExpo, EXPECTED_A_EXPO, "tick A expo");
        assertEq(ticks[1].totalExpo, EXPECTED_B_EXPO, "tick B expo");
        assertEq(ticks[0].remainingCollateral, EXPECTED_A_REMAINING, "tick A collateral");
        assertEq(ticks[1].remainingCollateral, EXPECTED_B_REMAINING, "tick B collateral");
        assertGt(ticks[0].remainingCollateral, 0, "tick A is not bad debt");
        assertGt(ticks[1].remainingCollateral, 0, "tick B is not bad debt");

        assertEq(protocol.getTotalLongPositions(), 0, "all ordinary positions removed");
        assertEq(protocol.getTotalExpo(), 0, "all exposure removed");
        assertEq(protocol.getBalanceLong(), 1, "exact one-wei residue");
        assertGt(protocol.getBalanceLong(), protocol.getTotalExpo(), "Rebalancer invariant source is broken");
    }

    /// @dev Exact production sink. No privileged caller and no Rebalancer modification: the same
    /// public whole-dollar liquidation reaches the invariant and the complete transaction reverts.
    function test_C_unprivilegedWholeDollarLiquidationHitsExactProductionRevert() public {
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer enabled");
        assertTrue(PUBLIC_LIQUIDATOR != protocol.defaultAdmin(), "caller is not admin");
        assertTrue(PUBLIC_LIQUIDATOR != managers.setExternalManager, "caller is not external manager");

        vm.startPrank(PUBLIC_LIQUIDATOR, PUBLIC_LIQUIDATOR);
        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(FINAL_PRICE));
        vm.stopPrank();

        assertEq(protocol.getTotalLongPositions(), 2, "revert rolls both ticks back");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "highest tick preserved after revert");
    }

    /// @dev Independent arithmetic. The liquidation MockOracle returns block.timestamp - 30 seconds.
    /// We independently reproduce the aggregate temporary long balance, then separately floor each
    /// tick collateral. Their sum is exactly one wei smaller than the aggregate balance.
    function test_D_independentWholeDollarArithmeticLeavesExactlyOneWei() public {
        uint128 liquidationOracleTimestamp = uint128(block.timestamp - 30 seconds);
        Types.ApplyPnlAndFundingData memory pnl =
            protocol.i_applyPnlAndFunding(FINAL_PRICE, liquidationOracleTimestamp);
        assertEq(pnl.tempLongBalance, EXPECTED_TEMP_LONG_BALANCE, "temporary long balance");

        uint256 price = uint256(FINAL_PRICE);
        uint256 valueA = EXPECTED_A_EXPO * (price - EXPECTED_A_PRICE_WITHOUT_PENALTY) / price;
        uint256 valueB = EXPECTED_B_EXPO * (price - EXPECTED_B_PRICE_WITHOUT_PENALTY) / price;

        assertEq(valueA, uint256(EXPECTED_A_REMAINING), "independent tick A floor");
        assertEq(valueB, uint256(EXPECTED_B_REMAINING), "independent tick B floor");
        assertEq(valueA + valueB, uint256(EXPECTED_TEMP_LONG_BALANCE) - 1, "independent floor sum");
        assertEq(uint256(EXPECTED_TEMP_LONG_BALANCE) - valueA - valueB, 1, "exact rounding residue");
    }

    /// @dev A failed dedicated liquidation makes no progress because the whole transaction rolls
    /// back. Independent public EOAs therefore hit the same failure on simple retry.
    function test_E_wholeDollarDedicatedRetriesAreSticky() public {
        address[3] memory callers = [PUBLIC_LIQUIDATOR, PUBLIC_LIQUIDATOR_2, PUBLIC_LIQUIDATOR_3];
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i], callers[i]);
            vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
            protocol.liquidate(abi.encode(FINAL_PRICE));
            vm.stopPrank();
            assertEq(protocol.getTotalLongPositions(), 2, "retry cannot consume a tick");
            assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "retry cannot advance highest tick");
        }
    }
}
