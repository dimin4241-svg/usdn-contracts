// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice High-severity probe: look for a rounding residue with liquidationIteration == 1.
/// If a single populated tick can itself end with newLongBalance > totalExpo, the
/// existing one-tick permissionless recovery path for user actions no longer helps:
/// validateWithdrawal/validateClosePosition would reach the Rebalancer sink in the
/// same transaction instead of committing one tick of progress.
contract TestLiquidationRoundingSingleTickHighProbe is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;

    // Large but still ordinary public user position. The explicit initial vault
    // deposit is chosen to keep the production 5% open-imbalance limit enabled
    // while providing trading-exposure capacity for this position.
    uint128 internal constant TARGET_AMOUNT = 500 ether;
    uint128 internal constant TARGET_DESIRED_LIQ = 1835 ether;
    uint128 internal constant INITIAL_VAULT = 4_300 ether;

    address internal constant TRADER = address(0xBEEF);

    PositionId internal targetPos;

    event SingleTickWitness(
        uint256 oraclePrice,
        int24 tick,
        uint256 totalExpoBefore,
        int256 tempLongBalance,
        int256 remainingCollateral,
        uint256 newLongBalance,
        uint256 totalExpoAfter
    );

    function setUp() public {
        params = DEFAULT_PARAMS;
        params.initialDeposit = INITIAL_VAULT;
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

        vm.deal(TRADER, 10 ether);
        super._setUp(params);

        assertEq(protocol.getLiquidationIteration(), 1, "production user-action iteration");
        assertEq(protocol.getMaxLeverage(), 10 ether, "production max leverage");
        assertEq(protocol.getSafetyMarginBps(), 200, "production safety margin");
        assertGt(protocol.getCloseExpoImbalanceLimitBps(), 0, "production close imbalance limit");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "production Rebalancer installed");

        // Remove the initialization-created long first. No witness state is inherited
        // from bootstrap; the large position below is created through normal public flows.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap long must be gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap exposure must be gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap long balance must be gone");

        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "price reset keeps empty long side");

        targetPos = setUpUserPositionInLong(
            OpenParams(TRADER, ProtocolAction.ValidateOpenPosition, TARGET_AMOUNT, TARGET_DESIRED_LIQ, ENTRY_PRICE)
        );

        assertEq(protocol.getTotalLongPositions(), 1, "exactly one populated long position");
        assertEq(protocol.getHighestPopulatedTick(), targetPos.tick, "target must be highest/only tick");
        _waitBeforeLiquidation();
    }

    /// @dev Searches realistic whole-dollar oracle prices inside the target tick's
    /// positive-collateral liquidation window. Each candidate is executed against
    /// the real v1.0.0 source helper and then rolled back.
    function test_probeSingleTickWholeDollarResidue() public {
        uint256 tickBoundary = protocol.getEffectivePriceForTick(targetPos.tick);
        int24 noPenaltyTick = protocol.i_calcTickWithoutPenalty(targetPos.tick);
        uint256 noPenaltyBoundary = protocol.getEffectivePriceForTick(noPenaltyTick);

        assertGt(tickBoundary, noPenaltyBoundary, "need positive-collateral liquidation window");

        uint256 firstDollar = noPenaltyBoundary / 1 ether + 1;
        uint256 lastDollar = (tickBoundary - 1) / 1 ether;
        assertLe(firstDollar, lastDollar, "need at least one whole-dollar price in window");

        uint256 totalExpoBefore = protocol.getTotalExpo();
        assertGt(totalExpoBefore, uint256(ENTRY_PRICE), "probe needs exposure large enough for sub-wei price rounding to matter");

        for (uint256 dollars = firstDollar; dollars <= lastDollar; ++dollars) {
            uint256 snapshot = vm.snapshotState();
            uint128 price = uint128(dollars * 1 ether);

            Types.ApplyPnlAndFundingData memory pnl =
                protocol.i_applyPnlAndFunding(price, uint128(block.timestamp - 30 seconds));
            Types.LiquidationsEffects memory effects =
                protocol.i_liquidatePositions(price, 1, pnl.tempLongBalance, pnl.tempVaultBalance);

            if (
                effects.liquidatedTicks.length == 1
                    && protocol.getTotalExpo() == 0
                    && effects.newLongBalance > protocol.getTotalExpo()
            ) {
                emit SingleTickWitness(
                    price,
                    targetPos.tick,
                    totalExpoBefore,
                    pnl.tempLongBalance,
                    effects.liquidatedTicks[0].remainingCollateral,
                    effects.newLongBalance,
                    protocol.getTotalExpo()
                );
                assertGt(effects.newLongBalance, 0, "single-tick residue must be positive");
                return;
            }

            vm.revertToState(snapshot);
        }

        assertTrue(false, "no single-tick whole-dollar residue found");
    }
}
