// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { DEPLOYER } from "../../../utils/Constants.sol";
import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";

/// @notice User-impact harness for the fully post-bootstrap ordinary-position
/// rounding witness. The initialization long is completely gone before any
/// witness position is opened. A real vault withdrawal is then initiated after
/// the support tick is removed and before the final two-tick liquidation.
contract TestLiquidationRoundingPostBootstrapImpact is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);
    address internal constant RECOVERY_KEEPER = address(0xA11CE);

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
        params.flags.enableRoles = true;

        vm.deal(SUPPORT_USER, 10 ether);
        vm.deal(USER_A, 10 ether);
        vm.deal(USER_B, 10 ether);
        vm.deal(RECOVERY_KEEPER, 10 ether);
        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "production user-action iteration");
        assertEq(protocol.getProtocolFeeBps(), 800, "production protocol fee");
        assertEq(protocol.getFundingSF(), 120, "production funding SF");
        assertEq(protocol.getMinLongPosition(), 2 ether, "production min long");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer installed");

        // Permanently remove all bootstrap long accounting first.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap positions must be gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap totalExpo must be gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap balanceLong must be gone");

        // Reset the market accounting price while the long side is empty.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "price reset must keep empty long side");

        // Ordinary post-bootstrap positions. These are the same deterministic
        // parameters found by the fuzz counterexample.
        supportPos = setUpUserPositionInLong(
            OpenParams(SUPPORT_USER, ProtocolAction.ValidateOpenPosition, 20 ether, 1783 ether, ENTRY_PRICE)
        );
        posA = setUpUserPositionInLong(
            OpenParams(USER_A, ProtocolAction.ValidateOpenPosition, 2 ether, 1724 ether, ENTRY_PRICE)
        );
        posB = setUpUserPositionInLong(
            OpenParams(USER_B, ProtocolAction.ValidateOpenPosition, 2 ether, 1703 ether, ENTRY_PRICE)
        );
        assertEq(supportPos.tick, 74_800, "support tick");
        assertEq(posA.tick, 74_500, "tick A");
        assertEq(posB.tick, 74_400, "tick B");

        _waitDelay();
        _waitDelay();

        // Remove only the support position through the normal dedicated path,
        // with the production Rebalancer still installed.
        uint256 supportBoundary = protocol.getEffectivePriceForTick(supportPos.tick);
        protocol.liquidate(abi.encode(uint128(supportBoundary - 1)));
        assertEq(protocol.getTotalLongPositions(), 2, "only two ordinary final positions must remain");
        assertEq(protocol.getHighestPopulatedTick(), posA.tick, "unexpected final highest tick");

        // Initiate a real pending withdrawal at the current safe market price.
        // One percent is deliberately conservative with respect to the enabled
        // withdrawal imbalance limit.
        uint256 deployerShares = usdn.sharesOf(DEPLOYER);
        uint256 shares = deployerShares / 100;
        require(shares > 0 && shares <= type(uint152).max, "invalid withdrawal share amount");
        victimShares = uint152(shares);

        vm.startPrank(DEPLOYER);
        usdn.approve(address(protocol), type(uint256).max);
        bool initiated = protocol.initiateWithdrawal{ value: protocol.getSecurityDepositValue() }(
            victimShares,
            0,
            DEPLOYER,
            payable(DEPLOYER),
            type(uint256).max,
            abi.encode(uint128(supportBoundary - 1)),
            EMPTY_PREVIOUS_DATA
        );
        vm.stopPrank();
        assertTrue(initiated, "withdrawal must be initiated");

        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(uint256(pending.action), uint256(ProtocolAction.ValidateWithdrawal), "withdrawal must be pending");
        assertGe(usdn.sharesOf(address(protocol)), victimShares, "victim shares must be escrowed");

        _waitDelay();

        // Recompute the final boundary after the real withdrawal initiation so
        // the impact proof does not assume that pending-vault accounting is inert.
        uint256 finalBoundary = protocol.getEffectivePriceForTick(posB.tick);
        require(finalBoundary > 1, "invalid final boundary");
        finalPrice = uint128(finalBoundary - 1);
    }

    /// @dev The same post-bootstrap state with a real withdrawal pending still
    /// makes the dedicated public liquidation path fail atomically.
    function test_A_pendingWithdrawalDoesNotRemoveDedicatedLiquidationFailure() public {
        uint256 sharesBefore = usdn.sharesOf(address(protocol));

        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(finalPrice));

        assertEq(protocol.getTotalLongPositions(), 2, "failed batch must roll back both ticks");
        assertEq(usdn.sharesOf(address(protocol)), sharesBefore, "escrow must survive failed liquidation");
        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(uint256(pending.action), uint256(ProtocolAction.ValidateWithdrawal), "withdrawal remains pending");
    }

    /// @dev A user trying to progress the pending withdrawal first pays the
    /// liveness cost: one tick is committed, validation returns false, no
    /// underlying is transferred and the shares remain escrowed.
    function test_B_firstValidationProcessesOneTickButPaysNothing() public {
        uint256 assetBefore = wstETH.balanceOf(DEPLOYER);
        uint256 sharesBefore = usdn.sharesOf(address(protocol));

        vm.prank(RECOVERY_KEEPER, RECOVERY_KEEPER);
        bool first = protocol.validateWithdrawal(payable(DEPLOYER), abi.encode(finalPrice), EMPTY_PREVIOUS_DATA);

        assertFalse(first, "first validation must stop on remaining liquidation");
        assertEq(protocol.getTotalLongPositions(), 1, "first validation must commit exactly one tick");
        assertEq(wstETH.balanceOf(DEPLOYER), assetBefore, "victim receives no underlying on first validation");
        assertEq(usdn.sharesOf(address(protocol)), sharesBefore, "victim shares remain escrowed");
        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(uint256(pending.action), uint256(ProtocolAction.ValidateWithdrawal), "withdrawal must stay pending");
    }

    /// @dev Severity bound: permissionless one-tick progress restores liveness.
    /// This proves concrete griefing/delay rather than a permanent protocol-wide
    /// freeze and is why Medium is more defensible than High.
    function test_C_secondPermissionlessValidationRecoversWithdrawal() public {
        uint256 assetBefore = wstETH.balanceOf(DEPLOYER);

        vm.startPrank(RECOVERY_KEEPER, RECOVERY_KEEPER);
        bool first = protocol.validateWithdrawal(payable(DEPLOYER), abi.encode(finalPrice), EMPTY_PREVIOUS_DATA);
        assertFalse(first, "first validation must process one tick only");

        bool second = protocol.validateWithdrawal(payable(DEPLOYER), abi.encode(finalPrice), EMPTY_PREVIOUS_DATA);
        vm.stopPrank();

        assertTrue(second, "second one-tick validation must complete withdrawal");
        assertEq(protocol.getTotalLongPositions(), 0, "all final positions must be processed");
        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(uint256(pending.action), uint256(ProtocolAction.None), "withdrawal must be cleared");
        assertGt(wstETH.balanceOf(DEPLOYER), assetBefore, "victim must finally receive underlying");
    }
}
