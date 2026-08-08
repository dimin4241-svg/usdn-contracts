// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test, console2 } from "forge-std/Test.sol";

import { IUsdnProtocol } from "../../../src/interfaces/UsdnProtocol/IUsdnProtocol.sol";
import { IUsdnProtocolErrors } from "../../../src/interfaces/UsdnProtocol/IUsdnProtocolErrors.sol";
import { IUsdnProtocolTypes as Types } from "../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";
import { IBaseOracleMiddleware } from "../../../src/interfaces/OracleMiddleware/IBaseOracleMiddleware.sol";
import { PriceInfo } from "../../../src/interfaces/OracleMiddleware/IOracleMiddlewareTypes.sol";

/// @notice Forks the exact mainnet state immediately before transaction
/// 0x8612e92fdc17641e2a2f7ae2f33bfd6a75486cf93305f135b0d74bdfcd6579f3,
/// which emitted two LiquidatedTick events (76000 and 75900) in block 25240929.
/// Only prospective oracle output is mocked. All USDN storage, implementation,
/// positions, accumulator and Rebalancer state come from the historical chain.
contract TestHistoricalMainnetLiquidationReachability is Test {
    address internal constant PROTOCOL = 0x656cB8C6d154Aad29d8771384089be5B5141f01a;
    address internal constant ACTOR = address(0xBEEF);
    string internal constant ARCHIVE_RPC = "https://eth.drpc.org";
    uint256 internal constant FORK_BLOCK = 25_240_928;

    uint256 internal constant REAL_LIQUIDATION_PRICE = 2_129_347_370_674_453_391_094;

    IUsdnProtocol internal protocol;
    address internal oracle;

    function setUp() public {
        vm.createSelectFork(ARCHIVE_RPC, FORK_BLOCK);
        vm.warp(block.timestamp + 12);

        protocol = IUsdnProtocol(PROTOCOL);
        oracle = address(protocol.getOracleMiddleware());
        vm.deal(ACTOR, 10 ether);

        console2.log("fork block", FORK_BLOCK);
        console2.log("last price", protocol.getLastPrice());
        console2.log("total expo", protocol.getTotalExpo());
        console2.log("long balance", protocol.getBalanceLong());
        console2.log("vault balance", protocol.getBalanceVault());
        console2.log("positions", protocol.getTotalLongPositions());
        console2.log("highest tick", int256(protocol.getHighestPopulatedTick()));

        assertEq(protocol.getLastPrice(), 2_172_386_083_548_588_700_245, "historical lastPrice mismatch");
        assertEq(protocol.getTotalExpo(), 580_162_335_058_503_923_346, "historical totalExpo mismatch");
        assertEq(protocol.getBalanceLong(), 165_175_187_079_186_674_402, "historical balanceLong mismatch");
        assertEq(protocol.getBalanceVault(), 429_552_229_902_924_664_984, "historical balanceVault mismatch");
        assertEq(protocol.getTotalLongPositions(), 46, "historical position count mismatch");
        assertEq(protocol.getHighestPopulatedTick(), 76_000, "historical highest tick mismatch");
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
        vm.prank(ACTOR);
        (ok_, data) = PROTOCOL.call(abi.encodeWithSignature("liquidate(bytes)", bytes("")));
        if (!ok_) {
            selector_ = _selector(data);
            return (ok_, selector_, ticks_);
        }
        ticks_ = abi.decode(data, (Types.LiqTickInfo[]));
    }

    function _populatedTicks()
        internal
        view
        returns (int24[] memory ticks_, uint256 tickCount_, uint256 positionCount_)
    {
        uint256 totalPositions = protocol.getTotalLongPositions();
        ticks_ = new int24[](totalPositions);
        int24 spacing = protocol.getTickSpacing();
        int24 tick = protocol.getHighestPopulatedTick();

        for (uint256 step; step < 12_000 && positionCount_ < totalPositions; ++step) {
            Types.TickData memory td = protocol.getTickData(tick);
            if (td.totalPos != 0) {
                ticks_[tickCount_++] = tick;
                positionCount_ += td.totalPos;
            }
            tick -= spacing;
        }
    }

    /// @dev The exact price emitted by the real next-block transaction should
    /// select the same two highest populated ticks. LiqTickInfo itself does not
    /// carry the tick number, so tick identity is proven by enumerating the
    /// pre-state and checking the resulting highest populated tick.
    function test_A_exactRealPriceReproducesHistoricalTwoTickBatch() public {
        (int24[] memory populated, uint256 tickCount,) = _populatedTicks();
        assertGe(tickCount, 3, "historical state needs at least three populated ticks");
        assertEq(populated[0], 76_000, "historical top tick mismatch");
        assertEq(populated[1], 75_900, "historical second tick mismatch");

        (bool ok, bytes4 sel, Types.LiqTickInfo[] memory ticks) = _callLiquidate(REAL_LIQUIDATION_PRICE);
        if (!ok) {
            console2.log("real-price call reverted");
            console2.logBytes4(sel);
        }
        assertTrue(ok, "real historical liquidation price must succeed on pre-state");
        assertEq(ticks.length, 2, "real historical price must liquidate exactly two ticks");
        assertEq(protocol.getHighestPopulatedTick(), populated[2], "two highest historical ticks were not removed");

        console2.log("real price reproduced two-tick batch");
        console2.log("removed top ticks", int256(populated[0]), int256(populated[1]));
        console2.log("new highest tick", int256(protocol.getHighestPopulatedTick()));
        console2.log("tick0 remaining collateral", ticks[0].remainingCollateral);
        console2.log("tick1 remaining collateral", ticks[1].remainingCollateral);
    }

    function test_B_scanAllHistoricalLiveTickBoundaries() public {
        (int24[] memory populated, uint256 tickCount, uint256 countedPositions) = _populatedTicks();
        assertEq(countedPositions, protocol.getTotalLongPositions(), "failed to enumerate historical positions");
        assertGt(tickCount, 1, "need multiple historical ticks");

        console2.log("historical populated tick count", tickCount);
        console2.log("historical positions accounted", countedPositions);

        uint256 rootSnapshot = vm.snapshotState();
        bool sawFinal2;
        bool sawFinal3Plus;

        for (uint256 j = 1; j < tickCount; ++j) {
            vm.revertToState(rootSnapshot);
            rootSnapshot = vm.snapshotState();

            int24 boundaryTick = populated[j];
            uint256 boundary = protocol.getEffectivePriceForTick(boundaryTick);
            uint256 price = boundary > 1 ? boundary - 1 : boundary;
            uint256 expectedEligible = j + 1;
            uint256 cumulativeTicks;
            uint256 finalBatchSize;

            for (uint256 batch; batch < 8; ++batch) {
                (bool ok, bytes4 sel, Types.LiqTickInfo[] memory removed) = _callLiquidate(price);
                if (!ok) {
                    if (sel == IUsdnProtocolErrors.UsdnProtocolInvalidLongExpo.selector) {
                        console2.log("HISTORICAL MAINNET INVALID_LONG_EXPO HIT");
                        console2.log("boundary tick", int256(boundaryTick));
                        console2.log("candidate price", price);
                        console2.log("initially eligible ticks", expectedEligible);
                        console2.log("successful ticks before failing batch", cumulativeTicks);
                        console2.log("failing batch index", batch);
                        console2.log("totalExpo before failing batch", protocol.getTotalExpo());
                        console2.log("balanceLong before failing batch", protocol.getBalanceLong());
                        return;
                    }
                    break;
                }

                if (removed.length == 0) break;
                cumulativeTicks += removed.length;
                finalBatchSize = removed.length;
                if (cumulativeTicks >= expectedEligible) break;
            }

            if (cumulativeTicks == expectedEligible) {
                if (finalBatchSize == 2) sawFinal2 = true;
                if (finalBatchSize >= 3) sawFinal3Plus = true;
                console2.log("historical candidate completed");
                console2.log("boundary tick", int256(boundaryTick));
                console2.log("eligible ticks", expectedEligible);
                console2.log("final batch size", finalBatchSize);
            }
        }

        console2.log("historical saw final 2-tick batch", sawFinal2);
        console2.log("historical saw final >=3-tick batch", sawFinal3Plus);
        console2.log("NO HISTORICAL INVALID_LONG_EXPO HIT ACROSS ENUMERATED BOUNDARIES");
    }
}
