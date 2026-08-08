// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Multi-seed adversarial search for independent fully post-bootstrap,
/// whole-dollar, positive-collateral two-tick witnesses. This is intentionally
/// separate from the frozen regression so distinct fuzz seeds can demonstrate
/// that the existing tuple is not a singular hand-picked construction.
contract TestLiquidationRoundingPostBootstrapWholeDollarMultiSeedFuzz is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);

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
        super._setUp(params);

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap exposure gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap balance gone");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "empty-side price reset");
    }

    function testFuzz_positiveCollateralWholeDollarWitnessIsNotUnique(
        uint16 supportDesiredRaw,
        uint16 gapARaw,
        uint16 gapBRaw
    ) public {
        uint256 supportDesired = bound(uint256(supportDesiredRaw), 1650, 1800);
        uint256 gapA = bound(uint256(gapARaw), 20, 140);
        uint256 gapB = bound(uint256(gapBRaw), 20, 140);
        if (supportDesired <= gapA + gapB + 1200) return;

        uint128 desiredSupport = uint128(supportDesired * 1 ether);
        uint128 desiredA = uint128((supportDesired - gapA) * 1 ether);
        uint128 desiredB = uint128((supportDesired - gapA - gapB) * 1 ether);

        PositionId memory supportPos = setUpUserPositionInLong(
            OpenParams(SUPPORT_USER, ProtocolAction.ValidateOpenPosition, 20 ether, desiredSupport, ENTRY_PRICE)
        );
        PositionId memory posA = setUpUserPositionInLong(
            OpenParams(USER_A, ProtocolAction.ValidateOpenPosition, 2 ether, desiredA, ENTRY_PRICE)
        );
        PositionId memory posB = setUpUserPositionInLong(
            OpenParams(USER_B, ProtocolAction.ValidateOpenPosition, 2 ether, desiredB, ENTRY_PRICE)
        );

        if (!(supportPos.tick > posA.tick && posA.tick > posB.tick)) return;

        _waitDelay();
        _waitDelay();

        uint256 supportBoundary = protocol.getEffectivePriceForTick(supportPos.tick);
        if (supportBoundary <= 1 ether) return;
        uint128 stagePrice = uint128(((supportBoundary - 1) / 1 ether) * 1 ether);
        if (stagePrice == 0) return;
        Types.LiqTickInfo[] memory staged = protocol.liquidate(abi.encode(stagePrice));
        if (staged.length != 1 || staged[0].remainingCollateral <= 0) return;

        if (protocol.getTotalLongPositions() != 2 || protocol.getHighestPopulatedTick() != posA.tick) return;

        _waitDelay();
        _waitDelay();

        uint256 finalBoundary = protocol.getEffectivePriceForTick(posB.tick);
        if (finalBoundary <= 1 ether) return;
        uint128 finalPrice = uint128(((finalBoundary - 1) / 1 ether) * 1 ether);
        if (finalPrice == 0) return;

        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));
        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(finalPrice));

        if (protocol.getTotalLongPositions() != 0 || ticks.length != 2) return;
        if (ticks[0].remainingCollateral <= 0 || ticks[1].remainingCollateral <= 0) return;

        assertEq(uint256(stagePrice) % 1 ether, 0, "whole-dollar stage");
        assertEq(uint256(finalPrice) % 1 ether, 0, "whole-dollar final");

        uint256 expo = protocol.getTotalExpo();
        uint256 longBalance = protocol.getBalanceLong();
        assertLe(longBalance, expo, "MULTISEED_POSITIVE_COLLATERAL_WHOLE_DOLLAR_COUNTEREXAMPLE");
    }
}
