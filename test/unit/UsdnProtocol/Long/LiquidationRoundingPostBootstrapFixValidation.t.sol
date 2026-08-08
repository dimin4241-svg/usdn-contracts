// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { DEPLOYER } from "../../../utils/Constants.sol";
import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

abstract contract PostBootstrapFixFixture is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);
    address internal constant KEEPER = address(0xA11CE);

    PositionId internal supportPos;
    PositionId internal posA;
    PositionId internal posB;
    uint128 internal finalPrice;

    function _setUpPostBootstrapWitness() internal {
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
        vm.deal(KEEPER, 10 ether);
        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "production user-action iteration");
        assertEq(protocol.getProtocolFeeBps(), 800, "production protocol fee");
        assertEq(protocol.getFundingSF(), 120, "production funding SF");
        assertEq(protocol.getMinLongPosition(), 2 ether, "production min long");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer installed");
        assertTrue(managers.setExternalManager != managers.setProtocolParamsManager, "roles must be separated");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap positions must be gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap totalExpo must be gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap balanceLong must be gone");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "price reset must keep empty long side");
        assertEq(protocol.getTotalExpo(), 0, "price reset must keep zero exposure");
        assertEq(protocol.getBalanceLong(), 0, "price reset must keep zero long balance");

        supportPos = setUpUserPositionInLong(
            OpenParams(SUPPORT_USER, ProtocolAction.ValidateOpenPosition, 20 ether, 1783 ether, ENTRY_PRICE)
        );
        posA = setUpUserPositionInLong(
            OpenParams(USER_A, ProtocolAction.ValidateOpenPosition, 2 ether, 1724 ether, ENTRY_PRICE)
        );
        posB = setUpUserPositionInLong(
            OpenParams(USER_B, ProtocolAction.ValidateOpenPosition, 2 ether, 1703 ether, ENTRY_PRICE)
        );

        assertEq(supportPos.tick, 74_800, "support tick");
        assertEq(posA.tick, 74_500, "tick A");
        assertEq(posB.tick, 74_400, "tick B");

        _waitDelay();
        _waitDelay();

        uint256 supportBoundary = protocol.getEffectivePriceForTick(supportPos.tick);
        Types.LiqTickInfo[] memory supportTicks = protocol.liquidate(abi.encode(uint128(supportBoundary - 1)));
        assertEq(supportTicks.length, 1, "support stage must liquidate exactly one tick");
        assertEq(protocol.getTotalLongPositions(), 2, "only final ordinary positions must remain");
        assertEq(protocol.getHighestPopulatedTick(), posA.tick, "unexpected final highest tick");

        _waitDelay();
        _waitDelay();

        uint256 finalBoundary = protocol.getEffectivePriceForTick(posB.tick);
        finalPrice = uint128(finalBoundary - 1);
        assertEq(finalPrice, 1_701_942_303_173_288_776_978, "witness final price changed");
    }
}

