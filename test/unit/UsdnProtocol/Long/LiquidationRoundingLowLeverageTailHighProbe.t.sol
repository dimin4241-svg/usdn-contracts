// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { DEPLOYER } from "../../../utils/Constants.sol";
import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";

/// @notice Experimental High-severity probe.
/// Builds several ordinary liquidatable ticks plus a live-config minimum-sized,
/// almost-1x tail position. The tail remains far below the crash price. If
/// rounding accumulated while one-tick user-action liquidations drain the upper
/// ticks exceeds the tail's tiny trading exposure, the final withdrawal
/// validation reaches the production Rebalancer invariant and rolls back.
contract TestLiquidationRoundingLowLeverageTailHighProbe is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant CRASH_PRICE = 900 ether;
    uint128 internal constant LIVE_MIN_LONG = 0.65 ether;
    uint128 internal constant HIGH_AMOUNT = 2 ether;
    uint128 internal constant TAIL_DESIRED_LIQ = 20_000; // 2e-14 USD, just above TickMath minimum

    address internal constant ACTOR1 = address(0xA001);
    address internal constant ACTOR2 = address(0xA002);
    address internal constant ACTOR3 = address(0xA003);
    address internal constant ACTOR4 = address(0xA004);
    address internal constant ACTOR5 = address(0xA005);
    address internal constant TAIL_USER = address(0xC001);
    address internal constant THIRD_PARTY = address(0xB0B);

    PositionId internal p1;
    PositionId internal p2;
    PositionId internal p3;
    PositionId internal p4;
    PositionId internal p5;
    PositionId internal tail;
    uint152 internal victimShares;

    event RecoveryStep(uint256 indexed step, uint256 positions, uint256 totalExpo, uint256 balanceLong, int24 highest);

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

        _fund(ACTOR1);
        _fund(ACTOR2);
        _fund(ACTOR3);
        _fund(ACTOR4);
        _fund(ACTOR5);
        _fund(TAIL_USER);
        _fund(THIRD_PARTY);
        vm.deal(DEPLOYER, 10 ether);
        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "live user-action iteration");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "Rebalancer installed");

        // Match the current deployed minimum long size (0.65 wstETH).
        vm.prank(managers.setProtocolParamsManager);
        protocol.setMinLongPosition(LIVE_MIN_LONG);
        assertEq(protocol.getMinLongPosition(), LIVE_MIN_LONG, "live minimum long");

        // Create five additional ordinary distinct upper ticks. After each open,
        // rebalance through the normal vault path instead of disabling limits.
        p1 = _openAndBalance(ACTOR1, 1250 ether);
        p2 = _openAndBalance(ACTOR2, 1180 ether);
        p3 = _openAndBalance(ACTOR3, 1110 ether);
        p4 = _openAndBalance(ACTOR4, 1040 ether);
        p5 = _openAndBalance(ACTOR5, 970 ether);

        // Ordinary public near-1x tail. It is intentionally economically boring,
        // but uses no privileged accounting mutation and remains non-liquidatable
        // at any realistic crash price.
        tail = setUpUserPositionInLong(
            OpenParams(TAIL_USER, ProtocolAction.ValidateOpenPosition, LIVE_MIN_LONG, TAIL_DESIRED_LIQ, ENTRY_PRICE)
        );

        assertLt(tail.tick, p5.tick, "tail must be below all crash ticks");
        assertLt(tail.tick, initialPosition.tick, "tail below bootstrap tick");

        (Position memory tailPos,) = protocol.getLongPosition(tail);
        assertEq(tailPos.amount, LIVE_MIN_LONG, "tail amount");
        assertGe(tailPos.totalExpo, tailPos.amount, "tail total expo");
        assertLe(tailPos.totalExpo - tailPos.amount, 20, "tail trading expo must be dust-sized");

        // Put real USDN shares into protocol escrow before the crash.
        uint256 shares = usdn.sharesOf(DEPLOYER) / 100;
        require(shares > 0 && shares <= type(uint152).max, "invalid victim shares");
        victimShares = uint152(shares);
        vm.startPrank(DEPLOYER);
        usdn.approve(address(protocol), type(uint256).max);
        bool initiated = protocol.initiateWithdrawal{ value: protocol.getSecurityDepositValue() }(
            victimShares,
            0,
            DEPLOYER,
            payable(DEPLOYER),
            type(uint256).max,
            abi.encode(ENTRY_PRICE),
            EMPTY_PREVIOUS_DATA
        );
        vm.stopPrank();
        assertTrue(initiated, "withdrawal initiated");
        _waitDelay();
    }

    function test_A_dedicatedCrashMustHitInvariantWithTailRemaining() public {
        uint256 sharesBefore = usdn.sharesOf(address(protocol));
        uint256 positionsBefore = protocol.getTotalLongPositions();

        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(CRASH_PRICE));

        assertEq(protocol.getTotalLongPositions(), positionsBefore, "dedicated revert must roll back");
        assertEq(usdn.sharesOf(address(protocol)), sharesBefore, "withdrawal remains escrowed");
    }

    function test_B_oneTickRecoveryEventuallyRevertsBeforeWithdrawalCanComplete() public {
        uint256 assetBefore = wstETH.balanceOf(DEPLOYER);
        uint256 sharesBefore = usdn.sharesOf(address(protocol));
        bool sawInvariantRevert;

        // There are at most 7 upper ticks in this fixture. Give recovery ten attempts;
        // success before an invariant revert disproves this High path.
        for (uint256 i; i < 10; ++i) {
            vm.startPrank(THIRD_PARTY, THIRD_PARTY);
            try protocol.validateWithdrawal(payable(DEPLOYER), abi.encode(CRASH_PRICE), EMPTY_PREVIOUS_DATA) returns (
                bool completed
            ) {
                vm.stopPrank();
                emit RecoveryStep(
                    i,
                    protocol.getTotalLongPositions(),
                    protocol.getTotalExpo(),
                    protocol.getBalanceLong(),
                    protocol.getHighestPopulatedTick()
                );
                if (completed) {
                    assertTrue(false, "withdrawal recovered permissionlessly; High path disproved");
                }
            } catch (bytes memory reason) {
                vm.stopPrank();
                if (reason.length == 4 && bytes4(reason) == UsdnProtocolInvalidLongExpo.selector) {
                    sawInvariantRevert = true;
                    break;
                }
                assembly ("memory-safe") {
                    revert(add(reason, 0x20), mload(reason))
                }
            }
        }

        assertTrue(sawInvariantRevert, "expected final one-tick recovery invariant revert");
        assertEq(wstETH.balanceOf(DEPLOYER), assetBefore, "victim still receives no underlying");
        assertEq(usdn.sharesOf(address(protocol)), sharesBefore, "victim shares remain escrowed");
        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(uint256(pending.action), uint256(ProtocolAction.ValidateWithdrawal), "withdrawal remains pending");
    }

    function _openAndBalance(address user, uint128 desiredLiq) internal returns (PositionId memory pos) {
        pos = setUpUserPositionInLong(
            OpenParams(user, ProtocolAction.ValidateOpenPosition, HIGH_AMOUNT, desiredLiq, ENTRY_PRICE)
        );
        // A matching ordinary vault deposit keeps production imbalance limits live.
        setUpUserPositionInVault(user, ProtocolAction.ValidateDeposit, HIGH_AMOUNT, ENTRY_PRICE);
    }

    function _fund(address user) internal {
        vm.deal(user, 20 ether);
    }
}
