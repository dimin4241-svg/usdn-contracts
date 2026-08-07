// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test, console2 } from "forge-std/Test.sol";

import { IUsdnProtocol } from "../../../src/interfaces/UsdnProtocol/IUsdnProtocol.sol";
import { IUsdnProtocolErrors } from "../../../src/interfaces/UsdnProtocol/IUsdnProtocolErrors.sol";
import { IBaseOracleMiddleware } from "../../../src/interfaces/OracleMiddleware/IBaseOracleMiddleware.sol";
import { PriceInfo } from "../../../src/interfaces/OracleMiddleware/IOracleMiddlewareTypes.sol";

/// @notice Read-only reachability probe against a fork of the *current* USDN
/// mainnet state. The only mocked dependency is the oracle return value so we
/// can ask the real deployed protocol how it behaves at prospective prices.
/// No protocol storage, positions, rebalancer state or accounting values are
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
        // liquidate() forwards the caller's oracle fee. Returning zero lets the
        // fork call exercise liquidation accounting without needing live Pyth
        // update bytes. The price itself is the only changed input.
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

    /// @dev Scan percentage price moves from the exact current state. Every
    /// candidate starts from the identical mainnet snapshot. A hit on
    /// UsdnProtocolInvalidLongExpo is direct current-state reachability proof.
    function test_scanCurrentMainnetStateForInvalidLongExpo() public {
        uint256 initialPositions = protocol.getTotalLongPositions();
        uint256 lastPrice = protocol.getLastPrice();
        uint256 snapshot = vm.snapshotState();
        bool sawMultiTickLiquidation;

        // 99.5% down through 35% of the protocol's stored price in 0.5% steps.
        // This intentionally includes extreme prices: the goal is first to
        // answer reachability, then narrow the minimum move if a hit exists.
        for (uint256 bps = 9950; bps >= 3500; bps -= 50) {
            vm.revertToState(snapshot);
            snapshot = vm.snapshotState();

            uint256 price = lastPrice * bps / 10_000;
            _mockOraclePrice(price);

            (bool ok, bytes memory data) = PROTOCOL.call(abi.encodeWithSignature("liquidate(bytes)", bytes("")));
            if (!ok) {
                bytes4 sel = _selector(data);
                if (sel == IUsdnProtocolErrors.UsdnProtocolInvalidLongExpo.selector) {
                    console2.log("CURRENT MAINNET INVALID_LONG_EXPO HIT");
                    console2.log("price bps", bps);
                    console2.log("price", price);
                    return;
                }
                // Other reverts are diagnostic. Log only the selector so the
                // scan remains readable.
                if (bps % 500 == 0) {
                    console2.log("other revert at bps", bps);
                    console2.logBytes4(sel);
                }
            } else {
                uint256 remaining = protocol.getTotalLongPositions();
                uint256 removed = initialPositions - remaining;
                if (removed >= 2 && !sawMultiTickLiquidation) {
                    sawMultiTickLiquidation = true;
                    console2.log("first successful multi-tick candidate bps", bps);
                    console2.log("price", price);
                    console2.log("positions removed", removed);
                }
            }

            if (bps == 3500) break;
        }

        console2.log("no InvalidLongExpo found in current-state coarse scan");
        console2.log("saw successful multi-tick liquidation", sawMultiTickLiquidation);
    }
}
