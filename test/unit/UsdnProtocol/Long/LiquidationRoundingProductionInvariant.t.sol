// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { DEPLOYER } from "../../../utils/Constants.sol";
import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";

/// @notice Production-configuration regression harness for the USDN multi-tick
/// liquidation rounding invariant.
contract TestLiquidationRoundingProductionInvariant is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant CRASH_PRICE = 1000 ether;
    uint128 internal constant SECOND_AMOUNT = 2 ether;
    uint128 internal constant SECOND_DESIRED_LIQ = 1010 ether;

    int24 internal constant EXPECTED_INITIAL_TICK = 69200;
    int24 internal constant EXPECTED_SECOND_TICK = 69100;
    address internal constant ACTOR = address(0xBEEF);

    PositionId internal secondPos;
    uint152 internal victimShares;

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

        vm.deal(ACTOR, 10 ether);
        vm.deal(DEPLOYER, 10 ether);

        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "expected user-action iteration");
        assertEq(protocol.getProtocolFeeBps(), 800, "production protocol fee");
        assertEq(protocol.getFundingSF(), 120, "production funding SF");
        assertEq(protocol.getMinLongPosition(), 2 ether, "production min long");
        assertGt(protocol.getCloseExpoImbalanceLimitBps(), 0, "close imbalance limit enabled");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "rebalancer installed");

        assertEq(initialPosition.tick, EXPECTED_INITIAL_TICK, "unexpected initial tick");

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

        setUpUserPositionInVault(ACTOR, ProtocolAction.ValidateDeposit, 2 ether, ENTRY_PRICE);

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

    /// @dev Vulnerable v1.0.0 reverted here with UsdnProtocolInvalidLongExpo.
    /// The fixed code must commit the same production-config two-tick batch,
    /// reconcile its one-wei dust, and leave the long accounting invariant valid.
    function test_B_publicTwoTickLiquidationSucceedsAfterRoundingReconciliation() public {
        uint256 protocolSharesBefore = usdn.sharesOf(address(protocol));

        protocol.liquidate(abi.encode(CRASH_PRICE));

        assertEq(protocol.getTotalExpo(), 0, "all exposure must be removed");
        assertEq(protocol.getBalanceLong(), 0, "long-side rounding residue must be cleared");
        assertLe(protocol.getBalanceLong(), protocol.getTotalExpo(), "long balance invariant");

        // Dedicated liquidation does not validate the already pending withdrawal.
        assertEq(usdn.sharesOf(address(protocol)), protocolSharesBefore, "escrow remains until withdrawal validation");
        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(
            uint256(pending.action),
            uint256(ProtocolAction.ValidateWithdrawal),
            "withdrawal remains pending after dedicated liquidation"
        );
    }

    /// @dev Preserve the existing one-tick user-action behavior. The source fix
    /// must not turn the first validation into a different state transition.
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

    /// @dev Preserve the permissionless recovery control: the second one-tick
    /// validation still completes the withdrawal.
    function test_D_secondValidationRecoversPermissionlessly() public {
        uint256 assetBefore = wstETH.balanceOf(DEPLOYER);

        bool first = protocol.validateWithdrawal(
            payable(DEPLOYER), abi.encode(CRASH_PRICE), EMPTY_PREVIOUS_DATA
        );
        assertFalse(first, "first validation should process one tick only");

        bool second = protocol.validateWithdrawal(
            payable(DEPLOYER), abi.encode(CRASH_PRICE), EMPTY_PREVIOUS_DATA
        );
        assertTrue(second, "second one-tick validation should finish withdrawal");

        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(uint256(pending.action), uint256(ProtocolAction.None), "withdrawal must be cleared");
        assertGt(wstETH.balanceOf(DEPLOYER), assetBefore, "victim must receive underlying");
    }

    /// @dev Source-level control: even with the downstream Rebalancer removed,
    /// the liquidation accounting itself must no longer commit a one-wei residue.
    function test_E_withoutRebalancerSinkStillPreservesLongExpoInvariant() public {
        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));

        protocol.liquidate(abi.encode(CRASH_PRICE));

        assertEq(protocol.getTotalExpo(), 0, "all long exposure must be removed");
        assertEq(protocol.getBalanceLong(), 0, "rounding residue must be reconciled at source");
        assertLe(protocol.getBalanceLong(), protocol.getTotalExpo(), "pre-sink invariant preserved");
    }
}
