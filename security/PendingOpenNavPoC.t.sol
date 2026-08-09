// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

// This file is copied by CI into test/integration/UsdnProtocol/ of the exact deployed USDN snapshot.
import { UsdnProtocolBaseFixture } from "../../unit/UsdnProtocol/utils/Fixtures.sol";
import { IUsdnProtocolTypes } from "../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Proves that an unvalidated leveraged long temporarily changes USDN NAV when price moves,
/// and that validateOpenPosition later cancels that temporary PnL.
contract PendingOpenNavPoC is UsdnProtocolBaseFixture {
    address internal constant ATTACKER = address(0xBEEF);

    function setUp() public {
        params = DEFAULT_PARAMS;
        // Keep the primitive isolated: funding/fees/rebase/limits are disabled by DEFAULT_PARAMS.
        params.initialLong = 5 ether;
        _setUp(params);
    }

    function test_pendingOpenProfitTemporarilyDepressesUsdnNavAndValidationRestoresIt() public {
        uint128 p0 = params.initialPrice; // $2,000
        uint128 p1 = uint128(uint256(p0) * 105 / 100); // +5%

        uint256 navBefore = protocol.usdnPrice(p0);
        uint256 vaultBefore = protocol.getBalanceVault();

        // Stop after INITIATE. USDN has already put the unvalidated position into global totalExpo
        // and into the long/vault accounting at a temporary entry price of p0.
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

        // At the original price, inserting the pending long should not manufacture PnL.
        uint256 navAfterInitiateAtP0 = protocol.usdnPrice(p0);

        // A normal permissionless state update at a higher price credits PnL to that temporary long.
        // This moves value from the USDN vault side to the long side while the position is still unvalidated.
        protocol.mockLiquidate(abi.encode(p1));
        uint256 navDuringPending = protocol.usdnPrice(p1);
        uint256 vaultDuringPending = protocol.getBalanceVault();

        // Validate using the same p1. The production code explicitly cancels the PnL that the
        // temporary pre-validation position accrued and adjusts vault/long balances accordingly.
        vm.prank(ATTACKER);
        (IUsdnProtocolTypes.LongActionOutcome outcome,) =
            protocol.validateOpenPosition(payable(ATTACKER), abi.encode(p1), EMPTY_PREVIOUS_DATA);
        assertEq(uint256(outcome), uint256(IUsdnProtocolTypes.LongActionOutcome.Processed), "open validation outcome");

        uint256 navAfterValidation = protocol.usdnPrice(p1);
        uint256 vaultAfterValidation = protocol.getBalanceVault();

        emit log_named_uint("NAV_BEFORE_AT_P0", navBefore);
        emit log_named_uint("NAV_AFTER_INITIATE_AT_P0", navAfterInitiateAtP0);
        emit log_named_uint("NAV_DURING_PENDING_AT_P1", navDuringPending);
        emit log_named_uint("NAV_AFTER_VALIDATION_AT_SAME_P1", navAfterValidation);
        emit log_named_uint("VAULT_BEFORE", vaultBefore);
        emit log_named_uint("VAULT_DURING_PENDING_AT_P1", vaultDuringPending);
        emit log_named_uint("VAULT_AFTER_VALIDATION_AT_SAME_P1", vaultAfterValidation);
        emit log_named_uint("REVERSIBLE_NAV_RECOVERY_BPS_OF_PENDING_NAV", (navAfterValidation - navDuringPending) * 10_000 / navDuringPending);
        emit log_named_uint("REVERSIBLE_VAULT_RECOVERY", vaultAfterValidation - vaultDuringPending);

        assertApproxEqRel(navAfterInitiateAtP0, navBefore, 0.0001 ether, "initiate itself should not distort NAV at p0");
        assertGt(navAfterValidation, navDuringPending, "same-price validation must reverse temporary NAV depression");
        assertGt(vaultAfterValidation, vaultDuringPending, "same-price validation must return temporary value to vault");
    }
}
