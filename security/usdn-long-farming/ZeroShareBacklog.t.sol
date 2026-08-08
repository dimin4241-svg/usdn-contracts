// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { IUsdnProtocolTypes } from "@smardex-usdn-contracts/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

import { USER_1 } from "../../test/utils/Constants.sol";
import { UsdnLongFarmingBaseFixture } from "./utils/Fixtures.sol";

/**
 * @notice Security regression probe for the zero-share -> first returning farmer transition.
 * @dev This file is copied by CI into the exact upstream usdn-long-farming repository and compiled there.
 */
contract TestUsdnLongFarmingZeroShareBacklog is UsdnLongFarmingBaseFixture {
    int24 internal constant FIRST_TICK = 1234;
    uint256 internal constant FIRST_VERSION = 123;
    uint256 internal constant FIRST_INDEX = 12;

    int24 internal constant RETURN_TICK = 2234;
    uint256 internal constant RETURN_VERSION = 456;
    uint256 internal constant RETURN_INDEX = 34;

    uint256 internal rewardsPerBlock;

    function setUp() public {
        _setUp();
        rewardsPerBlock = rewardsProvider.getRewardsPerBlock();
    }

    function _setMockPosition(uint256 version, address owner) internal {
        IUsdnProtocolTypes.Position memory position = IUsdnProtocolTypes.Position({
            validated: true,
            timestamp: uint40(block.timestamp),
            user: owner,
            totalExpo: 20,
            amount: 10
        });
        usdnProtocol.setPosition(position, version, false);
    }

    function _deposit(int24 tick, uint256 version, uint256 index) internal {
        usdnProtocol.transferPositionOwnership(
            IUsdnProtocolTypes.PositionId(tick, version, index), address(farming), ""
        );
    }

    /// @dev Put the farming contract through a real active -> liquidated -> zero-share transition.
    function _reachZeroSharesAfterRealFarmer() internal {
        _setMockPosition(FIRST_VERSION, address(this));
        _deposit(FIRST_TICK, FIRST_VERSION, FIRST_INDEX);
        assertEq(farming.getTotalShares(), 10, "first farmer shares");

        // Accrue and settle a normal active farming period first.
        vm.roll(block.number + 10);
        IUsdnProtocolTypes.Position memory firstPosition = IUsdnProtocolTypes.Position({
            validated: true,
            timestamp: uint40(block.timestamp),
            user: address(farming),
            totalExpo: 20,
            amount: 10
        });
        usdnProtocol.setPosition(firstPosition, FIRST_VERSION, true);

        vm.prank(USER_1);
        (bool liquidated,) = farming.harvest(FIRST_TICK, FIRST_VERSION, FIRST_INDEX);
        assertTrue(liquidated, "first position must be slashed");
        assertEq(farming.getTotalShares(), 0, "all wrapper shares must be gone");
        assertEq(farming.getPositionsCount(), 0, "no wrapper positions must remain");
        assertEq(rewardsProvider.pendingReward(0, address(farming)), 0, "provider backlog must be settled at zero start");
    }

    /**
     * @notice After a genuine zero-share interval, the first returning position is immediately credited with rewards
     *         accumulated before it entered the LongFarming contract.
     */
    function test_A_firstReturningFarmerImmediatelyOwnsIdleBacklog() public {
        _reachZeroSharesAfterRealFarmer();

        vm.roll(block.number + 100);
        uint256 idleBacklog = rewardsProvider.pendingReward(0, address(farming));
        assertEq(idleBacklog, 100 * rewardsPerBlock, "idle provider emissions");
        assertEq(farming.getTotalShares(), 0, "wrapper must still have no farmers during idle period");

        _setMockPosition(RETURN_VERSION, address(this));
        _deposit(RETURN_TICK, RETURN_VERSION, RETURN_INDEX);

        assertEq(farming.getTotalShares(), 10, "returning farmer shares");
        assertEq(
            rewardsProvider.pendingReward(0, address(farming)),
            idleBacklog,
            "deposit must not harvest provider backlog while wrapper totalShares was zero"
        );

        uint256 creditedImmediately = farming.pendingRewards(RETURN_TICK, RETURN_VERSION, RETURN_INDEX);
        assertEq(
            creditedImmediately,
            idleBacklog,
            "first returning farmer is credited with emissions from before its deposit"
        );
    }

    /**
     * @notice On the next block the first returning farmer can actually withdraw the entire idle backlog plus only one
     *         block of legitimately post-entry emissions.
     */
    function test_B_firstReturningFarmerHarvestsIdleBacklog() public {
        _reachZeroSharesAfterRealFarmer();

        vm.roll(block.number + 100);
        uint256 idleBacklog = rewardsProvider.pendingReward(0, address(farming));
        assertEq(idleBacklog, 100 * rewardsPerBlock, "idle provider emissions");

        _setMockPosition(RETURN_VERSION, address(this));
        _deposit(RETURN_TICK, RETURN_VERSION, RETURN_INDEX);

        uint256 ownerBalanceBefore = rewardToken.balanceOf(address(this));
        vm.roll(block.number + 1);

        uint256 providerPendingAtHarvest = rewardsProvider.pendingReward(0, address(farming));
        assertEq(providerPendingAtHarvest, idleBacklog + rewardsPerBlock, "idle backlog plus one post-entry block");

        vm.prank(USER_1);
        (bool liquidated, uint256 rewards) = farming.harvest(RETURN_TICK, RETURN_VERSION, RETURN_INDEX);
        assertFalse(liquidated, "returning position must remain active");

        uint256 ownerReceived = rewardToken.balanceOf(address(this)) - ownerBalanceBefore;
        assertEq(rewards, providerPendingAtHarvest, "harvest return value");
        assertEq(ownerReceived, providerPendingAtHarvest, "owner must receive provider backlog");
        assertEq(
            ownerReceived - rewardsPerBlock,
            idleBacklog,
            "all pre-entry idle emissions are captured by the first returning farmer"
        );
    }

    /**
     * @notice Diagnostic control: if the provider backlog is synchronized before the returning farmer enters, the
     *         farmer receives only emissions accrued after entry.
     * @dev The vm.prank is intentionally a diagnostic control, not an attacker capability.
     */
    function test_C_clearingProviderBacklogBeforeEntryRemovesWindfall() public {
        _reachZeroSharesAfterRealFarmer();

        vm.roll(block.number + 100);
        uint256 idleBacklog = rewardsProvider.pendingReward(0, address(farming));
        assertGt(idleBacklog, 0, "idle backlog precondition");

        uint256[] memory campaigns = new uint256[](1);
        campaigns[0] = 0;
        vm.prank(address(farming));
        rewardsProvider.harvest(campaigns);
        assertEq(rewardsProvider.pendingReward(0, address(farming)), 0, "diagnostic provider sync");

        _setMockPosition(RETURN_VERSION, address(this));
        _deposit(RETURN_TICK, RETURN_VERSION, RETURN_INDEX);

        uint256 ownerBalanceBefore = rewardToken.balanceOf(address(this));
        vm.roll(block.number + 1);
        vm.prank(USER_1);
        (, uint256 rewards) = farming.harvest(RETURN_TICK, RETURN_VERSION, RETURN_INDEX);

        uint256 ownerReceived = rewardToken.balanceOf(address(this)) - ownerBalanceBefore;
        assertEq(rewards, rewardsPerBlock, "only post-entry reward should be allocated after sync");
        assertEq(ownerReceived, rewardsPerBlock, "no idle windfall after provider sync");
    }
}
