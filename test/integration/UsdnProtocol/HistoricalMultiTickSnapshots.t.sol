// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test, console2 } from "forge-std/Test.sol";

import { IUsdnProtocol } from "../../../src/interfaces/UsdnProtocol/IUsdnProtocol.sol";
import { IUsdnProtocolErrors } from "../../../src/interfaces/UsdnProtocol/IUsdnProtocolErrors.sol";
import { IUsdnProtocolTypes as Types } from "../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";
import { IBaseOracleMiddleware } from "../../../src/interfaces/OracleMiddleware/IBaseOracleMiddleware.sol";
import { PriceInfo } from "../../../src/interfaces/OracleMiddleware/IOracleMiddlewareTypes.sol";

/// @notice Adversarial replay scanner over real production snapshots immediately
/// before transactions that emitted multiple LiquidatedTick events on mainnet.
/// No USDN state is synthesized; only prospective oracle output is mocked.
contract TestHistoricalMultiTickSnapshots is Test {
    address internal constant PROTOCOL = 0x656cB8C6d154Aad29d8771384089be5B5141f01a;
    address internal constant ACTOR = address(0xBEEF);
    string internal constant ARCHIVE_RPC = "https://eth.drpc.org";

    IUsdnProtocol internal protocol;
    address internal oracle;

    function _selectPreState(uint256 liquidationBlock) internal {
        vm.createSelectFork(ARCHIVE_RPC, liquidationBlock - 1);
        vm.warp(block.timestamp + 12);
        protocol = IUsdnProtocol(PROTOCOL);
        oracle = address(protocol.getOracleMiddleware());
        vm.deal(ACTOR, 10 ether);
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

        for (uint256 step; step < 15_000 && positionCount_ < totalPositions; ++step) {
            Types.TickData memory td = protocol.getTickData(tick);
            if (td.totalPos != 0) {
                ticks_[tickCount_++] = tick;
                positionCount_ += td.totalPos;
            }
            tick -= spacing;
        }
    }

    /// @return hit_ True iff a natural public liquidation batch reverted with
    /// UsdnProtocolInvalidLongExpo from this exact production pre-state.
    function _scanSnapshot(uint256 liquidationBlock, uint256 actualRealBatchSize) internal returns (bool hit_) {
        _selectPreState(liquidationBlock);

        uint256 totalPositions = protocol.getTotalLongPositions();
        int24 highest = protocol.getHighestPopulatedTick();
        uint256 expo = protocol.getTotalExpo();
        uint256 longBalance = protocol.getBalanceLong();
        (int24[] memory populated, uint256 tickCount, uint256 countedPositions) = _populatedTicks();

        console2.log("SNAPSHOT block", liquidationBlock - 1);
        console2.log("real next-tx batch size", actualRealBatchSize);
        console2.log("positions", totalPositions);
        console2.log("populated ticks", tickCount);
        console2.log("highest tick", int256(highest));
        console2.log("totalExpo", expo);
        console2.log("balanceLong", longBalance);

        assertEq(countedPositions, totalPositions, "failed to enumerate snapshot positions");
        if (tickCount < 2) return false;

        uint256 rootSnapshot = vm.snapshotState();
        bool exercised2;
        bool exercised3Plus;

        // Every live populated tick boundary is a discontinuity in the set of
        // liquidatable ticks. Testing one wei below each boundary covers every
        // possible initial set of liquidatable populated ticks at this state.
        for (uint256 j = 1; j < tickCount; ++j) {
            vm.revertToState(rootSnapshot);
            rootSnapshot = vm.snapshotState();

            int24 boundaryTick = populated[j];
            uint256 boundary = protocol.getEffectivePriceForTick(boundaryTick);
            uint256 price = boundary > 1 ? boundary - 1 : boundary;
            uint256 expectedEligible = j + 1;
            uint256 cumulativeTicks;
            uint256 finalBatchSize;

            // Historical snapshots observed here contain far fewer than 80
            // populated ticks, so eight public batches cover the maximum path.
            for (uint256 batch; batch < 8; ++batch) {
                (bool ok, bytes4 sel, Types.LiqTickInfo[] memory removed) = _callLiquidate(price);
                if (!ok) {
                    if (sel == IUsdnProtocolErrors.UsdnProtocolInvalidLongExpo.selector) {
                        console2.log("*** HISTORICAL PRODUCTION INVALID_LONG_EXPO HIT ***");
                        console2.log("pre-state block", liquidationBlock - 1);
                        console2.log("boundary tick", int256(boundaryTick));
                        console2.log("candidate price", price);
                        console2.log("initially eligible ticks", expectedEligible);
                        console2.log("successful ticks before failing batch", cumulativeTicks);
                        console2.log("failing batch index", batch);
                        console2.log("totalExpo before failure", protocol.getTotalExpo());
                        console2.log("balanceLong before failure", protocol.getBalanceLong());
                        return true;
                    }
                    // A different protocol check means this boundary is not a
                    // valid witness for this finding; do not misclassify it.
                    break;
                }

                if (removed.length == 0) break;
                cumulativeTicks += removed.length;
                finalBatchSize = removed.length;
                if (cumulativeTicks >= expectedEligible) break;
            }

            if (cumulativeTicks == expectedEligible) {
                if (finalBatchSize == 2) exercised2 = true;
                if (finalBatchSize >= 3) exercised3Plus = true;
            }
        }

        console2.log("snapshot exercised final 2-tick batch", exercised2);
        console2.log("snapshot exercised final >=3-tick batch", exercised3Plus);
        console2.log("snapshot result: no InvalidLongExpo");
        return false;
    }

    // Real multi-tick transactions discovered from the protocol's complete
    // LiquidatedTick event history scan. The first three are a particularly
    // valuable early sequence: 2, then 4, then 6 ticks within ~100 blocks.
    function test_A_block21762803_real2TickSnapshot() public {
        _scanSnapshot(21_762_803, 2);
    }

    function test_B_block21762859_real4TickSnapshot() public {
        _scanSnapshot(21_762_859, 4);
    }

    function test_C_block21762906_real6TickSnapshot() public {
        _scanSnapshot(21_762_906, 6);
    }

    function test_D_block21921846_real2TickSnapshot() public {
        _scanSnapshot(21_921_846, 2);
    }

    function test_E_block22018393_real2TickSnapshot() public {
        _scanSnapshot(22_018_393, 2);
    }

    function test_F_block22211357_real2TickSnapshot() public {
        _scanSnapshot(22_211_357, 2);
    }

    function test_G_block23416674_real2TickSnapshot() public {
        _scanSnapshot(23_416_674, 2);
    }

    function test_H_block25240929_real2TickSnapshot() public {
        _scanSnapshot(25_240_929, 2);
    }
}
