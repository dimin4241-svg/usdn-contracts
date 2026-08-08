// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { DEPLOYER } from "../../../utils/Constants.sol";
import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Impact extension of the fully post-bootstrap ordinary-position rounding witness.
/// The source state is created only through the public lifecycle. The focused impact tests opt into
/// fresh-Pyth semantics for Initiate* calls because production OracleMiddleware routes both Liquidation
/// and Initiate* Pyth updates through _getLowLatencyPrice(..., actionTimestamp = 0).
contract TestLiquidationRoundingPostBootstrapImpact is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;
    uint128 internal constant SUPPORT_DESIRED_LIQ = 1783 ether;
    uint128 internal constant A_DESIRED_LIQ = 1724 ether;
    uint128 internal constant B_DESIRED_LIQ = 1703 ether;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);
    address internal constant DEPOSITOR = address(0xA11CE);

    PositionId internal supportPos;
    PositionId internal posA;
    PositionId internal posB;
    uint152 internal victimShares;
    uint128 internal finalPrice;

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
        vm.deal(DEPOSITOR, 10 ether);
        vm.deal(DEPLOYER, 10 ether);
        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "production action iteration");
        assertEq(protocol.getProtocolFeeBps(), 800, "production protocol fee");
        assertEq(protocol.getFundingSF(), 120, "production funding SF");
        assertEq(protocol.getMinLongPosition(), 2 ether, "production min long");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "Rebalancer installed");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap positions gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap expo gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap long balance gone");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "empty long side before escrow");
        assertEq(protocol.getTotalExpo(), 0, "zero expo before escrow");
        assertEq(protocol.getBalanceLong(), 0, "zero long balance before escrow");

        // Escrow 0.1% of the original depositor's shares while long accounting is completely empty.
        // This pending withdrawal is not used as the primary impact claim; it is retained as an
        // orthogonal control that a failed dedicated liquidation rolls back unrelated user state.
        uint256 deployerShares = usdn.sharesOf(DEPLOYER);
        uint256 shares = deployerShares / 1000;
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
        assertTrue(initiated, "withdrawal must be initiated while long side is empty");
        assertGe(usdn.sharesOf(address(protocol)), victimShares, "victim shares escrowed");

        PendingAction memory pendingBeforeOpens = protocol.getUserPendingAction(DEPLOYER);
        assertEq(
            uint256(pendingBeforeOpens.action),
            uint256(ProtocolAction.ValidateWithdrawal),
            "withdrawal must be pending before ordinary opens"
        );

        _waitDelay();

        supportPos = setUpUserPositionInLong(
            OpenParams({
                user: SUPPORT_USER,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 20 ether,
                desiredLiqPrice: SUPPORT_DESIRED_LIQ,
                price: ENTRY_PRICE
            })
        );
        posA = setUpUserPositionInLong(
            OpenParams({
                user: USER_A,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 2 ether,
                desiredLiqPrice: A_DESIRED_LIQ,
                price: ENTRY_PRICE
            })
        );
        posB = setUpUserPositionInLong(
            OpenParams({
                user: USER_B,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 2 ether,
                desiredLiqPrice: B_DESIRED_LIQ,
                price: ENTRY_PRICE
            })
        );

        assertEq(supportPos.tick, 74_800, "support ordinary tick");
        assertEq(posA.tick, 74_500, "ordinary tick A");
        assertEq(posB.tick, 74_400, "ordinary tick B");
        assertEq(protocol.getTotalLongPositions(), 3, "three post-bootstrap ordinary positions");

        _waitDelay();
        _waitDelay();

        uint256 supportBoundary = protocol.getEffectivePriceForTick(supportPos.tick);
        Types.LiqTickInfo[] memory supportTicks = protocol.liquidate(abi.encode(uint128(supportBoundary - 1)));
        assertEq(supportTicks.length, 1, "support-only liquidation");
        assertGt(supportTicks[0].remainingCollateral, 0, "support is not bad debt");
        assertEq(protocol.getTotalLongPositions(), 2, "two final ordinary positions remain");
        assertEq(protocol.getHighestPopulatedTick(), 74_500, "final highest tick");

        _waitDelay();
        _waitDelay();
        finalPrice = uint128(protocol.getEffectivePriceForTick(posB.tick) - 1);
    }

    function test_A_pendingWithdrawalSurvivesDedicatedLiquidationRevert() public {
        uint256 escrowBefore = usdn.sharesOf(address(protocol));
        assertGe(escrowBefore, victimShares, "victim shares already escrowed");

        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(finalPrice));

        assertEq(usdn.sharesOf(address(protocol)), escrowBefore, "failed liquidation preserves escrow");
        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(uint256(pending.action), uint256(ProtocolAction.ValidateWithdrawal), "withdrawal remains pending");
        assertEq(protocol.getTotalLongPositions(), 2, "failed batch rolls positions back");
    }

    function test_B_sourceStateStillLeavesExactOneWeiWithVictimEscrowed() public {
        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));

        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(finalPrice));
        assertEq(ticks.length, 2, "two ordinary final ticks");
        assertGt(ticks[0].remainingCollateral, 0, "tick A positive collateral");
        assertGt(ticks[1].remainingCollateral, 0, "tick B positive collateral");
        assertEq(protocol.getTotalExpo(), 0, "all final exposure removed");
        assertEq(protocol.getBalanceLong(), 1, "same exact one-wei residue with pending withdrawal");
        assertGe(usdn.sharesOf(address(protocol)), victimShares, "victim shares remain escrowed");
    }

    function test_C_firstDepositAttemptCommitsOneTickThenRetryRevertsPersistently() public {
        // Production OracleMiddleware accepts the same recent Pyth publishTime for Liquidation and
        // InitiateDeposit. Align the unit mock with that production path for this focused test.
        oracleMiddleware.setUseRecentTimestampForInitiate(true);
        assertTrue(oracleMiddleware.useRecentTimestampForInitiate(), "fresh initiate timestamp enabled");

        uint128 depositAmount = 2 ether;
        wstETH.mintAndApprove(DEPOSITOR, depositAmount, address(protocol), depositAmount);
        uint256 depositorAssetBefore = wstETH.balanceOf(DEPOSITOR);
        uint256 securityDeposit = protocol.getSecurityDepositValue();

        // At this exact block the fresh initiate timestamp is block.timestamp - 30 seconds,
        // identical to the dedicated liquidation timestamp that reproduces the source boundary.
        vm.prank(DEPOSITOR);
        bool first = protocol.initiateDeposit{ value: securityDeposit }(
            depositAmount,
            0,
            DEPOSITOR,
            payable(DEPOSITOR),
            type(uint256).max,
            abi.encode(finalPrice),
            EMPTY_PREVIOUS_DATA
        );

        assertFalse(first, "first user action is consumed by pending liquidation");
        assertEq(protocol.getTotalLongPositions(), 1, "first action commits exactly one liquidation tick");
        assertEq(protocol.getHighestPopulatedTick(), posB.tick, "only final B tick remains");
        assertEq(wstETH.balanceOf(DEPOSITOR), depositorAssetBefore, "failed initiation takes no depositor asset");
        PendingAction memory noDeposit = protocol.getUserPendingAction(DEPOSITOR);
        assertEq(uint256(noDeposit.action), uint256(ProtocolAction.None), "deposit was not initiated");

        uint256 longBalanceAfterFirst = protocol.getBalanceLong();
        uint256 totalExpoAfterFirst = protocol.getTotalExpo();
        assertGt(totalExpoAfterFirst, 0, "one valid position still remains");
        assertLe(longBalanceAfterFirst, totalExpoAfterFirst, "state remains representable after first partial step");

        // The next normal user attempt reaches the last tick. Its transaction must roll back because
        // the aggregate-vs-per-tick rounding residue makes the production Rebalancer invariant fail.
        vm.startPrank(DEPOSITOR);
        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.initiateDeposit{ value: securityDeposit }(
            depositAmount,
            0,
            DEPOSITOR,
            payable(DEPOSITOR),
            type(uint256).max,
            abi.encode(finalPrice),
            EMPTY_PREVIOUS_DATA
        );
        vm.stopPrank();

        assertEq(protocol.getTotalLongPositions(), 1, "reverted retry cannot clear final tick");
        assertEq(protocol.getBalanceLong(), longBalanceAfterFirst, "reverted retry preserves long balance");
        assertEq(protocol.getTotalExpo(), totalExpoAfterFirst, "reverted retry preserves exposure");
        assertEq(wstETH.balanceOf(DEPOSITOR), depositorAssetBefore, "reverted retry takes no depositor asset");

        // Retrying is not a recovery mechanism: with no intervening state change the final liquidation
        // deterministically hits the same invariant again.
        vm.startPrank(DEPOSITOR);
        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.initiateDeposit{ value: securityDeposit }(
            depositAmount,
            0,
            DEPOSITOR,
            payable(DEPOSITOR),
            type(uint256).max,
            abi.encode(finalPrice),
            EMPTY_PREVIOUS_DATA
        );
        vm.stopPrank();

        assertEq(protocol.getTotalLongPositions(), 1, "final tick remains stuck across retries");
    }

    function test_D_withoutRebalancerSameTwoStepPathEndsAtExactOneWei() public {
        oracleMiddleware.setUseRecentTimestampForInitiate(true);

        uint128 depositAmount = 2 ether;
        wstETH.mintAndApprove(DEPOSITOR, depositAmount, address(protocol), depositAmount);
        uint256 securityDeposit = protocol.getSecurityDepositValue();

        vm.prank(DEPOSITOR);
        bool first = protocol.initiateDeposit{ value: securityDeposit }(
            depositAmount,
            0,
            DEPOSITOR,
            payable(DEPOSITOR),
            type(uint256).max,
            abi.encode(finalPrice),
            EMPTY_PREVIOUS_DATA
        );
        assertFalse(first, "first step clears one tick only");
        assertEq(protocol.getTotalLongPositions(), 1, "one tick remains before control");

        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));

        vm.prank(DEPOSITOR);
        bool second = protocol.initiateDeposit{ value: securityDeposit }(
            depositAmount,
            0,
            DEPOSITOR,
            payable(DEPOSITOR),
            type(uint256).max,
            abi.encode(finalPrice),
            EMPTY_PREVIOUS_DATA
        );

        assertTrue(second, "removing only the production sink lets final liquidation finish");
        assertEq(protocol.getTotalLongPositions(), 0, "final tick removed");
        assertEq(protocol.getTotalExpo(), 0, "all exposure removed");
        assertEq(protocol.getBalanceLong(), 1, "same exact one-wei source residue after sequential user path");
    }
}
