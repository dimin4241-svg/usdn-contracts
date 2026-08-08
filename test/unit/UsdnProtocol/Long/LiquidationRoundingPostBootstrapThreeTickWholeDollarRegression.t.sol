// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Deterministic regression frozen from an independently fuzzed
/// three-tick whole-dollar counterexample. Bootstrap state is fully removed
/// before all four witness positions are created through ordinary public flows.
contract TestLiquidationRoundingPostBootstrapThreeTickWholeDollarRegression is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;

    uint128 internal constant SUPPORT_AMOUNT = 20 ether;
    uint128 internal constant USER_AMOUNT = 2 ether;

    uint128 internal constant SUPPORT_DESIRED_LIQ = 1772 ether;
    uint128 internal constant A_DESIRED_LIQ = 1760 ether;
    uint128 internal constant B_DESIRED_LIQ = 1740 ether;
    uint128 internal constant C_DESIRED_LIQ = 1728 ether;

    uint128 internal constant STAGE_PRICE = 1771 ether;
    uint128 internal constant FINAL_PRICE = 1719 ether;

    int24 internal constant EXPECTED_SUPPORT_TICK = 74_800;
    int24 internal constant EXPECTED_A_TICK = 74_700;
    int24 internal constant EXPECTED_B_TICK = 74_600;
    int24 internal constant EXPECTED_C_TICK = 74_500;

    uint256 internal constant EXPECTED_SUPPORT_BOUNDARY = 1_771_392_824_854_198_989_095;
    uint256 internal constant EXPECTED_FINAL_BOUNDARY = 1_719_012_711_346_939_428_664;

    uint256 internal constant EXPECTED_A_EXPO = 14_207_428_584_122_779_508;
    uint256 internal constant EXPECTED_B_EXPO = 13_392_045_773_476_152_751;
    uint256 internal constant EXPECTED_C_EXPO = 12_672_198_531_825_921_694;

    uint256 internal constant EXPECTED_A_PRICE_WITHOUT_PENALTY = 1_718_925_046_890_368_692_971;
    uint256 internal constant EXPECTED_B_PRICE_WITHOUT_PENALTY = 1_701_822_307_755_308_504_692;
    uint256 internal constant EXPECTED_C_PRICE_WITHOUT_PENALTY = 1_684_889_735_252_267_016_011;

    int256 internal constant EXPECTED_A_REMAINING = 619_482_811_078_952;
    int256 internal constant EXPECTED_B_REMAINING = 133_824_572_904_941_725;
    int256 internal constant EXPECTED_C_REMAINING = 251_455_524_640_148_582;
    int256 internal constant EXPECTED_TEMP_LONG_BALANCE = 385_899_580_356_169_261;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);
    address internal constant USER_C = address(0xC0DE);
    address internal constant PUBLIC_LIQUIDATOR = address(0xA11CE);

    PositionId internal supportPos;
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

        assertEq(protocol.getLiquidationIteration(), 1, "production action liquidation iteration");
        assertEq(protocol.getProtocolFeeBps(), 800, "production protocol fee");
        assertEq(protocol.getFundingSF(), 120, "production funding SF");
        assertEq(protocol.getMinLongPosition(), 2 ether, "production minimum long");
        assertGt(protocol.getCloseExpoImbalanceLimitBps(), 0, "production close imbalance limit");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer installed");
        assertTrue(managers.setExternalManager != protocol.defaultAdmin(), "external manager is not admin");

        // Erase initialization-created long before any witness position exists.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap positions gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap exposure gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap long balance gone");

        // Reset accounting price on a completely empty long side.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "price reset leaves no positions");
        assertEq(protocol.getTotalExpo(), 0, "price reset leaves zero exposure");
        assertEq(protocol.getBalanceLong(), 0, "price reset leaves zero long balance");

        supportPos = setUpUserPositionInLong(
            OpenParams(SUPPORT_USER, ProtocolAction.ValidateOpenPosition, SUPPORT_AMOUNT, SUPPORT_DESIRED_LIQ, ENTRY_PRICE)
        );
        posA = setUpUserPositionInLong(
            OpenParams(USER_A, ProtocolAction.ValidateOpenPosition, USER_AMOUNT, A_DESIRED_LIQ, ENTRY_PRICE)
        );
        posB = setUpUserPositionInLong(
            OpenParams(USER_B, ProtocolAction.ValidateOpenPosition, USER_AMOUNT, B_DESIRED_LIQ, ENTRY_PRICE)
        );
        posC = setUpUserPositionInLong(
            OpenParams(USER_C, ProtocolAction.ValidateOpenPosition, USER_AMOUNT, C_DESIRED_LIQ, ENTRY_PRICE)
        );

        assertEq(supportPos.tick, EXPECTED_SUPPORT_TICK, "support tick");
        assertEq(posA.tick, EXPECTED_A_TICK, "A tick");
        assertEq(posB.tick, EXPECTED_B_TICK, "B tick");
        assertEq(posC.tick, EXPECTED_C_TICK, "C tick");
        assertEq(protocol.getTotalLongPositions(), 4, "four ordinary post-bootstrap positions");

        _waitDelay();
        _waitDelay();

        uint256 supportBoundary = protocol.getEffectivePriceForTick(supportPos.tick);
        assertEq(supportBoundary, EXPECTED_SUPPORT_BOUNDARY, "support boundary changed");
        assertEq(uint256(STAGE_PRICE) % 1 ether, 0, "whole-dollar stage price");
        assertGt(supportBoundary - uint256(STAGE_PRICE), 0.3 ether, "stage is not a boundary-wei needle");

        Types.LiqTickInfo[] memory staged = protocol.liquidate(abi.encode(STAGE_PRICE));
        assertEq(staged.length, 1, "stage consumes support only");
        assertGt(staged[0].remainingCollateral, 0, "stage is not bad debt");
        assertEq(protocol.getTotalLongPositions(), 3, "A+B+C remain");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "A is highest remaining tick");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "Rebalancer remained enabled through construction");

        _waitDelay();
        _waitDelay();

        uint256 finalBoundary = protocol.getEffectivePriceForTick(posC.tick);
        assertEq(finalBoundary, EXPECTED_FINAL_BOUNDARY, "final boundary changed");
        assertEq(uint256(FINAL_PRICE) % 1 ether, 0, "whole-dollar final price");
        assertGt(finalBoundary - uint256(FINAL_PRICE), 0.01 ether, "final is not a price-wei needle");
    }

    function test_A_threeOrdinaryTicksReachWholeDollarFinalState() public view {
        assertEq(protocol.getTotalLongPositions(), 3, "three ordinary ticks remain");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "A is highest");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer enabled");
    }

    /// @dev Source isolation only: removing Rebalancer immediately before the
    /// final call lets the malformed accounting state commit for inspection.
    function test_B_threePositiveCollateralFloorsLeaveTwoWeiResidue() public {
        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));

        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(FINAL_PRICE));
        assertEq(ticks.length, 3, "final batch contains A+B+C");

        assertEq(ticks[0].totalExpo, EXPECTED_A_EXPO, "A expo");
        assertEq(ticks[1].totalExpo, EXPECTED_B_EXPO, "B expo");
        assertEq(ticks[2].totalExpo, EXPECTED_C_EXPO, "C expo");
        assertEq(ticks[0].remainingCollateral, EXPECTED_A_REMAINING, "A collateral");
        assertEq(ticks[1].remainingCollateral, EXPECTED_B_REMAINING, "B collateral");
        assertEq(ticks[2].remainingCollateral, EXPECTED_C_REMAINING, "C collateral");
        assertGt(ticks[0].remainingCollateral, 0, "A is not bad debt");
        assertGt(ticks[1].remainingCollateral, 0, "B is not bad debt");
        assertGt(ticks[2].remainingCollateral, 0, "C is not bad debt");

        assertEq(protocol.getTotalLongPositions(), 0, "all final positions removed");
        assertEq(protocol.getTotalExpo(), 0, "all final exposure removed");
        assertEq(protocol.getBalanceLong(), 2, "three independent floors leave two wei");
        assertGt(protocol.getBalanceLong(), protocol.getTotalExpo(), "Rebalancer invariant source broken");
    }

    /// @dev Production sink: same public final call, no privileged mutation.
    function test_C_unprivilegedThreeTickDedicatedLiquidationRevertsAndRollsBack() public {
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer enabled");
        assertTrue(PUBLIC_LIQUIDATOR != protocol.defaultAdmin(), "caller is not admin");
        assertTrue(PUBLIC_LIQUIDATOR != managers.setExternalManager, "caller is not external manager");

        vm.startPrank(PUBLIC_LIQUIDATOR, PUBLIC_LIQUIDATOR);
        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(FINAL_PRICE));
        vm.stopPrank();

        assertEq(protocol.getTotalLongPositions(), 3, "revert rolls all three ticks back");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "highest tick unchanged after rollback");
    }

    /// @dev Independent arithmetic: aggregate PnL/funding produces a long
    /// balance two wei larger than the sum of three independently floored tick
    /// collateral amounts. No internal tick-value helper is used for the floors.
    function test_D_independentThreeFloorArithmeticExplainsExactTwoWei() public {
        uint128 liquidationOracleTimestamp = uint128(block.timestamp - 30 seconds);
        Types.ApplyPnlAndFundingData memory pnl =
            protocol.i_applyPnlAndFunding(FINAL_PRICE, liquidationOracleTimestamp);
        assertEq(pnl.tempLongBalance, EXPECTED_TEMP_LONG_BALANCE, "aggregate temporary long balance");

        uint256 price = uint256(FINAL_PRICE);
        uint256 valueA = EXPECTED_A_EXPO * (price - EXPECTED_A_PRICE_WITHOUT_PENALTY) / price;
        uint256 valueB = EXPECTED_B_EXPO * (price - EXPECTED_B_PRICE_WITHOUT_PENALTY) / price;
        uint256 valueC = EXPECTED_C_EXPO * (price - EXPECTED_C_PRICE_WITHOUT_PENALTY) / price;

        assertEq(valueA, uint256(EXPECTED_A_REMAINING), "independent A floor");
        assertEq(valueB, uint256(EXPECTED_B_REMAINING), "independent B floor");
        assertEq(valueC, uint256(EXPECTED_C_REMAINING), "independent C floor");

        uint256 floorSum = valueA + valueB + valueC;
        assertEq(floorSum, uint256(EXPECTED_TEMP_LONG_BALANCE) - 2, "three floors miss aggregate by two wei");
        assertEq(uint256(EXPECTED_TEMP_LONG_BALANCE) - floorSum, 2, "exact two-wei residue");
    }
}
