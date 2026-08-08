// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { UsdnProtocolBaseFixture } from "../utils/Fixtures.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice High-severity probe: look for a rounding residue with liquidationIteration == 1.
/// If one populated tick can itself end with newLongBalance > totalExpo, the
/// one-tick permissionless recovery argument for user actions disappears.
contract TestLiquidationRoundingSingleTickHighProbe is UsdnProtocolBaseFixture {
    uint128 internal constant ENTRY_PRICE = 2000 ether;
    uint128 internal constant BOOTSTRAP_LIQ_PRICE = 980 ether;

    // Build a large but balanced protocol first. initialDeposit=0 makes the fixture
    // auto-calculate the exact equilibrium vault side, so no imbalance limit is bypassed.
    uint128 internal constant INITIAL_LONG = 20_000 ether;

    // This position is opened by an ordinary user through initiate/validate with all
    // production limits enabled. Its exposure is intentionally > ~$1,250-equivalent
    // in raw 1e18 units so sub-wei effective-price rounding can become a full wei.
    uint128 internal constant TARGET_AMOUNT = 500 ether;
    uint128 internal constant TARGET_DESIRED_LIQ = 1250 ether;

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
        params.initialDeposit = 0; // exact equilibrium, calculated by the fixture
        params.initialLong = INITIAL_LONG;
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

        assertEq(protocol.getLiquidationIteration(), 1, "user-action liquidation iteration");
        assertGt(protocol.getMaxLeverage(), 10 ** 21, "max leverage must exceed 1x");
        assertEq(protocol.getSafetyMarginBps(), 200, "default safety margin");
        assertGt(protocol.getOpenExpoImbalanceLimitBps(), 0, "open imbalance limit must remain enabled");
        assertGt(protocol.getCloseExpoImbalanceLimitBps(), 0, "close imbalance limit must remain enabled");
        assertEq(address(protocol.getRebalancer()), address(rebalancer), "Rebalancer installed");

        // Remove the initialization-created long. This leaves a large organically
        // plausible vault TVL, while the attacker-controlled position below is created
        // only through normal public user actions.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(BOOTSTRAP_LIQ_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "bootstrap long must be gone");
        assertEq(protocol.getTotalExpo(), 0, "bootstrap exposure must be gone");
        assertEq(protocol.getBalanceLong(), 0, "bootstrap long balance must be gone");

        // Reset lastPrice to the normal entry price before opening the user position.
        _waitDelay();
        _waitDelay();
        protocol.liquidate(abi.encode(ENTRY_PRICE));
        assertEq(protocol.getTotalLongPositions(), 0, "price reset keeps empty long side");

        targetPos = setUpUserPositionInLong(
            OpenParams(TRADER, ProtocolAction.ValidateOpenPosition, TARGET_AMOUNT, TARGET_DESIRED_LIQ, ENTRY_PRICE)
        );

        assertEq(protocol.getTotalLongPositions(), 1, "exactly one populated long position");
        assertEq(protocol.getHighestPopulatedTick(), targetPos.tick, "target must be highest/only tick");
        assertGt(protocol.getTotalExpo(), TARGET_AMOUNT, "position must carry trading exposure");
        _waitBeforeLiquidation();
    }

    /// @dev Searches whole-dollar oracle prices inside the target tick's
    /// positive-collateral liquidation window. Each candidate is executed against
    /// the real vulnerable liquidation helper and then rolled back.
    function test_probeSingleTickWholeDollarResidue() public {
        uint256 tickBoundary = protocol.getEffectivePriceForTick(targetPos.tick);
        int24 noPenaltyTick = protocol.i_calcTickWithoutPenalty(targetPos.tick);
        uint256 noPenaltyBoundary = protocol.getEffectivePriceForTick(noPenaltyTick);

        assertGt(tickBoundary, noPenaltyBoundary, "need positive-collateral liquidation window");

        uint256 firstDollar = noPenaltyBoundary / 1 ether + 1;
        uint256 lastDollar = (tickBoundary - 1) / 1 ether;
        assertLe(firstDollar, lastDollar, "need at least one whole-dollar price in window");

        uint256 totalExpoBefore = protocol.getTotalExpo();
        assertGt(totalExpoBefore, 1250 ether, "exposure must be large enough for one-wei amplification");

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
