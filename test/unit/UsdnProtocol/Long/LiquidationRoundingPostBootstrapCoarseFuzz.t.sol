// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";

/// @notice Adversarial search for a fully post-bootstrap ordinary-only
/// liquidation-rounding witness where BOTH staged liquidation prices are whole
/// dollars. This deliberately removes the "boundary minus one price-wei" degree
/// of freedom from the earlier fuzz witness.
contract TestLiquidationRoundingPostBootstrapCoarseFuzz is UsdnProtocolBaseFixture {
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
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap must be gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap exposure must be gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap balance must be gone");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "price reset must keep long side empty");
    }

    function testFuzz_wholeDollarPricesDoNotLeavePositiveResidue(
        uint16 supportDesiredRaw,
        uint16 gapARaw,
        uint16 gapBRaw
    ) public {
        // <= 1800 is deliberately inside the fixture's production max-leverage
        // envelope at a $2000 entry price. Invalid opens must not terminate the
        // search and masquerade as a rounding counterexample.
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
        assertEq(protocol.getTotalLongPositions(), 3, "expected three ordinary positions");

        _waitDelay();
        _waitDelay();

        uint256 supportBoundary = protocol.getEffectivePriceForTick(supportPos.tick);
        if (supportBoundary <= 1 ether) return;
        uint128 stagePrice = uint128(((supportBoundary - 1) / 1 ether) * 1 ether);
        if (stagePrice == 0) return;
        protocol.liquidate(abi.encode(stagePrice));

        if (protocol.getTotalLongPositions() != 2 || protocol.getHighestPopulatedTick() != posA.tick) return;

        _waitDelay();
        _waitDelay();

        uint256 finalBoundary = protocol.getEffectivePriceForTick(posB.tick);
        if (finalBoundary <= 1 ether) return;
        uint128 finalPrice = uint128(((finalBoundary - 1) / 1 ether) * 1 ether);
        if (finalPrice == 0) return;

        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));
        protocol.liquidate(abi.encode(finalPrice));

        if (protocol.getTotalLongPositions() != 0) return;

        uint256 expo = protocol.getTotalExpo();
        uint256 longBalance = protocol.getBalanceLong();
        assertLe(longBalance, expo, "COARSE_ORACLE_POST_BOOTSTRAP_COUNTEREXAMPLE");
    }
}
