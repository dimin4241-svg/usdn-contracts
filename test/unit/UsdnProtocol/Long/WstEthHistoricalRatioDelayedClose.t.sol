// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { MockPyth } from "../../Middlewares/utils/MockPyth.sol";
import { MockChainlinkOnChain } from "../../Middlewares/utils/MockChainlinkOnChain.sol";
import { MockStreamVerifierProxy } from "../../Middlewares/utils/MockStreamVerifierProxy.sol";
import { WstEthOracleMiddlewareWithDataStreams } from
    "../../../../src/OracleMiddleware/WstEthOracleMiddlewareWithDataStreams.sol";
import { IVerifierProxy } from "../../../../src/interfaces/OracleMiddleware/IVerifierProxy.sol";
import { PriceInfo } from "../../../../src/interfaces/OracleMiddleware/IOracleMiddlewareTypes.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";
import { UsdnProtocolUtilsLibrary as Utils } from "../../../../src/UsdnProtocol/libraries/UsdnProtocolUtilsLibrary.sol";
import { DEPLOYER } from "../../../utils/Constants.sol";

contract TestWstEthHistoricalRatioDelayedClose is UsdnProtocolBaseFixture {
    uint128 internal constant WSTETH_PRICE = 2300 ether;
    int256 internal constant ETH_PRICE_8 = 2000e8;
    uint256 internal constant BASE_RATIO = 1.15 ether;
    uint256 internal constant DRIFTED_RATIO = 1.20 ether;
    bytes32 internal constant STREAM_ID = 0x0003000000000000000000000000000000000000000000000000000000000000;

    MockPyth internal pyth;
    MockChainlinkOnChain internal chainlink;
    MockStreamVerifierProxy internal verifier;
    WstEthOracleMiddlewareWithDataStreams internal dataStreamsMiddleware;

    function setUp() public {
        SetUpParams memory p = DEFAULT_PARAMS;
        p.initialPrice = WSTETH_PRICE;
        p.initialLong = 100 ether;
        _setUp(p);

        assertEq(wstETH.stEthPerToken(), BASE_RATIO, "unexpected base ratio");

        pyth = new MockPyth();
        chainlink = new MockChainlinkOnChain();
        // A zero fee-manager is enough for the test: the verifier still returns the encoded report,
        // while validationCost is zero. This isolates the timestamp/ratio behavior from fee plumbing.
        verifier = new MockStreamVerifierProxy(address(0));
        dataStreamsMiddleware = new WstEthOracleMiddlewareWithDataStreams(
            address(pyth),
            bytes32(0),
            address(chainlink),
            address(wstETH),
            1 hours,
            address(verifier),
            STREAM_ID
        );

        vm.prank(managers.setExternalManager);
        protocol.setOracleMiddleware(dataStreamsMiddleware);
    }

    function test_A_lateHistoricalRoundUsesCurrentRatio() public {
        uint40 actionTimestamp = uint40(block.timestamp);
        uint128 targetLimit = uint128(uint256(actionTimestamp) + dataStreamsMiddleware.getLowLatencyDelay());
        uint80 roundId = 42;
        _setHistoricalEthRound(roundId, targetLimit);

        vm.warp(uint256(targetLimit) + 2);

        PriceInfo memory beforeDrift = dataStreamsMiddleware.parseAndValidatePrice(
            bytes32(0), actionTimestamp, Types.ProtocolAction.ValidateClosePosition, abi.encode(roundId)
        );
        assertEq(beforeDrift.price, WSTETH_PRICE, "historical ETH x base ratio should equal historical wstETH price");
        assertEq(beforeDrift.timestamp, uint256(targetLimit) + 1, "historical ETH timestamp");

        wstETH.setStEthPerToken(DRIFTED_RATIO);

        PriceInfo memory afterDrift = dataStreamsMiddleware.parseAndValidatePrice(
            bytes32(0), actionTimestamp, Types.ProtocolAction.ValidateClosePosition, abi.encode(roundId)
        );

        assertEq(afterDrift.timestamp, beforeDrift.timestamp, "the ETH/USD round timestamp must stay historical");
        assertEq(afterDrift.price, 2400 ether, "same historical ETH round is repriced with current ratio");
        assertGt(afterDrift.price, beforeDrift.price, "ratio drift must change a fixed historical oracle round");
    }

    function test_B_controlNoRatioDriftDoesNotChargeVault() public {
        (Types.LongPendingAction memory close, uint80 roundId) = _initiateFullCloseAndPrepareHistoricalRound();

        uint256 vaultBeforeValidate = protocol.getBalanceVault();
        uint256 userBeforeValidate = wstETH.balanceOf(DEPLOYER);

        vm.prank(DEPLOYER);
        protocol.validateClosePosition(payable(DEPLOYER), abi.encode(roundId), EMPTY_PREVIOUS_DATA);

        uint256 payout = wstETH.balanceOf(DEPLOYER) - userBeforeValidate;
        uint256 vaultAfterValidate = protocol.getBalanceVault();

        assertEq(payout, close.closeBoundedPositionValue, "no ratio drift: payout should equal the bounded close value");
        assertEq(vaultAfterValidate, vaultBeforeValidate, "no ratio drift: validation should not subsidize the close");
    }

    function test_C_ratioDriftAfterPositionRemovalExtractsDifferenceFromVault() public {
        (Types.LongPendingAction memory close, uint80 roundId) = _initiateFullCloseAndPrepareHistoricalRound();

        // The long has already been fully removed at initiation. From this point onward it has no live exposure.
        assertEq(protocol.getTotalLongPositions(), 0, "position must already be removed before the waiting period");
        assertEq(protocol.getTotalExpo(), 0, "exposure must already be removed before the waiting period");

        uint256 vaultBeforeValidate = protocol.getBalanceVault();
        uint256 userBeforeValidate = wstETH.balanceOf(DEPLOYER);

        // Model only the real wstETH/stETH exchange-rate increase while the close remains pending.
        // The ETH/USD Chainlink round used below remains the same historical round.
        wstETH.setStEthPerToken(DRIFTED_RATIO);

        PriceInfo memory latePrice = dataStreamsMiddleware.parseAndValidatePrice(
            bytes32(0), close.timestamp, Types.ProtocolAction.ValidateClosePosition, abi.encode(roundId)
        );
        assertEq(latePrice.price, 2400 ether, "late validation must expose the current-ratio repricing");

        vm.prank(DEPLOYER);
        protocol.validateClosePosition(payable(DEPLOYER), abi.encode(roundId), EMPTY_PREVIOUS_DATA);

        uint256 payout = wstETH.balanceOf(DEPLOYER) - userBeforeValidate;
        uint256 vaultAfterValidate = protocol.getBalanceVault();
        uint256 vaultSubsidy = vaultBeforeValidate - vaultAfterValidate;

        assertGt(payout, close.closeBoundedPositionValue, "removed position receives extra value from ratio drift");
        assertGt(vaultSubsidy, 0, "extra payout must be funded by the vault");
        assertEq(
            vaultSubsidy,
            payout - uint256(close.closeBoundedPositionValue),
            "vault loss must exactly fund the delayed-close uplift"
        );
    }

    function _initiateFullCloseAndPrepareHistoricalRound()
        internal
        returns (Types.LongPendingAction memory close_, uint80 roundId_)
    {
        bytes memory payload = _directWstEthReport(WSTETH_PRICE, uint32(block.timestamp));

        vm.prank(DEPLOYER);
        protocol.initiateClosePosition(
            initialPosition,
            params.initialLong,
            DISABLE_MIN_PRICE,
            DEPLOYER,
            payable(DEPLOYER),
            type(uint256).max,
            payload,
            EMPTY_PREVIOUS_DATA,
            ""
        );

        Types.PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        close_ = Utils._toLongPendingAction(pending);
        assertEq(uint256(close_.action), uint256(Types.ProtocolAction.ValidateClosePosition), "pending close action");
        assertEq(protocol.getTotalLongPositions(), 0, "full close is removed at initiate");
        assertEq(protocol.getTotalExpo(), 0, "full close exposure is removed at initiate");

        uint128 targetLimit = uint128(uint256(close_.timestamp) + dataStreamsMiddleware.getLowLatencyDelay());
        roundId_ = 42;
        _setHistoricalEthRound(roundId_, targetLimit);
        vm.warp(uint256(targetLimit) + 2);
    }

    function _setHistoricalEthRound(uint80 roundId, uint128 targetLimit) internal {
        chainlink.setRoundData(roundId - 1, ETH_PRICE_8, targetLimit, targetLimit, roundId - 1);
        chainlink.setRoundData(roundId, ETH_PRICE_8, uint256(targetLimit) + 1, uint256(targetLimit) + 1, roundId);
    }

    function _directWstEthReport(uint128 directWstEthPrice, uint32 timestamp)
        internal
        pure
        returns (bytes memory payload_)
    {
        IVerifierProxy.ReportV3 memory report = IVerifierProxy.ReportV3({
            feedId: STREAM_ID,
            validFromTimestamp: timestamp,
            observationsTimestamp: timestamp,
            nativeFee: 0,
            linkFee: 0,
            expiresAt: timestamp + 100,
            price: int192(uint192(directWstEthPrice)),
            bid: int192(uint192(directWstEthPrice - 1)),
            ask: int192(uint192(directWstEthPrice + 1))
        });
        bytes32[3] memory emptySignature;
        payload_ = abi.encode(emptySignature, abi.encode(report));
    }
}
