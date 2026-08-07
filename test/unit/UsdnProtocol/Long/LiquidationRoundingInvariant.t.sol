// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";

/// @dev Reproduces a 1-wei accounting residue after a permissionless
/// multi-tick liquidation using only normal protocol entrypoints.
contract TestLiquidationRoundingInvariant is UsdnProtocolBaseFixture {
    PositionId internal secondPosition;

    function setUp() public {
        super._setUp(DEFAULT_PARAMS);

        // The fixture starts with a validated 5 wstETH long opened at $2000
        // with desired liquidation price ~= $1000. Create one more validated
        // position in a neighbouring tick through the public initiate/validate
        // flow; no storage mutation is used.
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

    function test_publicLiquidateLeavesBalanceLongAboveTotalExpo() public {
        // At $1000 both populated ticks are liquidatable in the same public
        // liquidate() call. Each tick's remaining collateral is rounded down
        // independently, so their sum is one wei below the temporary long
        // balance even though all long exposure is removed.
        protocol.liquidate(abi.encode(uint128(1000 ether)));

        assertEq(protocol.getTotalExpo(), 0, "all long exposure was removed");
        assertEq(protocol.getBalanceLong(), 1, "one wei long balance residue remains");
        assertGt(protocol.getBalanceLong(), protocol.getTotalExpo(), "core accounting invariant is broken");

        // The invalid state is observable by ordinary public accounting paths:
        // longAssetAvailableWithFunding -> _longAssetAvailable computes
        // totalExpo - balanceLong and therefore reverts from 0 - 1.
        vm.expectRevert();
        protocol.longAssetAvailableWithFunding(uint128(1000 ether), uint128(block.timestamp));
    }
}
