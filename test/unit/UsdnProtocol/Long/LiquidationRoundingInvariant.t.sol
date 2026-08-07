// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";

/// @dev Reproduces the multi-tick liquidation rounding invariant on the v1.0.0 test fixture.
/// No vm.store or direct protocol state mutation is used.
contract TestLiquidationRoundingInvariant is UsdnProtocolBaseFixture {
    PositionId internal secondPosition;

    function setUp() public {
        super._setUp(DEFAULT_PARAMS);

        secondPosition = setUpUserPositionInLong(
            OpenParams({
                user: address(this),
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 1 ether,
                desiredLiqPrice: 1010 ether,
                price: 2000 ether
            })
        );

        assertNotEq(secondPosition.tick, initialPosition.tick, "positions must occupy distinct ticks");
        _waitBeforeLiquidation();
    }

    /// @dev This variant disables the rebalancer/imbalance limits through DEFAULT_PARAMS
    /// to expose the underlying accounting residue directly in stored state.
    function test_publicLiquidateLeavesBalanceLongAboveTotalExpo() public {
        protocol.liquidate(abi.encode(uint128(1000 ether)));

        assertEq(protocol.getTotalExpo(), 0, "all long exposure was removed");
        assertEq(protocol.getBalanceLong(), 1, "one wei long balance residue remains");
        assertGt(protocol.getBalanceLong(), protocol.getTotalExpo(), "accounting invariant is broken");

        vm.expectRevert();
        protocol.longAssetAvailableWithFunding(uint128(1000 ether), uint128(block.timestamp));
    }
}
