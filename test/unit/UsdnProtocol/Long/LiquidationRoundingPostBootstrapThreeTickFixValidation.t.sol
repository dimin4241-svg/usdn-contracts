// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Red-to-green validation of the source fix on the independently found
/// three-tick positive-collateral whole-dollar witness. The arithmetic gap is
/// deliberately preserved in test A; test B proves the patch reconciles it
/// before the production Rebalancer safety sink.
contract TestLiquidationRoundingPostBootstrapThreeTickFixValidation is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;
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

    uint256 internal constant EXPECTED_A_EXPO = 14_207_428_584_122_779_508;
    uint256 internal constant EXPECTED_B_EXPO = 13_392_045_773_476_152_751;
    uint256 internal constant EXPECTED_C_EXPO = 12_672_198_531_825_921_694;

    uint256 internal constant EXPECTED_A_PRICE_WITHOUT_PENALTY = 1_718_925_046_890_368_692_971;
    uint256 internal constant EXPECTED_B_PRICE_WITHOUT_PENALTY = 1_701_822_307_755_308_504_692;
    uint256 internal constant EXPECTED_C_PRICE_WITHOUT_PENALTY = 1_684_889_735_252_267_016_011;

    uint256 internal constant EXPECTED_A_REMAINING = 619_482_811_078_952;
    uint256 internal constant EXPECTED_B_REMAINING = 133_824_572_904_941_725;
    uint256 internal constant EXPECTED_C_REMAINING = 251_455_524_640_148_582;
    uint256 internal constant EXPECTED_TEMP_LONG_BALANCE = 385_899_580_356_169_261;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);
    address internal constant USER_C = address(0xC0DE);
    address internal constant PUBLIC_LIQUIDATOR = address(0xA11CE);

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

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap positions gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap exposure gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap long balance gone");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "empty-side price reset");
        assertEq(protocol.getTotalExpo(), 0, "empty-side expo reset");
        assertEq(protocol.getBalanceLong(), 0, "empty-side balance reset");

        PositionId memory supportPos = setUpUserPositionInLong(
            OpenParams(SUPPORT_USER, ProtocolAction.ValidateOpenPosition, 20 ether, SUPPORT_DESIRED_LIQ, ENTRY_PRICE)
        );
        PositionId memory posA = setUpUserPositionInLong(
            OpenParams(USER_A, ProtocolAction.ValidateOpenPosition, 2 ether, A_DESIRED_LIQ, ENTRY_PRICE)
        );
        PositionId memory posB = setUpUserPositionInLong(
            OpenParams(USER_B, ProtocolAction.ValidateOpenPosition, 2 ether, B_DESIRED_LIQ, ENTRY_PRICE)
        );
        PositionId memory posC = setUpUserPositionInLong(
            OpenParams(USER_C, ProtocolAction.ValidateOpenPosition, 2 ether, C_DESIRED_LIQ, ENTRY_PRICE)
        );

        assertEq(supportPos.tick, EXPECTED_SUPPORT_TICK, "support tick");
        assertEq(posA.tick, EXPECTED_A_TICK, "A tick");
        assertEq(posB.tick, EXPECTED_B_TICK, "B tick");
        assertEq(posC.tick, EXPECTED_C_TICK, "C tick");

        _waitDelay();
        _waitDelay();
        Types.LiqTickInfo[] memory staged = protocol.liquidate(abi.encode(STAGE_PRICE));
        assertEq(staged.length, 1, "stage consumes support only");
        assertGt(staged[0].remainingCollateral, 0, "support stage not bad debt");
        assertEq(protocol.getTotalLongPositions(), 3, "A+B+C remain");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "A highest after stage");

        _waitDelay();
        _waitDelay();
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "Rebalancer remains enabled");
    }

    function test_A_sourceArithmeticStillContainsExactTwoWeiGap() public {
        uint128 oracleTimestamp = uint128(block.timestamp - 30 seconds);
        Types.ApplyPnlAndFundingData memory pnl = protocol.i_applyPnlAndFunding(FINAL_PRICE, oracleTimestamp);
        assertEq(pnl.tempLongBalance, EXPECTED_TEMP_LONG_BALANCE, "aggregate temporary long balance");

        uint256 p = uint256(FINAL_PRICE);
        uint256 a = EXPECTED_A_EXPO * (p - EXPECTED_A_PRICE_WITHOUT_PENALTY) / p;
        uint256 b = EXPECTED_B_EXPO * (p - EXPECTED_B_PRICE_WITHOUT_PENALTY) / p;
        uint256 c = EXPECTED_C_EXPO * (p - EXPECTED_C_PRICE_WITHOUT_PENALTY) / p;

        assertEq(a, EXPECTED_A_REMAINING, "A floor unchanged by fix");
        assertEq(b, EXPECTED_B_REMAINING, "B floor unchanged by fix");
        assertEq(c, EXPECTED_C_REMAINING, "C floor unchanged by fix");
        assertEq(a + b + c, EXPECTED_TEMP_LONG_BALANCE - 2, "source floors still miss two wei");
    }

    function test_B_fixReconcilesThreeTickGapBeforeProductionRebalancer() public {
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer enabled");
        assertTrue(PUBLIC_LIQUIDATOR != protocol.defaultAdmin(), "caller not admin");
        assertTrue(PUBLIC_LIQUIDATOR != managers.setExternalManager, "caller not external manager");

        vm.startPrank(PUBLIC_LIQUIDATOR, PUBLIC_LIQUIDATOR);
        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(FINAL_PRICE));
        vm.stopPrank();

        assertEq(ticks.length, 3, "same final A+B+C batch");
        assertEq(ticks[0].totalExpo, EXPECTED_A_EXPO, "A expo unchanged");
        assertEq(ticks[1].totalExpo, EXPECTED_B_EXPO, "B expo unchanged");
        assertEq(ticks[2].totalExpo, EXPECTED_C_EXPO, "C expo unchanged");
        assertEq(uint256(ticks[0].remainingCollateral), EXPECTED_A_REMAINING, "A tick collateral unchanged");
        assertEq(uint256(ticks[1].remainingCollateral), EXPECTED_B_REMAINING, "B tick collateral unchanged");
        assertEq(uint256(ticks[2].remainingCollateral), EXPECTED_C_REMAINING, "C tick collateral unchanged");

        assertEq(protocol.getTotalLongPositions(), 0, "all final positions removed");
        assertEq(protocol.getTotalExpo(), 0, "all exposure removed");
        assertEq(protocol.getBalanceLong(), 0, "fix reconciles exact two-wei aggregate gap");
    }
}
