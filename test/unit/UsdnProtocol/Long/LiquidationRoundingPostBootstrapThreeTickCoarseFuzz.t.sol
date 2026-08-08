// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";

/// @notice Adversarial search for a stronger fully post-bootstrap witness where
/// THREE ordinary ticks are liquidated together at an exact whole-dollar oracle
/// price. A positive residue here demonstrates that the defect is not specific
/// to a two-tick final batch and that the fallback one-tick recovery cost can
/// scale with the number of independently rounded ticks.
contract TestLiquidationRoundingPostBootstrapThreeTickCoarseFuzz is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);
    address internal constant USER_C = address(0xC0DE);

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
        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "production action liquidation iteration");
        assertEq(protocol.getProtocolFeeBps(), 800, "production protocol fee");
        assertEq(protocol.getFundingSF(), 120, "production funding SF");
        assertEq(protocol.getMinLongPosition(), 2 ether, "production minimum long");
        assertGt(protocol.getCloseExpoImbalanceLimitBps(), 0, "production close imbalance limit");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer installed");

        // Fully remove the initialization-created position before creating any
        // witness position, then reset the accounting price on an empty long side.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap positions must be gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap expo must be gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap long balance must be gone");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "price reset keeps long side empty");
        assertEq(protocol.getTotalExpo(), 0, "price reset keeps expo zero");
        assertEq(protocol.getBalanceLong(), 0, "price reset keeps long balance zero");
    }

    function testFuzz_threeTickWholeDollarPricesDoNotLeavePositiveResidue(
        uint16 supportDesiredRaw,
        uint16 gapARaw,
        uint16 gapBRaw,
        uint16 gapCRaw
    ) public {
        uint256 supportDesired = bound(uint256(supportDesiredRaw), 1650, 1800);
        uint256 gapA = bound(uint256(gapARaw), 10, 100);
        uint256 gapB = bound(uint256(gapBRaw), 10, 100);
        uint256 gapC = bound(uint256(gapCRaw), 10, 100);

        // Keep the lowest desired liquidation price comfortably inside the
        // fixture's ordinary-open leverage envelope.
        if (supportDesired <= gapA + gapB + gapC + 1250) return;

        uint128 desiredSupport = uint128(supportDesired * 1 ether);
        uint128 desiredA = uint128((supportDesired - gapA) * 1 ether);
        uint128 desiredB = uint128((supportDesired - gapA - gapB) * 1 ether);
        uint128 desiredC = uint128((supportDesired - gapA - gapB - gapC) * 1 ether);

        PositionId memory supportPos = setUpUserPositionInLong(
            OpenParams(SUPPORT_USER, ProtocolAction.ValidateOpenPosition, 20 ether, desiredSupport, ENTRY_PRICE)
        );
        PositionId memory posA = setUpUserPositionInLong(
            OpenParams(USER_A, ProtocolAction.ValidateOpenPosition, 2 ether, desiredA, ENTRY_PRICE)
        );
        PositionId memory posB = setUpUserPositionInLong(
            OpenParams(USER_B, ProtocolAction.ValidateOpenPosition, 2 ether, desiredB, ENTRY_PRICE)
        );
        PositionId memory posC = setUpUserPositionInLong(
            OpenParams(USER_C, ProtocolAction.ValidateOpenPosition, 2 ether, desiredC, ENTRY_PRICE)
        );

        if (!(supportPos.tick > posA.tick && posA.tick > posB.tick && posB.tick > posC.tick)) return;
        assertEq(protocol.getTotalLongPositions(), 4, "support plus three ordinary final positions");

        _waitDelay();
        _waitDelay();

        // Stage only the support tick at a whole-dollar price.
        uint256 supportBoundary = protocol.getEffectivePriceForTick(supportPos.tick);
        if (supportBoundary <= 1 ether) return;
        uint128 stagePrice = uint128(((supportBoundary - 1) / 1 ether) * 1 ether);
        if (stagePrice == 0) return;
        assertEq(uint256(stagePrice) % 1 ether, 0, "stage price is whole-dollar");
        protocol.liquidate(abi.encode(stagePrice));

        if (protocol.getTotalLongPositions() != 3 || protocol.getHighestPopulatedTick() != posA.tick) return;

        _waitDelay();
        _waitDelay();

        // Put the final oracle price one whole-dollar bucket below C's effective
        // boundary, so A+B+C are all eligible in the same dedicated batch.
        uint256 finalBoundary = protocol.getEffectivePriceForTick(posC.tick);
        if (finalBoundary <= 1 ether) return;
        uint128 finalPrice = uint128(((finalBoundary - 1) / 1 ether) * 1 ether);
        if (finalPrice == 0) return;
        assertEq(uint256(finalPrice) % 1 ether, 0, "final price is whole-dollar");

        // Source isolation only: keep the real Rebalancer throughout state
        // construction, remove it immediately before the final call so a broken
        // accounting state can commit and be inspected instead of reverting.
        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));
        protocol.liquidate(abi.encode(finalPrice));

        if (protocol.getTotalLongPositions() != 0) return;

        uint256 expo = protocol.getTotalExpo();
        uint256 longBalance = protocol.getBalanceLong();
        assertLe(longBalance, expo, "THREE_TICK_WHOLE_DOLLAR_POST_BOOTSTRAP_COUNTEREXAMPLE");
    }
}
