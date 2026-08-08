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
    uint256 internal constant EXPECTED_PRESTATE_POSITIONS = 2;
    uint256 internal constant EXPECTED_PRESTATE_EXPO = 18_299_478_101_274_206_497;
    uint256 internal constant EXPECTED_PRESTATE_LONG = 971_462_201_938_421_127;

    event TemporalOutcome(
        uint256 shift,
        bool reverted,
        uint256 ticks,
        uint256 positionsAfter,
        int24 highestAfter,
        uint256 rewardDelta
    );

    function test_boundary59_revertsAtomically() public {
        _assertAtomicRevertAt(59 seconds);
    }

    function test_boundary60_commitsProgressAndPaysReward() public {
        _assertProgressAt(60 seconds);
    }

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

    function _pinPrestate() internal view {
        assertEq(protocol.getTotalLongPositions(), EXPECTED_PRESTATE_POSITIONS, "whole-dollar prestate positions");
        assertEq(protocol.getTotalExpo(), EXPECTED_PRESTATE_EXPO, "whole-dollar prestate exposure");
        assertEq(protocol.getBalanceLong(), EXPECTED_PRESTATE_LONG, "whole-dollar prestate long balance");
        assertEq(protocol.getHighestPopulatedTick(), EXPECTED_A_TICK, "whole-dollar prestate highest tick");
        assertEq(uint256(FINAL_PRICE), 1_586 ether, "whole-dollar final price");
        assertEq(wstETH.balanceOf(PUBLIC_LIQUIDATOR), 0, "liquidator starts with no wstETH reward");
    }

    function _assertAtomicRevertAt(uint256 shift) internal {
        _pinPrestate();
        uint256 positionsBefore = protocol.getTotalLongPositions();
        uint256 expoBefore = protocol.getTotalExpo();
        uint256 longBefore = protocol.getBalanceLong();
        int24 highestBefore = protocol.getHighestPopulatedTick();
        uint256 liquidatorBefore = wstETH.balanceOf(PUBLIC_LIQUIDATOR);

        vm.warp(block.timestamp + shift);
        vm.startPrank(PUBLIC_LIQUIDATOR, PUBLIC_LIQUIDATOR);
        try protocol.liquidate(abi.encode(FINAL_PRICE)) returns (Types.LiqTickInfo[] memory) {
            vm.stopPrank();
            assertTrue(false, "expected atomic UsdnProtocolInvalidLongExpo revert");
        } catch (bytes memory reason) {
            vm.stopPrank();
            assertEq(reason.length, 4, "unexpected revert payload length");
            assertEq(bytes4(reason), bytes4(keccak256("UsdnProtocolInvalidLongExpo()")), "unexpected revert selector");
        }

        assertEq(protocol.getTotalLongPositions(), positionsBefore, "revert changed position count");
        assertEq(protocol.getTotalExpo(), expoBefore, "revert changed exposure");
        assertEq(protocol.getBalanceLong(), longBefore, "revert changed long balance");
        assertEq(protocol.getHighestPopulatedTick(), highestBefore, "revert changed highest tick");
        assertEq(wstETH.balanceOf(PUBLIC_LIQUIDATOR), liquidatorBefore, "revert paid liquidator");
    }

    function _assertProgressAt(uint256 shift) internal {
        _pinPrestate();
        uint256 positionsBefore = protocol.getTotalLongPositions();
        uint256 liquidatorBefore = wstETH.balanceOf(PUBLIC_LIQUIDATOR);

        vm.warp(block.timestamp + shift);
        vm.startPrank(PUBLIC_LIQUIDATOR, PUBLIC_LIQUIDATOR);
        Types.LiqTickInfo[] memory ticks = protocol.liquidate(abi.encode(FINAL_PRICE));
        vm.stopPrank();

        uint256 liquidatorAfter = wstETH.balanceOf(PUBLIC_LIQUIDATOR);
        assertGt(ticks.length, 0, "60s retry must liquidate at least one tick");
        assertLt(protocol.getTotalLongPositions(), positionsBefore, "60s retry must commit progress");
        assertGt(liquidatorAfter, liquidatorBefore, "60s retry must pay reward");
        assertLe(protocol.getBalanceLong(), protocol.getTotalExpo(), "60s success must preserve long/expo invariant");
    }

    function _characterize(uint256 shift) internal {
        _pinPrestate();
        uint256 positionsBefore = protocol.getTotalLongPositions();
        uint256 expoBefore = protocol.getTotalExpo();
        uint256 longBefore = protocol.getBalanceLong();
        int24 highestBefore = protocol.getHighestPopulatedTick();
        uint256 liquidatorBefore = wstETH.balanceOf(PUBLIC_LIQUIDATOR);

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
