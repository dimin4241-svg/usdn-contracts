// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";

/// @notice Fuzzes a lifecycle where the initialization-created position is
/// completely gone before any position involved in the probe is opened.
/// Every later position is created through the ordinary public open/validate
/// path under production-like flags and limits.
contract TestLiquidationRoundingPostBootstrapFuzz is UsdnProtocolBaseFixture {
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

        vm.deal(SUPPORT_USER, 10 ether);
        vm.deal(USER_A, 10 ether);
        vm.deal(USER_B, 10 ether);
        super._setUp(params);

        // Permanently remove the initialization position before constructing
        // any state relevant to the fuzz case.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap must be gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap exposure must be gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap balance must be gone");

        // Return protocol accounting to the normal $2000 entry market using
        // the public price-update/liquidation path while the long side is empty.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "price reset must not create positions");
    }

    /// @dev Search the production-valid desired-liq-price space around the
    /// hand-tested near-market configuration. Amounts are kept at a known-valid
    /// 20/2/2 wstETH so a counterexample cannot be dismissed as a limit bypass.
    ///
    /// A failure of the final invariant is the desired fuzz counterexample:
    /// Foundry will print supportDesired/gapA/gapB, which can then be frozen
    /// into a deterministic Rebalancer-enabled regression.
    function testFuzz_fullyPostBootstrapOrdinaryFinalBatchDoesNotLeavePositiveResidue(
        uint16 supportDesiredRaw,
        uint16 gapARaw,
        uint16 gapBRaw
    ) public {
        uint256 supportDesired = bound(uint256(supportDesiredRaw), 1700, 1820);
        uint256 gapA = bound(uint256(gapARaw), 20, 100);
        uint256 gapB = bound(uint256(gapBRaw), 20, 100);
        if (supportDesired <= gapA + gapB + 1200) return;

        uint128 desiredSupport = uint128(supportDesired * 1 ether);
        uint128 desiredA = uint128((supportDesired - gapA) * 1 ether);
        uint128 desiredB = uint128((supportDesired - gapA - gapB) * 1 ether);

        PositionId memory supportPos = setUpUserPositionInLong(
            OpenParams({
                user: SUPPORT_USER,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 20 ether,
                desiredLiqPrice: desiredSupport,
                price: ENTRY_PRICE
            })
        );
        PositionId memory posA = setUpUserPositionInLong(
            OpenParams({
                user: USER_A,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 2 ether,
                desiredLiqPrice: desiredA,
                price: ENTRY_PRICE
            })
        );
        PositionId memory posB = setUpUserPositionInLong(
            OpenParams({
                user: USER_B,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 2 ether,
                desiredLiqPrice: desiredB,
                price: ENTRY_PRICE
            })
        );

        // Tick spacing can collapse nearby desired prices. Those are not
        // two-tick final-batch candidates and are intentionally skipped.
        if (!(supportPos.tick > posA.tick && posA.tick > posB.tick)) return;
        assertEq(protocol.getTotalLongPositions(), 3, "expected exactly three ordinary positions");

        _waitDelay();
        _waitDelay();

        // Stage 1: choose the exact current boundary of the support tick. This
        // avoids a brute-force price scan and lets the protocol itself account
        // for funding/accumulator changes.
        uint256 supportBoundary = protocol.getEffectivePriceForTick(supportPos.tick);
        if (supportBoundary <= 1) return;
        protocol.liquidate(abi.encode(uint128(supportBoundary - 1)));

        // If funding/rounding caused more than the support tick to become
        // liquidatable at the same boundary, this input is not the intended
        // staged two-tick final state.
        if (
            protocol.getTotalLongPositions() != 2
                || protocol.getHighestPopulatedTick() != posA.tick
        ) return;

        _waitDelay();
        _waitDelay();

        // Stage 2: remove only the downstream Rebalancer sink immediately
        // before the final batch so the source accounting state can commit and
        // be inspected. All reachability/state construction above used the
        // production Rebalancer.
        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));

        uint256 finalBoundary = protocol.getEffectivePriceForTick(posB.tick);
        if (finalBoundary <= 1) return;
        protocol.liquidate(abi.encode(uint128(finalBoundary - 1)));

        // Only cases in which both remaining ordinary positions were actually
        // liquidated are relevant to the reported multi-tick residue.
        if (protocol.getTotalLongPositions() != 0) return;

        uint256 expo = protocol.getTotalExpo();
        uint256 longBalance = protocol.getBalanceLong();
        assertLe(longBalance, expo, "POST_BOOTSTRAP_ROUNDING_COUNTEREXAMPLE");
    }
}
