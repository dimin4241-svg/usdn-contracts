// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Red-side differential for the deterministic whole-dollar post-bootstrap witness.
/// Uses the exact same public lifecycle and exact same $1651 -> $1586 prices as
/// TestLiquidationRoundingPostBootstrapWholeDollarFix on the patched branch.
contract TestLiquidationRoundingPostBootstrapWholeDollarVulnerable is UsdnProtocolBaseFixture {
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

        // Eliminate the bootstrap long completely before creating the witness.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap positions gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap exposure gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap long balance gone");

        // Return accounting to the $2000 market through the public liquidation path.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "price reset keeps no positions");
        assertEq(protocol.getTotalExpo(), 0, "price reset keeps zero exposure");
        assertEq(protocol.getBalanceLong(), 0, "price reset keeps zero long balance");

        // All witness positions are ordinary post-bootstrap user opens.
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

        // Stage away only the support position at an ordinary whole-dollar price.
        _waitDelay();
        _waitDelay();
        uint256 supportBoundary = protocol.getEffectivePriceForTick(supportPos.tick);
        assertEq(supportBoundary, EXPECTED_SUPPORT_BOUNDARY, "support boundary changed");
        assertEq(uint256(STAGE_PRICE) % 1 ether, 0, "whole-dollar stage price");
        Types.LiqTickInfo[] memory staged = protocol.liquidate(abi.encode(STAGE_PRICE));
        assertEq(staged.length, 1, "stage consumes support only");
        assertGt(staged[0].remainingCollateral, 0, "support collateral positive");
        assertEq(protocol.getTotalLongPositions(), 2, "only A+B remain");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "A highest remaining tick");

        _waitDelay();
        _waitDelay();
        uint256 finalBoundary = protocol.getEffectivePriceForTick(posB.tick);
        assertEq(finalBoundary, EXPECTED_FINAL_BOUNDARY, "final boundary changed");
        assertEq(uint256(FINAL_PRICE) % 1 ether, 0, "whole-dollar final price");
        assertGt(finalBoundary - uint256(FINAL_PRICE), 0.8 ether, "final price remains coarse");
    }

    /// @dev Exact production-side failure: same two-tick whole-dollar batch that
    /// succeeds on the patched branch reverts here with the Rebalancer installed.
    function test_A_vulnerableDedicatedWholeDollarLiquidationRevertsAndRollsBack() public {
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "Rebalancer must remain enabled");

        uint256 positionsBefore = protocol.getTotalLongPositions();
        uint256 expoBefore = protocol.getTotalExpo();
        uint256 longBefore = protocol.getBalanceLong();
        int24 highestBefore = protocol.getHighestPopulatedTick();
        uint256 liquidatorBefore = wstETH.balanceOf(PUBLIC_LIQUIDATOR);

        vm.startPrank(PUBLIC_LIQUIDATOR, PUBLIC_LIQUIDATOR);
        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(FINAL_PRICE));
        vm.stopPrank();

        assertEq(protocol.getTotalLongPositions(), positionsBefore, "revert rolls positions back");
        assertEq(protocol.getTotalExpo(), expoBefore, "revert rolls exposure back");
        assertEq(protocol.getBalanceLong(), longBefore, "revert rolls long balance back");
        assertEq(protocol.getHighestPopulatedTick(), highestBefore, "revert rolls bitmap/highest tick back");
        assertEq(wstETH.balanceOf(PUBLIC_LIQUIDATOR), liquidatorBefore, "reverted liquidation pays no reward");
    }

    /// @dev Isolation control: remove only the downstream Rebalancer. The exact
    /// same batch then commits and exposes the +1 wei source accounting residue.
    function test_B_sameBatchWithoutRebalancerCommitsExactOneWeiResidue() public {
        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));

        vm.startPrank(PUBLIC_LIQUIDATOR, PUBLIC_LIQUIDATOR);
        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(FINAL_PRICE));
        vm.stopPrank();

        assertEq(ticks.length, 2, "same two-tick final batch");
        assertEq(ticks[0].totalExpo, EXPECTED_A_EXPO, "tick A expo");
        assertEq(ticks[1].totalExpo, EXPECTED_B_EXPO, "tick B expo");
        assertEq(ticks[0].remainingCollateral, EXPECTED_A_REMAINING, "tick A floor");
        assertEq(ticks[1].remainingCollateral, EXPECTED_B_REMAINING, "tick B floor");
        assertGt(ticks[0].remainingCollateral, 0, "tick A is solvent");
        assertGt(ticks[1].remainingCollateral, 0, "tick B is solvent");
        assertEq(protocol.getTotalLongPositions(), 0, "all positions removed");
        assertEq(protocol.getTotalExpo(), 0, "all exposure removed");
        assertEq(protocol.getBalanceLong(), 1, "exact one-wei residue");
        assertGt(protocol.getBalanceLong(), protocol.getTotalExpo(), "source violates Rebalancer invariant");
    }

    /// @dev Independent arithmetic proof, without calling the tick-value helper.
    function test_C_independentWholeDollarFloorSumMissesAggregateByExactlyOneWei() public {
        Types.ApplyPnlAndFundingData memory pnl =
            protocol.i_applyPnlAndFunding(FINAL_PRICE, uint128(block.timestamp - 30 seconds));
        assertEq(pnl.tempLongBalance, EXPECTED_TEMP_LONG_BALANCE, "temporary long balance");

        uint256 price = uint256(FINAL_PRICE);
        uint256 valueA = EXPECTED_A_EXPO * (price - EXPECTED_A_PRICE_WITHOUT_PENALTY) / price;
        uint256 valueB = EXPECTED_B_EXPO * (price - EXPECTED_B_PRICE_WITHOUT_PENALTY) / price;
        assertEq(valueA, uint256(EXPECTED_A_REMAINING), "independent A floor");
        assertEq(valueB, uint256(EXPECTED_B_REMAINING), "independent B floor");
        assertEq(valueA + valueB, uint256(EXPECTED_TEMP_LONG_BALANCE) - 1, "sum of floors loses one wei");
        assertEq(uint256(EXPECTED_TEMP_LONG_BALANCE) - valueA - valueB, 1, "exact mismatch");
    }

    /// @dev Same-snapshot retry control: public liquidators cannot make partial
    /// progress because the two-tick transaction is atomic and rolls back each time.
    function test_D_threeDedicatedRetriesMakeZeroCommittedProgress() public {
        uint256 positionsBefore = protocol.getTotalLongPositions();
        uint256 expoBefore = protocol.getTotalExpo();
        uint256 longBefore = protocol.getBalanceLong();
        int24 highestBefore = protocol.getHighestPopulatedTick();
        uint256 liquidatorBefore = wstETH.balanceOf(PUBLIC_LIQUIDATOR);

        for (uint256 i; i < 3; ++i) {
            vm.startPrank(PUBLIC_LIQUIDATOR, PUBLIC_LIQUIDATOR);
            vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
            protocol.liquidate(abi.encode(FINAL_PRICE));
            vm.stopPrank();

            assertEq(protocol.getTotalLongPositions(), positionsBefore, "retry cannot remove a position");
            assertEq(protocol.getTotalExpo(), expoBefore, "retry cannot commit exposure update");
            assertEq(protocol.getBalanceLong(), longBefore, "retry cannot commit long update");
            assertEq(protocol.getHighestPopulatedTick(), highestBefore, "retry cannot advance liquidation bitmap");
            assertEq(wstETH.balanceOf(PUBLIC_LIQUIDATOR), liquidatorBefore, "retry pays no reward");
        }
    }
}
