// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test, console2 } from "forge-std/Test.sol";

import { IUsdnProtocol } from "../../../src/interfaces/UsdnProtocol/IUsdnProtocol.sol";
import { IUsdnProtocolErrors } from "../../../src/interfaces/UsdnProtocol/IUsdnProtocolErrors.sol";
import { IUsdnProtocolTypes as Types } from "../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";
import { IBaseOracleMiddleware } from "../../../src/interfaces/OracleMiddleware/IBaseOracleMiddleware.sol";
import { PriceInfo } from "../../../src/interfaces/OracleMiddleware/IOracleMiddlewareTypes.sol";

/// @notice Prospective reachability probe starting from the exact current USDN
/// mainnet state. Only future oracle prices are mocked. No protocol storage,
/// balances, accumulator values, ticks, positions or Rebalancer state are
/// synthesized.
contract TestCurrentMainnetLiquidationReachability is Test {
    address internal constant PROTOCOL = 0x656cB8C6d154Aad29d8771384089be5B5141f01a;
    string internal constant RPC = "https://ethereum-rpc.publicnode.com";

    IUsdnProtocol internal protocol;
    address internal oracle;

    function setUp() public {
        vm.createSelectFork(RPC);
        protocol = IUsdnProtocol(PROTOCOL);
        oracle = address(protocol.getOracleMiddleware());

        console2.log("fork block", block.number);
        console2.log("last price", protocol.getLastPrice());
        console2.log("total expo", protocol.getTotalExpo());
        console2.log("long balance", protocol.getBalanceLong());
        console2.log("vault balance", protocol.getBalanceVault());
        console2.log("positions", protocol.getTotalLongPositions());
        console2.log("highest tick", int256(protocol.getHighestPopulatedTick()));
        console2.log("liquidation iteration", protocol.getLiquidationIteration());
        console2.log("oracle", oracle);
    }

    function _mockOraclePrice(uint256 price) internal {
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IBaseOracleMiddleware.validationCost.selector),
            abi.encode(uint256(0))
        );
        PriceInfo memory info = PriceInfo({ price: price, neutralPrice: price, timestamp: block.timestamp });
        vm.mockCall(
            oracle,
            abi.encodeWithSelector(IBaseOracleMiddleware.parseAndValidatePrice.selector),
            abi.encode(info)
        );
    }

    function _selector(bytes memory revertData) internal pure returns (bytes4 sel) {
        if (revertData.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(revertData, 0x20))
        }
    }

    function _callLiquidate(uint256 price)
        internal
        returns (bool ok_, bytes4 selector_, Types.LiqTickInfo[] memory ticks_)
    {
        _mockOraclePrice(price);
        bytes memory data;
        (ok_, data) = PROTOCOL.call(abi.encodeWithSignature("liquidate(bytes)", bytes("")));
        if (!ok_) {
            selector_ = _selector(data);
            return (ok_, selector_, ticks_);
        }
        ticks_ = abi.decode(data, (Types.LiqTickInfo[]));
    }

    /// @dev Enumerates the real populated ticks from the live fork. Ticks are
    /// returned in descending order. The sum of TickData.totalPos must equal
    /// the protocol's live totalLongPositions count.
    function _currentPopulatedTicks()
        internal
        view
        returns (int24[] memory ticks_, uint256 tickCount_, uint256 positionCount_)
    {
        uint256 totalPositions = protocol.getTotalLongPositions();
        ticks_ = new int24[](totalPositions);

        int24 spacing = protocol.getTickSpacing();
        int24 tick = protocol.getHighestPopulatedTick();

        for (uint256 step; step < 10_000 && positionCount_ < totalPositions; ++step) {
            Types.TickData memory td = protocol.getTickData(tick);
            if (td.totalPos != 0) {
                ticks_[tickCount_++] = tick;
                positionCount_ += td.totalPos;
            }
            tick -= spacing;
        }
    }

    /// @dev Production-faithful batching probe. Candidate j chooses a price one
    /// wei below the effective liquidation boundary of live populated tick j.
    /// Starting from the identical current-mainnet snapshot, that makes the
    /// top j+1 ticks liquidatable. Repeated public liquidate() calls therefore
    /// exercise the protocol's real MAX_LIQUIDATION_ITERATION batching
    /// (10 + 10 + ... + final remainder). Rebalancer is left untouched and can
    /// only run once no higher liquidations remain, exactly where the reported
    /// InvalidLongExpo sink is reached.
    function test_everyCurrentLiveTickBoundaryWithProductionBatching() public {
        (int24[] memory populated, uint256 tickCount, uint256 countedPositions) = _currentPopulatedTicks();
        uint256 initialPositions = protocol.getTotalLongPositions();

        console2.log("populated tick count", tickCount);
        console2.log("positions accounted by TickData", countedPositions);
        assertEq(countedPositions, initialPositions, "failed to enumerate all live positions");
        assertGt(tickCount, 1, "need at least two live ticks");

        uint256 rootSnapshot = vm.snapshotState();
        bool sawTwoTickFinal;
        bool sawThreePlusFinal;

        // j=1 starts with exactly two live ticks eligible. Larger j naturally
        // exercises final remainders after one or more full 10-tick batches.
        for (uint256 j = 1; j < tickCount; ++j) {
            vm.revertToState(rootSnapshot);
            rootSnapshot = vm.snapshotState();

            int24 boundaryTick = populated[j];
            uint256 boundary = protocol.getEffectivePriceForTick(boundaryTick);
            uint256 price = boundary > 1 ? boundary - 1 : boundary;
            uint256 expectedEligible = j + 1;
            uint256 cumulativeTicks;
            uint256 batchIndex;
            uint256 finalBatchSize;
            bool candidateDone;

            // With 26 live ticks four calls are enough (10+10+6). Keep five
            // for margin if the live state changes between CI runs.
            for (; batchIndex < 5; ++batchIndex) {
                (bool ok, bytes4 sel, Types.LiqTickInfo[] memory removed) = _callLiquidate(price);

                if (!ok) {
                    if (sel == IUsdnProtocolErrors.UsdnProtocolInvalidLongExpo.selector) {
                        console2.log("CURRENT MAINNET INVALID_LONG_EXPO HIT");
                        console2.log("boundary tick", int256(boundaryTick));
                        console2.log("candidate price", price);
                        console2.log("expected initially eligible ticks", expectedEligible);
                        console2.log("successful ticks before failing batch", cumulativeTicks);
                        console2.log("failing batch index", batchIndex);
                        console2.log("totalExpo before failing batch", protocol.getTotalExpo());
                        console2.log("balanceLong before failing batch", protocol.getBalanceLong());
                        return;
                    }

                    console2.log("candidate other revert");
                    console2.log("boundary tick", int256(boundaryTick));
                    console2.log("candidate price", price);
                    console2.logBytes4(sel);
                    candidateDone = true;
                    break;
                }

                if (removed.length == 0) {
                    candidateDone = true;
                    break;
                }

                cumulativeTicks += removed.length;
                finalBatchSize = removed.length;

                // Once all ticks that were expected to be above this price have
                // been processed, this call is the final initial-state batch;
                // the production Rebalancer sink has already executed if no
                // liquidation remains pending.
                if (cumulativeTicks >= expectedEligible) {
                    candidateDone = true;
                    break;
                }
            }

            if (!candidateDone) {
                console2.log("candidate exceeded batch budget");
                console2.log("boundary tick", int256(boundaryTick));
                continue;
            }

            if (cumulativeTicks == expectedEligible) {
                if (finalBatchSize == 2) sawTwoTickFinal = true;
                if (finalBatchSize >= 3) sawThreePlusFinal = true;

                console2.log("candidate completed");
                console2.log("boundary tick", int256(boundaryTick));
                console2.log("eligible ticks", expectedEligible);
                console2.log("final batch size", finalBatchSize);
                console2.log("final protocol totalExpo", protocol.getTotalExpo());
                console2.log("final protocol balanceLong", protocol.getBalanceLong());
            } else {
                console2.log("eligibility mismatch");
                console2.log("boundary tick", int256(boundaryTick));
                console2.log("expected eligible", expectedEligible);
                console2.log("actually liquidated", cumulativeTicks);
            }
        }

        console2.log("saw final two-tick production batch", sawTwoTickFinal);
        console2.log("saw final >=3-tick production batch", sawThreePlusFinal);
        console2.log("NO CURRENT MAINNET INVALID_LONG_EXPO HIT ACROSS ALL LIVE TICK BOUNDARIES");
    }
}
