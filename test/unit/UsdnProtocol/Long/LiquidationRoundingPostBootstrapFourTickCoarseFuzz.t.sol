// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Adversarial search for a fully post-bootstrap final batch of FOUR
/// ordinary ticks, all with strictly positive remaining collateral, liquidated
/// at exact whole-dollar prices. This probes whether independently rounded dust
/// accumulates beyond the already proven 2- and 3-tick witnesses.
contract TestLiquidationRoundingPostBootstrapFourTickCoarseFuzz is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xA001);
    address internal constant USER_B = address(0xB002);
    address internal constant USER_C = address(0xC003);
    address internal constant USER_D = address(0xD004);

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
        vm.deal(USER_D, 10 ether);
        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "production action iteration");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer installed");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap expo gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap balance gone");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "empty-side price reset");
    }

    function testFuzz_fourTickWholeDollarPositiveCollateralDoesNotLeaveResidue(
        uint16 supportRaw,
        uint16 gapARaw,
        uint16 gapBRaw,
        uint16 gapCRaw,
        uint16 gapDRaw
    ) public {
        uint256 supportDesired = bound(uint256(supportRaw), 1700, 1820);
        uint256 gapA = bound(uint256(gapARaw), 8, 55);
        uint256 gapB = bound(uint256(gapBRaw), 8, 55);
        uint256 gapC = bound(uint256(gapCRaw), 8, 55);
        uint256 gapD = bound(uint256(gapDRaw), 8, 55);
        if (supportDesired <= gapA + gapB + gapC + gapD + 1280) return;

        uint128 dSupport = uint128(supportDesired * 1 ether);
        uint128 dA = uint128((supportDesired - gapA) * 1 ether);
        uint128 dB = uint128((supportDesired - gapA - gapB) * 1 ether);
        uint128 dC = uint128((supportDesired - gapA - gapB - gapC) * 1 ether);
        uint128 dD = uint128((supportDesired - gapA - gapB - gapC - gapD) * 1 ether);

        PositionId memory support = setUpUserPositionInLong(
            OpenParams(SUPPORT_USER, ProtocolAction.ValidateOpenPosition, 20 ether, dSupport, ENTRY_PRICE)
        );
        PositionId memory a = setUpUserPositionInLong(
            OpenParams(USER_A, ProtocolAction.ValidateOpenPosition, 2 ether, dA, ENTRY_PRICE)
        );
        PositionId memory b = setUpUserPositionInLong(
            OpenParams(USER_B, ProtocolAction.ValidateOpenPosition, 2 ether, dB, ENTRY_PRICE)
        );
        PositionId memory c = setUpUserPositionInLong(
            OpenParams(USER_C, ProtocolAction.ValidateOpenPosition, 2 ether, dC, ENTRY_PRICE)
        );
        PositionId memory d = setUpUserPositionInLong(
            OpenParams(USER_D, ProtocolAction.ValidateOpenPosition, 2 ether, dD, ENTRY_PRICE)
        );

        if (!(support.tick > a.tick && a.tick > b.tick && b.tick > c.tick && c.tick > d.tick)) return;

        _waitDelay();
        _waitDelay();

        uint256 supportBoundary = protocol.getEffectivePriceForTick(support.tick);
        if (supportBoundary <= 1 ether) return;
        uint128 stagePrice = uint128(((supportBoundary - 1) / 1 ether) * 1 ether);
        if (stagePrice == 0) return;
        Types.LiqTickInfo[] memory staged = protocol.liquidate(abi.encode(stagePrice));
        if (staged.length != 1 || staged[0].remainingCollateral <= 0) return;
        if (protocol.getTotalLongPositions() != 4 || protocol.getHighestPopulatedTick() != a.tick) return;

        _waitDelay();
        _waitDelay();

        uint256 finalBoundary = protocol.getEffectivePriceForTick(d.tick);
        if (finalBoundary <= 1 ether) return;
        uint128 finalPrice = uint128(((finalBoundary - 1) / 1 ether) * 1 ether);
        if (finalPrice == 0) return;
        assertEq(uint256(stagePrice) % 1 ether, 0, "whole-dollar stage");
        assertEq(uint256(finalPrice) % 1 ether, 0, "whole-dollar final");

        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));
        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(finalPrice));

        if (protocol.getTotalLongPositions() != 0 || ticks.length != 4) return;
        for (uint256 i; i < ticks.length; ++i) {
            if (ticks[i].remainingCollateral <= 0) return;
        }

        assertLe(
            protocol.getBalanceLong(),
            protocol.getTotalExpo(),
            "FOUR_TICK_POSITIVE_COLLATERAL_WHOLE_DOLLAR_COUNTEREXAMPLE"
        );
    }
}
