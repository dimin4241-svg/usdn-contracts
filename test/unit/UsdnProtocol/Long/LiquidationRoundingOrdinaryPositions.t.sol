// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";

/// @notice Stronger reachability control for the multi-tick liquidation rounding
/// issue. The initialize()-created bootstrap position is first removed by a
/// normal single-tick public liquidation. The later dangerous final batch then
/// contains only positions created through ordinary initiate/validate opens.
contract TestLiquidationRoundingOrdinaryPositions is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;
    uint128 internal constant FINAL_CRASH_PRICE = 870 ether;

    address internal constant USER_A = address(0xCAFE);
    address internal constant USER_B = address(0xBEEF);

    PositionId internal posA;
    PositionId internal posB;
    int24 internal bootstrapTick;

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

        vm.deal(USER_A, 10 ether);
        vm.deal(USER_B, 10 ether);

        super._setUp(params);
        bootstrapTick = initialPosition.tick;

        // Two minimum-size ordinary positions at materially lower liquidation
        // prices. They are small enough to fit the production open-imbalance
        // limit while the large bootstrap position still exists.
        posA = setUpUserPositionInLong(
            OpenParams({
                user: USER_A,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 2 ether,
                desiredLiqPrice: 900 ether,
                price: ENTRY_PRICE
            })
        );
        posB = setUpUserPositionInLong(
            OpenParams({
                user: USER_B,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 2 ether,
                desiredLiqPrice: 890 ether,
                price: ENTRY_PRICE
            })
        );

        assertGt(bootstrapTick, posA.tick, "bootstrap must liquidate first");
        assertGt(posA.tick, posB.tick, "ordinary positions need distinct lower ticks");

        // First price move liquidates only the bootstrap tick. Because this is a
        // one-tick liquidation it cannot create the positive rounding residue.
        // The two ordinary positions remain alive for the later final batch.
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));

        assertEq(protocol.getTotalLongPositions(), 2, "only the two ordinary positions should remain");
        assertEq(protocol.getHighestPopulatedTick(), posA.tick, "highest remaining tick must be ordinary");
        (Position memory a,) = protocol.getLongPosition(posA);
        (Position memory b,) = protocol.getLongPosition(posB);
        assertTrue(a.validated && b.validated, "ordinary positions must survive bootstrap liquidation");
    }

    function test_A_finalBatchContainsOnlyOrdinaryPositions() public view {
        assertEq(protocol.getTotalLongPositions(), 2, "ordinary positions only");
        assertEq(protocol.getHighestPopulatedTick(), posA.tick, "ordinary highest tick");
        assertNotEq(posA.tick, bootstrapTick, "ordinary A is not bootstrap");
        assertNotEq(posB.tick, bootstrapTick, "ordinary B is not bootstrap");
    }

    function test_B_ordinaryOnlyDedicatedLiquidationReverts() public {
        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(FINAL_CRASH_PRICE));
    }

    /// @dev Isolation control: remove only the downstream Rebalancer after the
    /// bootstrap is already gone, then inspect the accounting state produced by
    /// liquidating the two ordinary ticks together.
    function test_C_ordinaryOnlySourceStateBreaksInvariantWithoutSink() public {
        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));

        protocol.liquidate(abi.encode(FINAL_CRASH_PRICE));

        assertEq(protocol.getTotalExpo(), 0, "all ordinary exposure removed");
        assertGt(protocol.getBalanceLong(), 0, "positive residue remains");
        assertGt(protocol.getBalanceLong(), protocol.getTotalExpo(), "accounting invariant broken");
    }
}
