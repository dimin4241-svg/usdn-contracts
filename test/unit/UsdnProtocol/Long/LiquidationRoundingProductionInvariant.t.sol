// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { DEPLOYER } from "../../../utils/Constants.sol";
import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";

/// @notice Production-configuration reachability and severity harness for the
/// USDN multi-tick liquidation rounding invariant.
///
/// Base: SmarDex-Ecosystem/usdn-contracts v1.0.0
/// Commit: df398cdf28f3b9a4ec487dc26051ff55ed3bc056
///
/// Important properties:
/// - no vm.store and no direct mutation of protocol accounting state;
/// - positions/deposits/withdrawals use normal production action paths;
/// - funding + protocol fees remain enabled;
/// - all economically relevant default safety mechanisms are enabled before
///   initialization and remain enabled for the whole scenario;
/// - the initial long is scaled to 200 wstETH, while the second position is the
///   production minimum of 2 wstETH;
/// - the corrected user-open semantics put the two final positions at ticks
///   69200 and 69100; the crash price is therefore 1000 USD, not 1010 USD.
contract TestLiquidationRoundingProductionInvariant is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant CRASH_PRICE = 1000 ether;
    uint128 internal constant SECOND_AMOUNT = 2 ether;
    uint128 internal constant SECOND_DESIRED_LIQ = 1010 ether;

    int24 internal constant EXPECTED_INITIAL_TICK = 69200;
    int24 internal constant EXPECTED_SECOND_TICK = 69100;

    // Use an EOA-like address for fixture user actions. With the production
    // security deposit enabled, action validation refunds ETH to the validator;
    // using address(this) would make the harness itself reject the plain ETH
    // refund and produce an unrelated UsdnProtocolEtherRefundFailed().
    address internal constant ACTOR = address(0xBEEF);

    PositionId internal secondPos;
    uint152 internal victimShares;

    function setUp() public {
        params = DEFAULT_PARAMS;
        params.initialLong = 200 ether;

        // Keep the production economic/accounting mechanisms enabled from the
        // beginning. Roles are intentionally left in the fixture-friendly mode;
        // role layout has no bearing on liquidation arithmetic.
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

        // Fund only normal payable action callers. This changes no protocol
        // accounting state and merely supplies the configured security deposit.
        vm.deal(ACTOR, 10 ether);
        vm.deal(DEPLOYER, 10 ether);

        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "expected user-action iteration");
        assertEq(protocol.getProtocolFeeBps(), 800, "production protocol fee");
        assertEq(protocol.getFundingSF(), 120, "production funding SF");
        assertEq(protocol.getMinLongPosition(), 2 ether, "production min long");
        assertGt(protocol.getCloseExpoImbalanceLimitBps(), 0, "close imbalance limit enabled");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "rebalancer installed");

        // Initialization uses _getTickFromDesiredLiqPrice(), which adds the
        // liquidation penalty before tick-spacing rounding.
        assertEq(initialPosition.tick, EXPECTED_INITIAL_TICK, "unexpected initial tick");

        // Normal user opens use getEffectiveTickForPrice() directly. With the
        // production funding projection and the 1010 USD desired liquidation
        // price, this position belongs to tick 69100 (not 69300).
        secondPos = setUpUserPositionInLong(
            OpenParams({
                user: ACTOR,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: SECOND_AMOUNT,
                desiredLiqPrice: SECOND_DESIRED_LIQ,
                price: ENTRY_PRICE
            })
        );
        assertEq(secondPos.tick, EXPECTED_SECOND_TICK, "unexpected second tick");
        assertNotEq(secondPos.tick, initialPosition.tick, "positions must occupy different ticks");

        // Bring the small long-heavy imbalance back toward equilibrium using a
        // normal vault deposit. Funding/protocol fees remain enabled throughout.
        setUpUserPositionInVault(ACTOR, ProtocolAction.ValidateDeposit, 2 ether, ENTRY_PRICE);

        // Escrow a material fraction of the initial depositor's USDN shares
        // before the price drop. 5% is roughly 9-10 wstETH of vault value in
        // this fixture and remains inside the production withdrawal limit.
        uint256 deployerShares = usdn.sharesOf(DEPLOYER);
        uint256 shares = deployerShares / 20;
        require(shares > 0 && shares <= type(uint152).max, "invalid victim share amount");
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
        assertTrue(initiated, "withdrawal must be initiated");

        _waitDelay();
    }

    function test_A_correctProductionTicksAndEscrow() public view {
        assertEq(initialPosition.tick, EXPECTED_INITIAL_TICK, "initial tick");
        assertEq(secondPos.tick, EXPECTED_SECOND_TICK, "second tick");

        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(
            uint256(pending.action),
            uint256(ProtocolAction.ValidateWithdrawal),
            "withdrawal must remain pending before crash"
        );
        assertGe(usdn.sharesOf(address(protocol)), victimShares, "victim shares must be escrowed");
    }

    /// @dev Dedicated liquidate() processes up to 10 ticks. At 1000 USD both
    /// final populated ticks are in the same batch. Independent per-tick floor
    /// rounding leaves balanceLong one wei above totalExpo; the production
    /// Rebalancer invariant check then reverts the whole transaction.
    function test_B_publicTwoTickLiquidationRevertsAtProductionInvariant() public {
        uint256 protocolSharesBefore = usdn.sharesOf(address(protocol));

        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(CRASH_PRICE));

        // Revert rolls back the attempted liquidation; the already-initiated
        // withdrawal remains escrowed.
        assertEq(usdn.sharesOf(address(protocol)), protocolSharesBefore, "escrow must survive failed liquidation");
        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(
            uint256(pending.action),
            uint256(ProtocolAction.ValidateWithdrawal),
            "withdrawal must remain pending"
        );
    }

    /// @dev User actions use liquidationIteration == 1. The first validation
    /// therefore commits one tick of progress and returns false instead of
    /// reaching the final Rebalancer sink.
    function test_C_firstWithdrawalValidationCommitsOneTickButPaysNothing() public {
        uint256 assetBefore = wstETH.balanceOf(DEPLOYER);
        uint256 sharesBefore = usdn.sharesOf(address(protocol));

        bool first = protocol.validateWithdrawal(
            payable(DEPLOYER), abi.encode(CRASH_PRICE), EMPTY_PREVIOUS_DATA
        );

        assertFalse(first, "first validation must stop on pending liquidation");
        assertEq(wstETH.balanceOf(DEPLOYER), assetBefore, "victim must receive no underlying yet");
        assertEq(usdn.sharesOf(address(protocol)), sharesBefore, "victim shares remain escrowed");

        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(
            uint256(pending.action),
            uint256(ProtocolAction.ValidateWithdrawal),
            "withdrawal must still be pending"
        );
    }

    /// @dev Severity control: a second permissionless validation handles the
    /// final single tick. A one-tick liquidation cannot create the positive
    /// balanceLong > totalExpo residue, so the withdrawal should complete.
    function test_D_secondValidationRecoversPermissionlessly() public {
        uint256 assetBefore = wstETH.balanceOf(DEPLOYER);

        bool first = protocol.validateWithdrawal(
            payable(DEPLOYER), abi.encode(CRASH_PRICE), EMPTY_PREVIOUS_DATA
        );
        assertFalse(first, "first validation should process one tick only");

        // Deliberately call as a third party: validateWithdrawal is permissionless
        // with respect to msg.sender; the validator address identifies the action.
        bool second = protocol.validateWithdrawal(
            payable(DEPLOYER), abi.encode(CRASH_PRICE), EMPTY_PREVIOUS_DATA
        );
        assertTrue(second, "second one-tick validation should finish withdrawal");

        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(uint256(pending.action), uint256(ProtocolAction.None), "withdrawal must be cleared");
        assertGt(wstETH.balanceOf(DEPLOYER), assetBefore, "victim must receive underlying");
    }
}
