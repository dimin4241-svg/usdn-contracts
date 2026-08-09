// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IUsdnProtocol } from "../../src/interfaces/UsdnProtocol/IUsdnProtocol.sol";
import { IUsdnProtocolTypes } from "../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

interface IAggregatorLike {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IComptrollerLike {
    function calcGav() external returns (uint256);
    function calcGrossShareValue() external returns (uint256);
}

contract SusdnTransientNavTest is Test, IUsdnProtocolTypes {
    address constant PROTOCOL_ADDR = 0x656cB8C6d154Aad29d8771384089be5B5141f01a;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant USDN_AGG = 0xd5004C5D3017862839e83981b110f27EE7B36EAa;
    address constant SUSDN_ACCESSOR = 0x4d54Abd78590bf94c8406d019aFF724DAb659A84;

    IUsdnProtocol protocol = IUsdnProtocol(PROTOCOL_ADDR);
    IAggregatorLike agg = IAggregatorLike(USDN_AGG);
    IComptrollerLike comptroller = IComptrollerLike(SUSDN_ACCESSOR);

    address attacker = address(0xA11CE);

    function setUp() external {
        vm.createSelectFork(vm.envString("RPC_URL"));
        vm.deal(attacker, 100 ether);
    }

    function _emptyPrevious() internal pure returns (PreviousActionsData memory d) {
        d.priceData = new bytes[](0);
        d.rawIndices = new uint128[](0);
    }

    function _snapshot(string memory prefix) internal {
        (, int256 feedAnswer,,, ) = agg.latestRoundData();
        uint128 lastPrice = protocol.getLastPrice();

        emit log_string(prefix);
        emit log_named_int("feedAnswer", feedAnswer);
        emit log_named_uint("sUSDN_GAV", comptroller.calcGav());
        emit log_named_uint("sUSDN_GSV", comptroller.calcGrossShareValue());
        emit log_named_uint("lastPrice", lastPrice);
        emit log_named_uint("USDN_price_at_lastPrice", protocol.usdnPrice(lastPrice));
        emit log_named_uint("balanceVault", protocol.getBalanceVault());
        emit log_named_uint("balanceLong", protocol.getBalanceLong());
        emit log_named_uint("totalExpo", protocol.getTotalExpo());
    }

    function test_pendingOpenChangesOnlyEconomicallyBackedNav() external {
        uint128 amount = uint128(protocol.getMinLongPosition());
        uint128 lastPrice = protocol.getLastPrice();
        uint64 securityDeposit = protocol.getSecurityDepositValue();
        uint256 maxLeverage = protocol.getMaxLeverage();

        emit log_named_uint("minLongPosition", amount);
        emit log_named_uint("securityDeposit", securityDeposit);
        emit log_named_uint("maxLeverage", maxLeverage);

        _snapshot("BEFORE");

        // Funding setup only. We do not mutate protocol or sUSDN storage directly.
        deal(WSTETH, attacker, uint256(amount) * 2);
        assertGe(IERC20(WSTETH).balanceOf(attacker), amount, "wstETH setup failed");

        vm.startPrank(attacker);
        IERC20(WSTETH).approve(PROTOCOL_ADDR, type(uint256).max);
        (bool initiated, PositionId memory posId) = protocol.initiateOpenPosition{ value: securityDeposit }(
            amount,
            lastPrice / 2,
            type(uint128).max,
            maxLeverage,
            attacker,
            payable(attacker),
            type(uint256).max,
            "",
            _emptyPrevious()
        );
        vm.stopPrank();

        emit log_named_uint("initiated", initiated ? 1 : 0);
        emit log_named_int("posTick", posId.tick);
        emit log_named_uint("posVersion", posId.tickVersion);
        emit log_named_uint("posIndex", posId.index);
        assertTrue(initiated, "open was not initiated");

        _snapshot("AFTER_PENDING_OPEN");
    }
}
