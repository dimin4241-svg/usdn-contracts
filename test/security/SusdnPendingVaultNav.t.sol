// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUsdn } from "../../src/interfaces/Usdn/IUsdn.sol";
import { IUsdnProtocol } from "../../src/interfaces/UsdnProtocol/IUsdnProtocol.sol";
import { IUsdnProtocolTypes } from "../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

interface IAggregatorLikePendingNav {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IComptrollerLikePendingNav {
    function calcGav() external returns (uint256);
    function calcGrossShareValue() external returns (uint256);
}

contract SusdnPendingVaultNavTest is Test, IUsdnProtocolTypes {
    address constant PROTOCOL_ADDR = 0x656cB8C6d154Aad29d8771384089be5B5141f01a;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant USDN = 0xde17a000BA631c5d7c2Bd9FB692EFeA52D90DEE2;
    address constant USDNR = 0x82957d600963Ae0C529c3819Ac7C349c4D49269B;
    address constant USDN_AGG = 0xd5004C5D3017862839e83981b110f27EE7B36EAa;
    address constant SUSDN_ACCESSOR = 0x4d54Abd78590bf94c8406d019aFF724DAb659A84;

    IUsdnProtocol protocol = IUsdnProtocol(PROTOCOL_ADDR);
    IUsdn usdn = IUsdn(USDN);
    IAggregatorLikePendingNav agg = IAggregatorLikePendingNav(USDN_AGG);
    IComptrollerLikePendingNav comptroller = IComptrollerLikePendingNav(SUSDN_ACCESSOR);

    address attacker = address(0xA11CE);

    struct NavSnapshot {
        int256 feedAnswer;
        uint256 gav;
        uint256 gsv;
        uint128 lastPrice;
        uint256 usdnPrice;
        uint256 balanceVault;
        int256 pendingBalanceVault;
        uint256 totalSupply;
    }

    function setUp() external {
        vm.createSelectFork(vm.envString("RPC_URL"));
        vm.deal(attacker, 100 ether);
    }

    function _emptyPrevious() internal pure returns (PreviousActionsData memory d) {
        d.priceData = new bytes[](0);
        d.rawIndices = new uint128[](0);
    }

    function _snapshot(string memory prefix) internal returns (NavSnapshot memory s) {
        (, s.feedAnswer,,, ) = agg.latestRoundData();
        s.gav = comptroller.calcGav();
        s.gsv = comptroller.calcGrossShareValue();
        s.lastPrice = protocol.getLastPrice();
        s.usdnPrice = protocol.usdnPrice(s.lastPrice);
        s.balanceVault = protocol.getBalanceVault();
        s.pendingBalanceVault = protocol.getPendingBalanceVault();
        s.totalSupply = usdn.totalSupply();

        emit log_string(prefix);
        emit log_named_int("feedAnswer", s.feedAnswer);
        emit log_named_uint("sUSDN_GAV", s.gav);
        emit log_named_uint("sUSDN_GSV", s.gsv);
        emit log_named_uint("lastPrice", s.lastPrice);
        emit log_named_uint("USDN_price_at_lastPrice", s.usdnPrice);
        emit log_named_uint("balanceVault", s.balanceVault);
        emit log_named_int("pendingBalanceVault", s.pendingBalanceVault);
        emit log_named_uint("USDN_totalSupply", s.totalSupply);
    }

    function test_pendingDepositDoesNotCreateFreeSusdnNav() external {
        uint128 amount = uint128(protocol.getMinLongPosition());
        uint64 securityDeposit = protocol.getSecurityDepositValue();
        address sdex = address(protocol.getSdex());

        deal(WSTETH, attacker, uint256(amount) * 2);
        // Funding only. The real protocol still computes and pulls the exact SDEX amount.
        deal(sdex, attacker, 1_000_000 ether);

        NavSnapshot memory before_ = _snapshot("DEPOSIT_BEFORE");

        vm.startPrank(attacker);
        IERC20(WSTETH).approve(PROTOCOL_ADDR, type(uint256).max);
        IERC20(sdex).approve(PROTOCOL_ADDR, type(uint256).max);
        bool initiated = protocol.initiateDeposit{ value: securityDeposit }(
            amount,
            0,
            attacker,
            payable(attacker),
            type(uint256).max,
            "",
            _emptyPrevious()
        );
        vm.stopPrank();

        assertTrue(initiated, "deposit was not initiated");
        NavSnapshot memory pending_ = _snapshot("DEPOSIT_PENDING");
        emit log_named_int("deposit_GAV_delta", int256(pending_.gav) - int256(before_.gav));
        emit log_named_int("deposit_GSV_delta", int256(pending_.gsv) - int256(before_.gsv));
        emit log_named_int("deposit_feed_delta", pending_.feedAnswer - before_.feedAnswer);
        assertEq(pending_.pendingBalanceVault, int256(uint256(amount)), "pending deposit accounting mismatch");
    }

    function test_pendingWithdrawalDoesNotCreateFreeSusdnNav() external {
        uint64 securityDeposit = protocol.getSecurityDepositValue();
        uint256 tokensToWithdraw = 100 ether;

        // Fork-only funding from a contract that holds a large real USDN balance. No USDN storage is modified.
        vm.prank(USDNR);
        bool funded = usdn.transfer(attacker, tokensToWithdraw);
        assertTrue(funded, "USDN funding transfer failed");

        uint256 attackerShares = usdn.sharesOf(attacker);
        assertGt(attackerShares, 0, "no USDN shares received");
        assertLe(attackerShares, type(uint152).max, "withdrawal shares do not fit uint152");

        NavSnapshot memory before_ = _snapshot("WITHDRAW_BEFORE");

        vm.startPrank(attacker);
        usdn.approve(PROTOCOL_ADDR, type(uint256).max);
        bool initiated = protocol.initiateWithdrawal{ value: securityDeposit }(
            uint152(attackerShares),
            0,
            attacker,
            payable(attacker),
            type(uint256).max,
            "",
            _emptyPrevious()
        );
        vm.stopPrank();

        assertTrue(initiated, "withdrawal was not initiated");
        NavSnapshot memory pending_ = _snapshot("WITHDRAW_PENDING");
        emit log_named_int("withdraw_GAV_delta", int256(pending_.gav) - int256(before_.gav));
        emit log_named_int("withdraw_GSV_delta", int256(pending_.gsv) - int256(before_.gsv));
        emit log_named_int("withdraw_feed_delta", pending_.feedAnswer - before_.feedAnswer);
        assertLt(pending_.pendingBalanceVault, 0, "pending withdrawal accounting was not registered");
    }
}
