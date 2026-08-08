// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Scale control for the whole-dollar witness. All collateral magnitudes are 10x larger
/// than the primary deterministic reproduction while desired liquidation and oracle prices stay unchanged.
contract TestLiquidationRoundingPostBootstrapScale10x is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;
    uint128 internal constant STAGE_PRICE = 1651 ether;
    uint128 internal constant FINAL_PRICE = 1586 ether;

    uint256 internal constant EXPECTED_A_EXPO = 93_138_310_789_196_227_268;
    uint256 internal constant EXPECTED_B_EXPO = 89_856_453_784_474_317_897;
    uint256 internal constant EXPECTED_A_PRICE_WITHOUT_PENALTY = 1_570_940_508_592_271_423_354;
    uint256 internal constant EXPECTED_B_PRICE_WITHOUT_PENALTY = 1_555_310_166_964_661_193_276;
    uint256 internal constant EXPECTED_A_REMAINING = 884_373_008_234_712_718;
    uint256 internal constant EXPECTED_B_REMAINING = 1_738_763_911_597_197_138;
    int256 internal constant EXPECTED_TEMP_LONG_BALANCE = 2_623_136_919_831_909_857;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);
    address internal constant PUBLIC_LIQUIDATOR = address(0xA11CE);

    PositionId internal supportPos;
    PositionId internal posA;
    PositionId internal posB;

    function setUp() public {
        params = DEFAULT_PARAMS;
        params.initialLong = 2000 ether;
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
            OpenParams(SUPPORT_USER, ProtocolAction.ValidateOpenPosition, 200 ether, 1652 ether, ENTRY_PRICE)
        );
        posA = setUpUserPositionInLong(
            OpenParams(USER_A, ProtocolAction.ValidateOpenPosition, 20 ether, 1619 ether, ENTRY_PRICE)
        );
        posB = setUpUserPositionInLong(
            OpenParams(USER_B, ProtocolAction.ValidateOpenPosition, 20 ether, 1587 ether, ENTRY_PRICE)
        );

        assertEq(supportPos.tick, 74_100, "support tick");
        assertEq(posA.tick, 73_800, "tick A");
        assertEq(posB.tick, 73_700, "tick B");

        _waitDelay();
        _waitDelay();
        Types.LiqTickInfo[] memory staged = protocol.liquidate(abi.encode(STAGE_PRICE));
        assertEq(staged.length, 1, "stage must liquidate only support");
        assertEq(protocol.getTotalLongPositions(), 2, "only A+B remain");
        assertEq(protocol.getHighestPopulatedTick(), 73_800, "A highest remaining");

        _waitDelay();
        _waitDelay();
    }

    function test_A_10xScaleSourceIsolation() public {
        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));

        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(FINAL_PRICE));
        assertEq(ticks.length, 2, "final batch must contain A+B");
        assertEq(ticks[0].totalExpo, EXPECTED_A_EXPO, "10x tick A expo");
        assertEq(ticks[1].totalExpo, EXPECTED_B_EXPO, "10x tick B expo");
        assertEq(uint256(ticks[0].remainingCollateral), EXPECTED_A_REMAINING, "10x tick A collateral");
        assertEq(uint256(ticks[1].remainingCollateral), EXPECTED_B_REMAINING, "10x tick B collateral");
        assertEq(protocol.getTotalLongPositions(), 0, "all positions removed");
        assertEq(protocol.getTotalExpo(), 0, "all exposure removed");
        assertEq(protocol.getBalanceLong(), 1, "10x scale leaves exact one-wei residue");
        assertGt(protocol.getBalanceLong(), protocol.getTotalExpo(), "same invariant break at 10x scale");
    }

    /// @dev Reproduce the 10x residue without relying on the liquidation helper's collateral output.
    function test_B_10xIndependentArithmeticStillLeavesExactlyOneWei() public {
        uint128 liquidationOracleTimestamp = uint128(block.timestamp - 30 seconds);
        Types.ApplyPnlAndFundingData memory pnl =
            protocol.i_applyPnlAndFunding(FINAL_PRICE, liquidationOracleTimestamp);
        assertEq(pnl.tempLongBalance, EXPECTED_TEMP_LONG_BALANCE, "10x temporary long balance");

        uint256 price = uint256(FINAL_PRICE);
        uint256 valueA = EXPECTED_A_EXPO * (price - EXPECTED_A_PRICE_WITHOUT_PENALTY) / price;
        uint256 valueB = EXPECTED_B_EXPO * (price - EXPECTED_B_PRICE_WITHOUT_PENALTY) / price;

        assertEq(valueA, EXPECTED_A_REMAINING, "10x independent tick A floor");
        assertEq(valueB, EXPECTED_B_REMAINING, "10x independent tick B floor");
        assertEq(valueA + valueB, uint256(EXPECTED_TEMP_LONG_BALANCE) - 1, "10x floor sum misses one wei");
        assertEq(uint256(EXPECTED_TEMP_LONG_BALANCE) - valueA - valueB, 1, "10x exact rounding residue");
    }

    function test_C_10xScaleProductionSink() public {
        vm.startPrank(PUBLIC_LIQUIDATOR, PUBLIC_LIQUIDATOR);
        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(FINAL_PRICE));
        vm.stopPrank();

        assertEq(protocol.getTotalLongPositions(), 2, "production revert rolls final batch back");
    }
}
