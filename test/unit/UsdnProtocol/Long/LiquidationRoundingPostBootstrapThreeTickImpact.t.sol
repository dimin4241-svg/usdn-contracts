// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { DEPLOYER } from "../../../utils/Constants.sol";
import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";

/// @notice Impact harness for the independently found three-tick witness. It
/// asks the strongest triager question: does the liveness cost grow when more
/// independently rounded ticks are pending? User actions retain the production
/// one-tick liquidation iteration.
contract TestLiquidationRoundingPostBootstrapThreeTickImpact is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;
    uint128 internal constant STAGE_PRICE = 1771 ether;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);
    address internal constant USER_C = address(0xC0DE);
    address internal constant KEEPER = address(0xA11CE);

    PositionId internal posA;
    PositionId internal posB;
    PositionId internal posC;
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
        vm.deal(USER_C, 10 ether);
        vm.deal(KEEPER, 10 ether);
        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "production user-action iteration");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer installed");

        // Remove bootstrap completely, then reset accounting price on empty side.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap expo gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap balance gone");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "empty-side price reset");

        PositionId memory supportPos = setUpUserPositionInLong(
            OpenParams(SUPPORT_USER, ProtocolAction.ValidateOpenPosition, 20 ether, 1772 ether, ENTRY_PRICE)
        );
        posA = setUpUserPositionInLong(
            OpenParams(USER_A, ProtocolAction.ValidateOpenPosition, 2 ether, 1760 ether, ENTRY_PRICE)
        );
        posB = setUpUserPositionInLong(
            OpenParams(USER_B, ProtocolAction.ValidateOpenPosition, 2 ether, 1740 ether, ENTRY_PRICE)
        );
        posC = setUpUserPositionInLong(
            OpenParams(USER_C, ProtocolAction.ValidateOpenPosition, 2 ether, 1728 ether, ENTRY_PRICE)
        );
        assertEq(supportPos.tick, 74_800, "support tick");
        assertEq(posA.tick, 74_700, "A tick");
        assertEq(posB.tick, 74_600, "B tick");
        assertEq(posC.tick, 74_500, "C tick");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(STAGE_PRICE));
        assertEq(protocol.getTotalLongPositions(), 3, "three final ordinary ticks remain");
        assertEq(protocol.getHighestPopulatedTick(), posA.tick, "A is highest final tick");

        // Put a real vault withdrawal into escrow while all three final ticks
        // are still live. Use only 1% to stay comfortably inside enabled limits.
        uint256 shares = usdn.sharesOf(DEPLOYER) / 100;
        require(shares > 0 && shares <= type(uint152).max, "bad withdrawal share amount");
        victimShares = uint152(shares);

        vm.startPrank(DEPLOYER);
        usdn.approve(address(protocol), type(uint256).max);
        bool initiated = protocol.initiateWithdrawal{ value: protocol.getSecurityDepositValue() }(
            victimShares,
            0,
            DEPLOYER,
            payable(DEPLOYER),
            type(uint256).max,
            abi.encode(STAGE_PRICE),
            EMPTY_PREVIOUS_DATA
        );
        vm.stopPrank();
        assertTrue(initiated, "withdrawal initiated");
        assertEq(
            uint256(protocol.getUserPendingAction(DEPLOYER).action),
            uint256(ProtocolAction.ValidateWithdrawal),
            "withdrawal pending"
        );
        assertGe(usdn.sharesOf(address(protocol)), victimShares, "shares escrowed");

        _waitDelay();

        // Recompute after withdrawal initiation. We intentionally use the exact
        // effective boundary minus one wei here to isolate impact/recovery count;
        // the separate deterministic reachability proof already establishes the
        // same defect at an exact whole-dollar price.
        uint256 boundary = protocol.getEffectivePriceForTick(posC.tick);
        require(boundary > 1, "bad final boundary");
        finalPrice = uint128(boundary - 1);
    }

    function test_A_pendingWithdrawalKeepsThreeTickDedicatedFailure() public {
        uint256 sharesBefore = usdn.sharesOf(address(protocol));
        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(finalPrice));

        assertEq(protocol.getTotalLongPositions(), 3, "dedicated failure rolls back all three ticks");
        assertEq(usdn.sharesOf(address(protocol)), sharesBefore, "escrow survives revert");
        assertEq(
            uint256(protocol.getUserPendingAction(DEPLOYER).action),
            uint256(ProtocolAction.ValidateWithdrawal),
            "withdrawal still pending"
        );
    }

    function test_B_firstRecoveryValidationCommitsOneTickAndPaysNothing() public {
        uint256 assetBefore = wstETH.balanceOf(DEPLOYER);
        uint256 sharesBefore = usdn.sharesOf(address(protocol));

        vm.prank(KEEPER, KEEPER);
        bool ok = protocol.validateWithdrawal(payable(DEPLOYER), abi.encode(finalPrice), EMPTY_PREVIOUS_DATA);

        assertFalse(ok, "first validation stops on remaining liquidation");
        assertEq(protocol.getTotalLongPositions(), 2, "exactly one of three ticks committed");
        assertEq(wstETH.balanceOf(DEPLOYER), assetBefore, "no underlying paid on first attempt");
        assertEq(usdn.sharesOf(address(protocol)), sharesBefore, "shares remain escrowed");
    }

    function test_C_secondRecoveryValidationStillDoesNotPay() public {
        uint256 assetBefore = wstETH.balanceOf(DEPLOYER);
        uint256 sharesBefore = usdn.sharesOf(address(protocol));

        vm.startPrank(KEEPER, KEEPER);
        bool first = protocol.validateWithdrawal(payable(DEPLOYER), abi.encode(finalPrice), EMPTY_PREVIOUS_DATA);
        bool second = protocol.validateWithdrawal(payable(DEPLOYER), abi.encode(finalPrice), EMPTY_PREVIOUS_DATA);
        vm.stopPrank();

        assertFalse(first, "first validation incomplete");
        assertFalse(second, "second validation still incomplete with one tick left");
        assertEq(protocol.getTotalLongPositions(), 1, "two validations commit two ticks");
        assertEq(wstETH.balanceOf(DEPLOYER), assetBefore, "still no underlying after second attempt");
        assertEq(usdn.sharesOf(address(protocol)), sharesBefore, "shares still escrowed after second attempt");
    }

    function test_D_thirdPermissionlessValidationFinallyCompletesWithdrawal() public {
        uint256 assetBefore = wstETH.balanceOf(DEPLOYER);

        vm.startPrank(KEEPER, KEEPER);
        bool first = protocol.validateWithdrawal(payable(DEPLOYER), abi.encode(finalPrice), EMPTY_PREVIOUS_DATA);
        bool second = protocol.validateWithdrawal(payable(DEPLOYER), abi.encode(finalPrice), EMPTY_PREVIOUS_DATA);
        bool third = protocol.validateWithdrawal(payable(DEPLOYER), abi.encode(finalPrice), EMPTY_PREVIOUS_DATA);
        vm.stopPrank();

        assertFalse(first, "first incomplete");
        assertFalse(second, "second incomplete");
        assertTrue(third, "third one-tick recovery completes withdrawal");
        assertEq(protocol.getTotalLongPositions(), 0, "all three ticks eventually processed");
        assertEq(
            uint256(protocol.getUserPendingAction(DEPLOYER).action),
            uint256(ProtocolAction.None),
            "withdrawal cleared"
        );
        assertGt(wstETH.balanceOf(DEPLOYER), assetBefore, "victim finally receives underlying");
    }
}
