// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { DEPLOYER } from "../../../utils/Constants.sol";
import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancer } from "../../../../src/interfaces/Rebalancer/IRebalancer.sol";

/// @notice Stronger reachability control for the multi-tick liquidation rounding
/// issue: the bootstrap position is first closed through the normal user action
/// path, then the vulnerable final ticks are created only by ordinary opens.
contract TestLiquidationRoundingOrdinaryPositions is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant CRASH_PRICE = 990 ether;

    address internal constant LARGE_USER = address(0xCAFE);
    address internal constant SMALL_USER = address(0xBEEF);

    PositionId internal largePos;
    PositionId internal smallPos;

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

        vm.deal(DEPLOYER, 10 ether);
        vm.deal(LARGE_USER, 10 ether);
        vm.deal(SMALL_USER, 10 ether);

        super._setUp(params);

        // Remove the special initialize()-created long using exactly the same
        // initiate/validate close path available to its owner.
        (Position memory bootstrap,) = protocol.getLongPosition(initialPosition);
        assertEq(bootstrap.user, DEPLOYER, "bootstrap owner");
        assertEq(bootstrap.amount, 200 ether, "bootstrap amount");

        // Cache before vm.prank: a one-shot prank would otherwise be consumed
        // by the external getter used to evaluate the call value.
        uint256 securityDeposit = protocol.getSecurityDepositValue();
        vm.prank(DEPLOYER);
        protocol.initiateClosePosition{ value: securityDeposit }(
            initialPosition,
            bootstrap.amount,
            DISABLE_MIN_PRICE,
            DEPLOYER,
            payable(DEPLOYER),
            type(uint256).max,
            abi.encode(ENTRY_PRICE),
            EMPTY_PREVIOUS_DATA,
            ""
        );
        _waitDelay();
        vm.prank(DEPLOYER);
        protocol.validateClosePosition(payable(DEPLOYER), abi.encode(ENTRY_PRICE), EMPTY_PREVIOUS_DATA);
        _waitDelay();

        assertEq(protocol.getTotalExpo(), 0, "bootstrap exposure must be gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap long balance must be gone");

        // Re-create approximately the same balanced economic state exclusively
        // with ordinary user positions. Desired liquidation prices are adjacent
        // so the two populated ticks are liquidated together near $990.
        largePos = setUpUserPositionInLong(
            OpenParams({
                user: LARGE_USER,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 200 ether,
                desiredLiqPrice: 1010 ether,
                price: ENTRY_PRICE
            })
        );

        smallPos = setUpUserPositionInLong(
            OpenParams({
                user: SMALL_USER,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: 2 ether,
                desiredLiqPrice: 1000 ether,
                price: ENTRY_PRICE
            })
        );

        assertNotEq(largePos.tick, smallPos.tick, "ordinary positions need distinct ticks");
        assertEq(protocol.getTotalExpo() > 0, true, "ordinary exposure must exist");

        // Escrow a real withdrawal before the crash. Closing the bootstrap long
        // does not burn the initial depositor's USDN balance.
        uint256 shares = usdn.sharesOf(DEPLOYER) / 20;
        require(shares > 0 && shares <= type(uint152).max, "invalid shares");

        vm.startPrank(DEPLOYER);
        usdn.approve(address(protocol), type(uint256).max);
        bool initiated = protocol.initiateWithdrawal{ value: protocol.getSecurityDepositValue() }(
            uint152(shares),
            0,
            DEPLOYER,
            payable(DEPLOYER),
            type(uint256).max,
            abi.encode(ENTRY_PRICE),
            EMPTY_PREVIOUS_DATA
        );
        vm.stopPrank();
        assertTrue(initiated, "withdrawal initiation");
        _waitDelay();
    }

    function test_A_onlyOrdinaryPositionsRemain() public view {
        assertNotEq(largePos.tick, initialPosition.tick, "large normal open should not reuse bootstrap construction");
        assertNotEq(smallPos.tick, initialPosition.tick, "small normal open should not reuse bootstrap construction");
        assertNotEq(largePos.tick, smallPos.tick, "two ordinary ticks");
    }

    function test_B_ordinaryOnlyDedicatedLiquidationReverts() public {
        vm.expectRevert(UsdnProtocolInvalidLongExpo.selector);
        protocol.liquidate(abi.encode(CRASH_PRICE));
    }

    function test_C_ordinaryOnlySourceStateBreaksInvariantWithoutSink() public {
        vm.prank(managers.setExternalManager);
        protocol.setRebalancer(IRebalancer(address(0)));

        protocol.liquidate(abi.encode(CRASH_PRICE));

        assertEq(protocol.getTotalExpo(), 0, "all ordinary exposure removed");
        assertGt(protocol.getBalanceLong(), 0, "positive residue remains");
        assertGt(protocol.getBalanceLong(), protocol.getTotalExpo(), "accounting invariant broken");
    }
}
