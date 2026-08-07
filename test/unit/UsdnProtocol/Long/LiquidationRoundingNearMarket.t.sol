// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { console2 } from "forge-std/console2.sol";
import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";

/// @notice Strong reachability probe: bootstrap is removed first. The complete
/// later state is then created only through ordinary public user opens. One
/// ordinary support tick is liquidated first; the final batch contains two
/// other ordinary positions and is scanned for the rounding invariant failure.
contract TestLiquidationRoundingNearMarket is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);

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

        vm.deal(SUPPORT_USER, 10 ether);
        vm.deal(USER_A, 10 ether);
        vm.deal(USER_B, 10 ether);
        super._setUp(params);

        // Remove bootstrap completely before any position relevant to the probe
        // is created.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap must be gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap exposure must be gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap balance must be gone");

        // Bring accounting price back to $2000 through the normal public path.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));

        // All positions below are ordinary user opens performed after bootstrap
        // has already disappeared.
        supportPos = setUpUserPositionInLong(
            OpenParams({
                user: SUPPORT_USER,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 20 ether,
                desiredLiqPrice: 1800 ether,
                price: ENTRY_PRICE
            })
        );
        posA = setUpUserPositionInLong(
            OpenParams({
                user: USER_A,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 2 ether,
                desiredLiqPrice: 1750 ether,
                price: ENTRY_PRICE
            })
        );
        posB = setUpUserPositionInLong(
            OpenParams({
                user: USER_B,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 2 ether,
                desiredLiqPrice: 1700 ether,
                price: ENTRY_PRICE
            })
        );

        console2.log("support tick", int256(supportPos.tick));
        console2.log("ordinary tick A", int256(posA.tick));
        console2.log("ordinary tick B", int256(posB.tick));
        assertGt(supportPos.tick, posA.tick, "support tick must liquidate first");
        assertGt(posA.tick, posB.tick, "final ticks must be distinct");
        assertEq(protocol.getTotalLongPositions(), 3, "three ordinary positions expected");

        _waitDelay();
        _waitDelay();
    }

    function test_probeAllOrdinaryStagedPrices() public {
        // Find a normal first-stage price which removes only the upper support
        // tick. Each candidate starts from the identical three-position state.
        uint256 supportSnapshot = vm.snapshotState();
        bool supportRemoved;
        uint256 supportPrice;

        for (uint256 price = 1650; price <= 1820; ++price) {
            vm.revertToState(supportSnapshot);
            supportSnapshot = vm.snapshotState();

            protocol.liquidate(abi.encode(uint128(price * 1 ether)));
            if (
                protocol.getTotalLongPositions() == 2
                    && protocol.getHighestPopulatedTick() == posA.tick
            ) {
                supportRemoved = true;
                supportPrice = price;
                break;
            }
        }

        assertTrue(supportRemoved, "must find support-only liquidation price");
        console2.log("support-only liquidation price", supportPrice);
        assertEq(protocol.getTotalLongPositions(), 2, "only final ordinary positions remain");

        // Now scan the final two-tick batch. Rebalancer is removed only after
        // the entire reachable state has been built, so source accounting can
        // be inspected instead of reverting at the known downstream sink.
        _waitDelay();
        _waitDelay();
        uint256 finalSnapshot = vm.snapshotState();

        for (uint256 price = 1500; price <= supportPrice; ++price) {
            vm.revertToState(finalSnapshot);
            finalSnapshot = vm.snapshotState();

            vm.prank(managers.setExternalManager);
            protocol.setRebalancer(IRebalancer(address(0)));
            protocol.liquidate(abi.encode(uint128(price * 1 ether)));

            uint256 positions = protocol.getTotalLongPositions();
            uint256 expo = protocol.getTotalExpo();
            uint256 longBalance = protocol.getBalanceLong();
            if (positions == 0 && longBalance > expo) {
                console2.log("BROKEN INVARIANT AT", price);
                console2.log("totalExpo", expo);
                console2.log("balanceLong", longBalance);
                return;
            }
        }

        console2.log("no positive residue found in all-ordinary staged scan");
    }
}
