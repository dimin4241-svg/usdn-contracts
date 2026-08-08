// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { DEPLOYER } from "../../../utils/Constants.sol";
import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Escrow-impact extension of the fully post-bootstrap ordinary-position
/// rounding witness. The victim withdrawal is initiated only after bootstrap
/// accounting has reached 0/0/0, and before any of the later witness positions
/// are created.
contract TestLiquidationRoundingPostBootstrapImpact is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;
    uint128 internal constant SUPPORT_DESIRED_LIQ = 1783 ether;
    uint128 internal constant A_DESIRED_LIQ = 1724 ether;
    uint128 internal constant B_DESIRED_LIQ = 1703 ether;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);

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

        // Escrow 0.1% of the original depositor's shares while long accounting
        // is completely empty. This is intentionally small so the pending-vault
        // reservation cannot be mistaken for the source of the later long-side
        // rounding condition.
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
        Types.LiqTickInfo[] memory supportTicks =
            protocol.liquidate(abi.encode(uint128(supportBoundary - 1)));
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

    function test_C_firstPermissionlessValidationCommitsOneTickButPaysNothing() public {
        uint256 assetBefore = wstETH.balanceOf(DEPLOYER);
        uint256 escrowBefore = usdn.sharesOf(address(protocol));

        bool first = protocol.validateWithdrawal(payable(DEPLOYER), abi.encode(finalPrice), EMPTY_PREVIOUS_DATA);
        assertFalse(first, "first validation stops on one pending liquidation tick");
        assertEq(wstETH.balanceOf(DEPLOYER), assetBefore, "no underlying paid on first validation");
        assertEq(usdn.sharesOf(address(protocol)), escrowBefore, "shares stay escrowed after first validation");
        assertEq(protocol.getTotalLongPositions(), 1, "exactly one ordinary tick committed");

        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(uint256(pending.action), uint256(ProtocolAction.ValidateWithdrawal), "withdrawal still pending");
    }

    function test_D_secondPermissionlessValidationCompletesWithdrawal() public {
        uint256 assetBefore = wstETH.balanceOf(DEPLOYER);

        bool first = protocol.validateWithdrawal(payable(DEPLOYER), abi.encode(finalPrice), EMPTY_PREVIOUS_DATA);
        assertFalse(first, "first validation processes one tick");
        bool second = protocol.validateWithdrawal(payable(DEPLOYER), abi.encode(finalPrice), EMPTY_PREVIOUS_DATA);
        assertTrue(second, "second one-tick validation completes withdrawal");

        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(uint256(pending.action), uint256(ProtocolAction.None), "withdrawal cleared");
        assertGt(wstETH.balanceOf(DEPLOYER), assetBefore, "victim receives underlying");
    }
}