contract TestLiquidationRoundingPostBootstrapFixAccounting is PostBootstrapFixFixture {
    function setUp() public {
        _setUpPostBootstrapWitness();
    }

    function test_A_sameOrdinaryOnlyWitnessNowLiquidatesSuccessfully() public {
        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(finalPrice));
        assertEq(ticks.length, 2, "same final batch must contain two ordinary ticks");
        assertEq(protocol.getTotalLongPositions(), 0, "all ordinary positions must liquidate");
        assertEq(protocol.getTotalExpo(), 0, "all long exposure must be removed");
        assertEq(protocol.getBalanceLong(), 0, "patched accounting must reconcile final dust");
    }

    function test_B_sameSourceFloorsStillMissExactlyOneWeiButStateIsReconciled() public {
        uint128 liquidationOracleTimestamp = uint128(block.timestamp - 30 seconds);
        Types.ApplyPnlAndFundingData memory pnl = protocol.i_applyPnlAndFunding(finalPrice, liquidationOracleTimestamp);
        assertEq(pnl.tempLongBalance, 365_737_702_725_827_419, "pre-liquidation long balance changed");

        uint256 price = uint256(finalPrice);
        uint256 valueA = 12_675_520_241_288_472_878 * (price - 1_684_916_553_638_498_409_790) / price;
        uint256 valueB = 12_034_709_889_783_951_966 * (price - 1_668_152_187_831_301_125_432) / price;
        assertEq(valueA, 126_802_320_177_930_074, "tick A source floor");
        assertEq(valueB, 238_935_382_547_897_344, "tick B source floor");
        assertEq(uint256(pnl.tempLongBalance) - valueA - valueB, 1, "same source must expose one-wei rounding gap");

        protocol.liquidate(abi.encode(finalPrice));
        assertEq(protocol.getTotalExpo(), 0, "all exposure removed");
        assertEq(protocol.getBalanceLong(), 0, "fix must reconcile the one-wei source gap");
    }

    function test_C_unprivilegedEOANowCompletesDedicatedLiquidation() public {
        vm.startPrank(KEEPER, KEEPER);
        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(finalPrice));
        vm.stopPrank();
        assertEq(ticks.length, 2, "unprivileged public liquidation must process both ticks");
        assertEq(protocol.getTotalLongPositions(), 0, "EOA liquidation must make progress");
        assertEq(protocol.getBalanceLong(), 0, "EOA liquidation must preserve invariant");
    }
}

contract TestLiquidationRoundingPostBootstrapFixImpact is PostBootstrapFixFixture {
    uint152 internal victimShares;

    function setUp() public {
        _setUpPostBootstrapWitness();

        uint256 deployerShares = usdn.sharesOf(DEPLOYER);
        uint256 shares = deployerShares / 100;
        require(shares > 0 && shares <= type(uint152).max, "invalid withdrawal share amount");
        victimShares = uint152(shares);

        uint256 currentBoundary = protocol.getEffectivePriceForTick(posA.tick);
        vm.startPrank(DEPLOYER);
        usdn.approve(address(protocol), type(uint256).max);
        bool initiated = protocol.initiateWithdrawal{ value: protocol.getSecurityDepositValue() }(
            victimShares,
            0,
            DEPLOYER,
            payable(DEPLOYER),
            type(uint256).max,
            abi.encode(uint128(currentBoundary + 1)),
            EMPTY_PREVIOUS_DATA
        );
        vm.stopPrank();
        assertTrue(initiated, "withdrawal must be initiated");

        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(uint256(pending.action), uint256(ProtocolAction.ValidateWithdrawal), "withdrawal must be pending");
        assertGe(usdn.sharesOf(address(protocol)), victimShares, "victim shares must be escrowed");

        _waitDelay();
        uint256 finalBoundary = protocol.getEffectivePriceForTick(posB.tick);
        finalPrice = uint128(finalBoundary - 1);
    }

    function test_A_fixedDedicatedLiquidationAndFirstValidationBothSucceed() public {
        uint256 assetBefore = wstETH.balanceOf(DEPLOYER);
        uint256 escrowBefore = usdn.sharesOf(address(protocol));

        vm.startPrank(KEEPER, KEEPER);
        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(finalPrice));
        assertEq(ticks.length, 2, "fixed dedicated liquidation must process both final ticks");
        assertEq(protocol.getTotalLongPositions(), 0, "fixed liquidation must clear final positions");
        assertEq(protocol.getBalanceLong(), 0, "fixed liquidation must leave zero long balance");
        assertEq(usdn.sharesOf(address(protocol)), escrowBefore, "pending withdrawal escrow must remain intact");

        bool validated = protocol.validateWithdrawal(payable(DEPLOYER), abi.encode(finalPrice), EMPTY_PREVIOUS_DATA);
        vm.stopPrank();

        assertTrue(validated, "first validation after fixed liquidation must complete withdrawal");
        PendingAction memory pending = protocol.getUserPendingAction(DEPLOYER);
        assertEq(uint256(pending.action), uint256(ProtocolAction.None), "withdrawal must be cleared");
        assertGt(wstETH.balanceOf(DEPLOYER), assetBefore, "victim must receive underlying");
    }
}
