// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { DEPLOYER } from "../../../utils/Constants.sol";
import { IUsdnProtocolErrors } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolErrors.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";
import { TestLiquidationRoundingPostBootstrapRegression } from "./LiquidationRoundingPostBootstrapRegression.t.sol";

/// @notice High-impact probe built on the exact post-bootstrap two-tick 1-wei witness.
/// A normal user first creates a real pending withdrawal at a non-liquidating price.
/// Validation is then attempted at a price where both remaining ticks are liquidatable.
/// Because production liquidationIteration == 1, the first validation may commit only
/// the first tick and return false. The second validation reaches the final tick and,
/// if the rounding residue survives sequential processing, must hit the production
/// Rebalancer invariant and roll back while leaving the user's withdrawal pending.
contract TestLiquidationRoundingSequentialWithdrawalHighProbe is TestLiquidationRoundingPostBootstrapRegression {
    address internal constant VICTIM = address(0xA11CE);
    uint256 internal constant WITHDRAW_TOKENS = 100 ether;

    function test_pendingWithdrawalCanBeBlockedOnFinalSequentialLiquidationTick() public {
        assertEq(protocol.getLiquidationIteration(), 1, "production liquidationIteration must be 1");
        assertEq(protocol.getTotalLongPositions(), 2, "exact two-tick witness required");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer must be enabled");

        vm.deal(VICTIM, 10 ether);

        // Fund the victim with ordinary USDN shares already minted by the protocol.
        // No storage manipulation and no synthetic pending action is used.
        uint256 victimShares256 = usdn.convertToShares(WITHDRAW_TOKENS);
        assertGt(victimShares256, 0, "withdrawal shares");
        assertLe(victimShares256, type(uint152).max, "withdrawal shares must fit protocol API");
        uint152 victimShares = uint152(victimShares256);

        vm.prank(DEPLOYER);
        usdn.transferShares(VICTIM, victimShares);
        assertEq(usdn.sharesOf(VICTIM), victimShares, "victim must own real USDN shares");

        vm.prank(VICTIM);
        usdn.approve(address(protocol), type(uint256).max);

        // Initiate above the highest liquidation boundary so no target tick is consumed
        // during initiation. Recompute the later crash price after initiation because the
        // action legitimately applies PnL/funding to protocol state.
        uint128 safeInitiationPrice = uint128(protocol.getEffectivePriceForTick(posA.tick) + 10 ether);
        uint256 victimAssetBefore = wstETH.balanceOf(VICTIM);
        uint256 securityDeposit = protocol.getSecurityDepositValue();

        vm.prank(VICTIM);
        bool initiated = protocol.initiateWithdrawal{ value: securityDeposit }(
            victimShares,
            DISABLE_AMOUNT_OUT_MIN,
            VICTIM,
            payable(VICTIM),
            type(uint256).max,
            abi.encode(safeInitiationPrice),
            EMPTY_PREVIOUS_DATA
        );
        assertTrue(initiated, "withdrawal must be initiated through the public flow");
        assertEq(protocol.getTotalLongPositions(), 2, "initiation must not liquidate target ticks");

        Types.PendingAction memory pending = protocol.getUserPendingAction(VICTIM);
        assertEq(
            uint256(pending.action),
            uint256(Types.ProtocolAction.ValidateWithdrawal),
            "victim must have a real pending withdrawal"
        );
        assertEq(wstETH.balanceOf(VICTIM), victimAssetBefore, "initiation must not pay underlying");

        _waitDelay();

        // Keep both remaining ticks liquidatable even after validateWithdrawal() applies its
        // production funding update internally. The previous boundary-minus-1-wei input was
        // too tight: the internal funding move raised the effective long price enough that
        // tick B stopped being eligible and the withdrawal completed normally.
        uint128 tickBBoundary = uint128(protocol.getEffectivePriceForTick(posB.tick));
        uint128 crashPrice = tickBBoundary - uint128(1 ether);
        assertLt(crashPrice, tickBBoundary, "crash price below final tick");
        assertLt(crashPrice, protocol.getEffectivePriceForTick(posA.tick), "tick A must also be liquidatable");

        uint256 aVersionBefore = protocol.getTickVersion(posA.tick);
        uint256 bVersionBefore = protocol.getTickVersion(posB.tick);

        // First validation: production iteration=1 processes the highest tick only.
        vm.prank(VICTIM);
        bool firstValidated = protocol.validateWithdrawal(payable(VICTIM), abi.encode(crashPrice), EMPTY_PREVIOUS_DATA);
        assertFalse(firstValidated, "first validation must stop on pending liquidation");
        assertEq(protocol.getTotalLongPositions(), 1, "first liquidation tick must commit");
        assertEq(protocol.getTickVersion(posA.tick), aVersionBefore + 1, "tick A must be committed as liquidated");
        assertEq(protocol.getTickVersion(posB.tick), bVersionBefore, "final tick must remain");
        assertEq(wstETH.balanceOf(VICTIM), victimAssetBefore, "victim must still receive no underlying");

        pending = protocol.getUserPendingAction(VICTIM);
        assertEq(
            uint256(pending.action),
            uint256(Types.ProtocolAction.ValidateWithdrawal),
            "pending withdrawal must survive first liquidation pass"
        );

        // Second validation reaches the final tick. If sequential processing preserves the
        // rounding residue, this is the first point where Rebalancer is invoked.
        vm.prank(VICTIM);
        vm.expectRevert(IUsdnProtocolErrors.UsdnProtocolInvalidLongExpo.selector);
        protocol.validateWithdrawal(payable(VICTIM), abi.encode(crashPrice), EMPTY_PREVIOUS_DATA);

        // The final-tick revert must be atomic: the final position and pending withdrawal stay.
        assertEq(protocol.getTotalLongPositions(), 1, "final tick must roll back");
        assertEq(protocol.getTickVersion(posB.tick), bVersionBefore, "final tick version must roll back");
        assertEq(wstETH.balanceOf(VICTIM), victimAssetBefore, "blocked withdrawal must pay no underlying");
        pending = protocol.getUserPendingAction(VICTIM);
        assertEq(
            uint256(pending.action),
            uint256(Types.ProtocolAction.ValidateWithdrawal),
            "blocked withdrawal must remain pending"
        );

        // Fresh retry: advance time and submit fresh price data for the same pending action.
        // The user should not be able to escape merely by retrying validation.
        skip(1);
        vm.prank(VICTIM);
        vm.expectRevert(IUsdnProtocolErrors.UsdnProtocolInvalidLongExpo.selector);
        protocol.validateWithdrawal(payable(VICTIM), abi.encode(crashPrice), EMPTY_PREVIOUS_DATA);

        assertEq(protocol.getTotalLongPositions(), 1, "retry must not clear final position");
        assertEq(protocol.getTickVersion(posB.tick), bVersionBefore, "retry must roll final tick back again");
        assertEq(wstETH.balanceOf(VICTIM), victimAssetBefore, "retry must still pay no underlying");
        pending = protocol.getUserPendingAction(VICTIM);
        assertEq(
            uint256(pending.action),
            uint256(Types.ProtocolAction.ValidateWithdrawal),
            "withdrawal must remain pending after fresh retry"
        );
    }
}
