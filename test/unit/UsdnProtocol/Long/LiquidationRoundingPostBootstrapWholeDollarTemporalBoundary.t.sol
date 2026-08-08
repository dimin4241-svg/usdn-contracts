// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { TestLiquidationRoundingPostBootstrapWholeDollarVulnerable } from "./LiquidationRoundingPostBootstrapWholeDollarVulnerable.t.sol";
import { IUsdnProtocolTypes as Types } from "../../../../src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

/// @notice Measures how long the exact $1651 -> $1586 whole-dollar witness keeps
/// the dedicated public liquidation endpoint in the atomic two-tick revert state.
/// Every test inherits the exact same post-bootstrap fixture; only wall-clock time
/// is shifted before the final public liquidation attempt.
contract TestLiquidationRoundingPostBootstrapWholeDollarTemporalBoundary is
    TestLiquidationRoundingPostBootstrapWholeDollarVulnerable
{
    event TemporalOutcome(
        uint256 shift,
        bool reverted,
        uint256 ticks,
        uint256 positionsAfter,
        int24 highestAfter,
        uint256 rewardDelta
    );

    function test_shift01() public { _characterize(1 seconds); }
    function test_shift10() public { _characterize(10 seconds); }
    function test_shift20() public { _characterize(20 seconds); }
    function test_shift30() public { _characterize(30 seconds); }
    function test_shift35() public { _characterize(35 seconds); }
    function test_shift40() public { _characterize(40 seconds); }
    function test_shift45() public { _characterize(45 seconds); }
    function test_shift50() public { _characterize(50 seconds); }
    function test_shift55() public { _characterize(55 seconds); }
    function test_shift59() public { _characterize(59 seconds); }
    function test_shift60() public { _characterize(60 seconds); }

    function _characterize(uint256 shift) internal {
        uint256 positionsBefore = protocol.getTotalLongPositions();
        uint256 expoBefore = protocol.getTotalExpo();
        uint256 longBefore = protocol.getBalanceLong();
        int24 highestBefore = protocol.getHighestPopulatedTick();
        uint256 liquidatorBefore = wstETH.balanceOf(PUBLIC_LIQUIDATOR);

        assertEq(positionsBefore, 2, "whole-dollar witness must start with A+B");
        assertEq(highestBefore, EXPECTED_A_TICK, "whole-dollar witness highest tick");

        vm.warp(block.timestamp + shift);
        vm.startPrank(PUBLIC_LIQUIDATOR, PUBLIC_LIQUIDATOR);
        try protocol.liquidate(abi.encode(FINAL_PRICE)) returns (Types.LiqTickInfo[] memory ticks) {
            vm.stopPrank();
            uint256 positionsAfter = protocol.getTotalLongPositions();
            uint256 liquidatorAfter = wstETH.balanceOf(PUBLIC_LIQUIDATOR);

            assertGt(ticks.length, 0, "successful retry must liquidate at least one tick");
            assertLt(positionsAfter, positionsBefore, "successful retry must commit progress");
            assertGt(liquidatorAfter, liquidatorBefore, "successful retry must pay reward");
            assertLe(protocol.getBalanceLong(), protocol.getTotalExpo(), "success must preserve long/expo invariant");

            emit TemporalOutcome(
                shift,
                false,
                ticks.length,
                positionsAfter,
                protocol.getHighestPopulatedTick(),
                liquidatorAfter - liquidatorBefore
            );
        } catch (bytes memory reason) {
            vm.stopPrank();

            assertEq(reason.length, 4, "unexpected revert payload length");
            assertEq(bytes4(reason), bytes4(keccak256("UsdnProtocolInvalidLongExpo()")), "unexpected revert selector");
            assertEq(protocol.getTotalLongPositions(), positionsBefore, "revert changed position count");
            assertEq(protocol.getTotalExpo(), expoBefore, "revert changed exposure");
            assertEq(protocol.getBalanceLong(), longBefore, "revert changed long balance");
            assertEq(protocol.getHighestPopulatedTick(), highestBefore, "revert changed highest tick");
            assertEq(wstETH.balanceOf(PUBLIC_LIQUIDATOR), liquidatorBefore, "revert paid liquidator");

            emit TemporalOutcome(shift, true, 0, positionsBefore, highestBefore, 0);
        }
    }
}
