// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { console2 } from "forge-std/src/console2.sol";
import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";

/// @notice Reachability probe which removes the bootstrap position before the
/// two ordinary positions are even created. The goal is to show that the issue
/// does not require either the initialization position or an extreme move from
/// the ordinary positions' entry price.
contract TestLiquidationRoundingNearMarket is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;

    address internal constant USER_A = address(0xCAFE);
    address internal constant USER_B = address(0xBEEF);

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

        vm.deal(USER_A, 10 ether);
        vm.deal(USER_B, 10 ether);
        super._setUp(params);

        // Remove the initialize-created position first, before creating either
        // of the positions used in the final multi-tick batch.
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap must be gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap exposure must be gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap balance must be gone");

        // Return to the entry market and create a large high-leverage normal
        // position to move the empty long side toward the production imbalance
        // target, followed by a small position on the adjacent lower tick.
        _waitDelay();
        posA = setUpUserPositionInLong(
            OpenParams({
                user: USER_A,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 20 ether,
                desiredLiqPrice: 1800 ether,
                price: ENTRY_PRICE
            })
        );
        posB = setUpUserPositionInLong(
            OpenParams({
                user: USER_B,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 2 ether,
                desiredLiqPrice: 1790 ether,
                price: ENTRY_PRICE
            })
        );

        assertNotEq(posA.tick, posB.tick, "two ordinary positions need different ticks");
        assertEq(protocol.getTotalLongPositions(), 2, "only post-bootstrap ordinary positions remain");
        _waitDelay();
    }

    /// @dev Diagnostic scan. Each candidate starts from exactly the same state.
    /// The test deliberately does not assert a particular candidate; the logs
    /// identify whether a nearby final price produces the invariant violation.
    function test_probeNearMarketPrices() public {
        uint256 initialSnapshot = vm.snapshotState();

        for (uint256 price = 1720; price <= 1810; price += 2) {
            vm.revertToState(initialSnapshot);
            initialSnapshot = vm.snapshotState();

            vm.prank(managers.setExternalManager);
            protocol.setRebalancer(IRebalancer(address(0)));

            protocol.liquidate(abi.encode(uint128(price * 1 ether)));

            uint256 positions = protocol.getTotalLongPositions();
            uint256 expo = protocol.getTotalExpo();
            uint256 longBalance = protocol.getBalanceLong();
            if (positions == 0) {
                console2.log("candidate price", price);
                console2.log("totalExpo", expo);
                console2.log("balanceLong", longBalance);
                if (longBalance > expo) {
                    console2.log("BROKEN INVARIANT AT", price);
                    return;
                }
            }
        }

        console2.log("no positive residue found in scanned near-market range");
    }
}
