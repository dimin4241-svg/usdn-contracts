// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test, console2 } from "forge-std/Test.sol";

import { IUsdnProtocol } from "../../../src/interfaces/UsdnProtocol/IUsdnProtocol.sol";
import { IUsdnProtocolErrors } from "../../../src/interfaces/UsdnProtocol/IUsdnProtocolErrors.sol";
import { IBaseOracleMiddleware } from "../../../src/interfaces/OracleMiddleware/IBaseOracleMiddleware.sol";
import { PriceInfo } from "../../../src/interfaces/OracleMiddleware/IOracleMiddlewareTypes.sol";

/// @notice Reachability probe against a fork of the current USDN mainnet state.
/// Only the oracle return value is mocked. Protocol storage, positions,
/// accumulator, balances and Rebalancer state are the live deployed values.
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

    /// @dev For every candidate price, repeatedly call the real deployed
    /// liquidate() on the fork. This matters because public liquidation is
    /// capped per call; a deep price move can require 10 + 10 + ... + final
    /// ticks, and the rounding bug is most relevant in the final batch.
    function test_scanCurrentMainnetStateForInvalidLongExpo() public {
        uint256 initialPositions = protocol.getTotalLongPositions();
        uint256 lastPrice = protocol.getLastPrice();
        uint256 snapshot = vm.snapshotState();
        bool sawMultiTickLiquidation;
        bool sawMultiBatchLiquidation;

        for (uint256 bps = 9950; bps >= 3000; bps -= 50) {
            vm.revertToState(snapshot);
            snapshot = vm.snapshotState();

            uint256 price = lastPrice * bps / 10_000;
            _mockOraclePrice(price);
            uint256 previousPositions = initialPositions;
            uint256 successfulBatches;

            // 35 positions exist in the captured live state, so eight calls are
            // comfortably above the number needed even if every batch were
            // capped at only a few ticks.
            for (uint256 batch; batch < 8; ++batch) {
                (bool ok, bytes memory data) = PROTOCOL.call(abi.encodeWithSignature("liquidate(bytes)", bytes("")));
                if (!ok) {
                    bytes4 sel = _selector(data);
                    if (sel == IUsdnProtocolErrors.UsdnProtocolInvalidLongExpo.selector) {
                        console2.log("CURRENT MAINNET INVALID_LONG_EXPO HIT");
                        console2.log("price bps", bps);
                        console2.log("price", price);
                        console2.log("failed batch index", batch);
                        console2.log("successful batches before failure", successfulBatches);
                        console2.log("positions before failing batch", previousPositions);
                        return;
                    }
                    // A different revert ends this candidate; it must not be
                    // misclassified as the accounting bug.
                    if (bps % 500 == 0) {
                        console2.log("other revert at bps", bps);
                        console2.log("batch", batch);
                        console2.logBytes4(sel);
                    }
                    break;
                }

                uint256 remaining = protocol.getTotalLongPositions();
                uint256 removedThisBatch = previousPositions - remaining;
                if (removedThisBatch == 0) break;

                ++successfulBatches;
                if (removedThisBatch >= 2 && !sawMultiTickLiquidation) {
                    sawMultiTickLiquidation = true;
                    console2.log("first successful multi-tick candidate bps", bps);
                    console2.log("price", price);
                    console2.log("positions removed in batch", removedThisBatch);
                }
                if (successfulBatches >= 2) sawMultiBatchLiquidation = true;

                previousPositions = remaining;
                if (remaining == 0) break;
            }

            if (bps == 3000) break;
        }

        console2.log("no InvalidLongExpo found in current-state repeated-batch scan");
        console2.log("saw successful multi-tick liquidation", sawMultiTickLiquidation);
        console2.log("saw successful multi-batch liquidation", sawMultiBatchLiquidation);
    }
}
