// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IRebalancerTypes } from "../../../../src/interfaces/Rebalancer/IRebalancerTypes.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Exercises the exact whole-dollar rounding witness with a real Rebalancer deposit
/// validated through its public lifecycle before the final liquidation.
contract TestLiquidationRoundingActiveRebalancerFixValidation is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;

    uint128 internal constant SUPPORT_AMOUNT = 20 ether;
    uint128 internal constant USER_AMOUNT = 2 ether;
    uint128 internal constant SUPPORT_DESIRED_LIQ = 1652 ether;
    uint128 internal constant A_DESIRED_LIQ = 1619 ether;
    uint128 internal constant B_DESIRED_LIQ = 1587 ether;

    uint128 internal constant STAGE_PRICE = 1651 ether;
    uint128 internal constant FINAL_PRICE = 1586 ether;

    int24 internal constant EXPECTED_SUPPORT_TICK = 74_100;
    int24 internal constant EXPECTED_A_TICK = 73_800;
    int24 internal constant EXPECTED_B_TICK = 73_700;

    uint256 internal constant EXPECTED_FINAL_BOUNDARY = 1_586_817_316_249_371_051_367;
    uint256 internal constant EXPECTED_A_REMAINING = 88_436_831_455_148_774;
    uint256 internal constant EXPECTED_B_REMAINING = 173_875_956_498_254_704;

    address internal constant SUPPORT_USER = address(0xCAFE);
    address internal constant USER_A = address(0xBEEF);
    address internal constant USER_B = address(0xD00D);
    address internal constant REBALANCER_DEPOSITOR = address(0xF00D);
    address internal constant PUBLIC_LIQUIDATOR = address(0xA11CE);

    uint88 internal constant REBALANCER_PENDING_ASSETS = 2 ether;

    PositionId internal supportPos;
    PositionId internal posA;
    PositionId internal posB;

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
        params.flags.enableRoles = true;

        vm.deal(SUPPORT_USER, 10 ether);
        vm.deal(USER_A, 10 ether);
        vm.deal(USER_B, 10 ether);
        vm.deal(REBALANCER_DEPOSITOR, 10 ether);
        vm.deal(PUBLIC_LIQUIDATOR, 10 ether);
        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "production action liquidation iteration");
        assertEq(protocol.getProtocolFeeBps(), 800, "production protocol fee");
        assertEq(protocol.getFundingSF(), 120, "production funding SF");
        assertEq(protocol.getMinLongPosition(), 2 ether, "production minimum long");
        assertGt(protocol.getCloseExpoImbalanceLimitBps(), 0, "production close imbalance limit");
        assertGt(protocol.getRebalancerBonusBps(), 0, "production Rebalancer bonus enabled");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer installed");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap positions gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap exposure gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap long balance gone");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "price reset keeps no positions");
        assertEq(protocol.getTotalExpo(), 0, "price reset keeps zero exposure");
        assertEq(protocol.getBalanceLong(), 0, "price reset keeps zero long balance");

        supportPos = setUpUserPositionInLong(
            OpenParams(SUPPORT_USER, ProtocolAction.ValidateOpenPosition, SUPPORT_AMOUNT, SUPPORT_DESIRED_LIQ, ENTRY_PRICE)
        );
        posA = setUpUserPositionInLong(
            OpenParams(USER_A, ProtocolAction.ValidateOpenPosition, USER_AMOUNT, A_DESIRED_LIQ, ENTRY_PRICE)
        );
        posB = setUpUserPositionInLong(
            OpenParams(USER_B, ProtocolAction.ValidateOpenPosition, USER_AMOUNT, B_DESIRED_LIQ, ENTRY_PRICE)
        );

        assertEq(supportPos.tick, EXPECTED_SUPPORT_TICK, "support tick");
        assertEq(posA.tick, EXPECTED_A_TICK, "tick A");
        assertEq(posB.tick, EXPECTED_B_TICK, "tick B");

        _waitDelay();
        _waitDelay();
        Types.LiqTickInfo[] memory staged = protocol.liquidate(abi.encode(STAGE_PRICE));
        assertEq(staged.length, 1, "stage must consume only support tick");
        assertEq(protocol.getTotalLongPositions(), 2, "only A+B remain");

        wstETH.mintAndApprove(
            REBALANCER_DEPOSITOR,
            REBALANCER_PENDING_ASSETS,
            address(rebalancer),
            type(uint256).max
        );
        vm.prank(REBALANCER_DEPOSITOR);
        rebalancer.initiateDepositAssets(REBALANCER_PENDING_ASSETS, REBALANCER_DEPOSITOR);

        _waitDelay();
        vm.prank(REBALANCER_DEPOSITOR);
        rebalancer.validateDepositAssets();
        assertEq(rebalancer.getPendingAssetsAmount(), REBALANCER_PENDING_ASSETS, "real pending assets validated");
        assertEq(rebalancer.getPositionVersion(), 0, "no Rebalancer position before final liquidation");

        _waitDelay();
        uint256 finalBoundary = protocol.getEffectivePriceForTick(posB.tick);
        assertEq(finalBoundary, EXPECTED_FINAL_BOUNDARY, "whole-dollar witness timing changed");
        assertGt(finalBoundary, FINAL_PRICE, "B must be liquidatable at final whole-dollar price");
    }

    function _trackedPhysicalAssets() internal view returns (uint256 total_) {
        total_ = wstETH.balanceOf(address(protocol)) + wstETH.balanceOf(address(rebalancer))
            + wstETH.balanceOf(PUBLIC_LIQUIDATOR);
    }

    function _correctedBonusFromTicks(Types.LiqTickInfo[] memory ticks) internal returns (uint256 correctedBonus_) {
        assertEq(ticks.length, 2, "final batch must liquidate A+B");
        assertEq(uint256(ticks[0].remainingCollateral), EXPECTED_A_REMAINING, "tick A floor changed");
        assertEq(uint256(ticks[1].remainingCollateral), EXPECTED_B_REMAINING, "tick B floor changed");

        uint256 legacyFlooredCollateral =
            uint256(ticks[0].remainingCollateral) + uint256(ticks[1].remainingCollateral);
        uint256 bonusBps = protocol.getRebalancerBonusBps();
        uint256 legacyBonus = legacyFlooredCollateral * bonusBps / 10_000;
        correctedBonus_ = (legacyFlooredCollateral + 1) * bonusBps / 10_000;

        assertEq(correctedBonus_, legacyBonus + 1, "reconciliation must be observable in Rebalancer bonus");
    }

    function _assertOpenedRebalancerPosition(uint128 versionAfter, uint256 correctedBonus) internal {
        IRebalancerTypes.PositionData memory rbPosition = rebalancer.getPositionData(versionAfter);
        assertEq(rbPosition.amount, REBALANCER_PENDING_ASSETS, "Rebalancer principal excludes liquidation bonus");
        assertNotEq(rbPosition.tick, type(int24).min, "real Rebalancer position must exist");

        Types.PositionId memory rbPosId = Types.PositionId({
            tick: rbPosition.tick,
            tickVersion: rbPosition.tickVersion,
            index: rbPosition.index
        });
        (Types.Position memory protocolPosition,) = protocol.getLongPosition(rbPosId);
        assertTrue(protocolPosition.validated, "Rebalancer position must be validated atomically");
        assertEq(protocolPosition.user, address(rebalancer), "position owner must be the real Rebalancer");
        assertEq(
            uint256(protocolPosition.amount),
            uint256(REBALANCER_PENDING_ASSETS) + correctedBonus,
            "protocol position must contain pending assets plus corrected bonus"
        );
        assertEq(
            uint256(protocolPosition.amount) - uint256(rbPosition.amount),
            correctedBonus,
            "observable Rebalancer bonus must equal corrected collateral formula"
        );
    }

    function test_activeRebalancerConsumesPendingAssetsAndUsesCorrectedCollateralBonus() public {
        uint256 trackedAssetsBefore = _trackedPhysicalAssets();
        uint256 liquidatorAssetBefore = wstETH.balanceOf(PUBLIC_LIQUIDATOR);
        uint128 versionBefore = rebalancer.getPositionVersion();

        assertEq(
            wstETH.balanceOf(address(rebalancer)),
            REBALANCER_PENDING_ASSETS,
            "pending assets physically held by Rebalancer"
        );

        vm.startPrank(PUBLIC_LIQUIDATOR, PUBLIC_LIQUIDATOR);
        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(FINAL_PRICE));
        vm.stopPrank();

        uint256 correctedBonus = _correctedBonusFromTicks(ticks);
        uint128 versionAfter = rebalancer.getPositionVersion();
        assertEq(versionAfter, versionBefore + 1, "real Rebalancer trigger must open next version");
        assertEq(rebalancer.getPendingAssetsAmount(), 0, "validated pending assets must be consumed");

        _assertOpenedRebalancerPosition(versionAfter, correctedBonus);

        assertEq(protocol.getTotalLongPositions(), 1, "A+B removed and one Rebalancer position opened");
        assertLe(protocol.getBalanceLong(), protocol.getTotalExpo(), "long/exposure safety invariant preserved");
        assertEq(wstETH.balanceOf(address(rebalancer)), 0, "pending assets transferred into protocol");
        assertGt(
            wstETH.balanceOf(PUBLIC_LIQUIDATOR),
            liquidatorAssetBefore,
            "liquidator receives configured reward"
        );
        assertEq(
            _trackedPhysicalAssets(),
            trackedAssetsBefore,
            "no phantom external asset is created by reconciliation or Rebalancer bonus"
        );
    }
}
