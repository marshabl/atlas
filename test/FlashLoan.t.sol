// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "forge-std/Test.sol";

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { TxBuilder } from "../src/contracts/helpers/TxBuilder.sol";
import { BaseTest } from "./base/BaseTest.t.sol";
import { ArbitrageTest } from "./base/ArbitrageTest.t.sol";
import { SolverBase } from "../src/contracts/solver/SolverBase.sol";
import { DAppControl } from "../src/contracts/dapp/DAppControl.sol";
import { CallConfig } from "../src/contracts/types/DAppApprovalTypes.sol";
import { UserOperation } from "../src/contracts/types/UserCallTypes.sol";
import { SolverOperation } from "../src/contracts/types/SolverCallTypes.sol";
import { DAppOperation } from "../src/contracts/types/DAppApprovalTypes.sol";
import { FastLaneErrorsEvents } from "../src/contracts/types/Emissions.sol";

interface IWETH {
    function withdraw(uint256 wad) external;
}

contract FlashLoanTest is BaseTest {
    DummyController public controller;
    TxBuilder public txBuilder;

    struct Sig {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    Sig public sig;

    function setUp() public virtual override {
        BaseTest.setUp();

        // Creating new gov address (ERR-V49 OwnerActive if already registered with controller)
        governancePK = 11_112;
        governanceEOA = vm.addr(governancePK);

        // Deploy
        vm.startPrank(governanceEOA);

        controller = new DummyController(address(escrow), WETH_ADDRESS);
        atlasVerification.initializeGovernance(address(controller));
        atlasVerification.integrateDApp(address(controller));

        txBuilder = new TxBuilder({
            controller: address(controller),
            atlasAddress: address(atlas),
            _verification: address(atlasVerification)
        });

        vm.stopPrank();
    }

    function testFlashLoan() public {

        vm.startPrank(solverOneEOA);
        SimpleSolver solver = new SimpleSolver(WETH_ADDRESS);
        deal(WETH_ADDRESS, address(solver), 1e18); // 1 WETH to solver to pay bid
        atlas.deposit{ value: 1e18 }(); // gas for solver to pay
        vm.stopPrank();

        vm.startPrank(userEOA);
        deal(userEOA, 100e18); // eth to solver for atleth deposit
        atlas.deposit{ value: 100e18 }();
        vm.stopPrank();

        // Input params for Atlas.metacall() - will be populated below

        vm.startPrank(userEOA);
        address executionEnvironment = atlas.createExecutionEnvironment(txBuilder.control());
        console.log("executionEnvironment a", executionEnvironment);
        vm.stopPrank();
        vm.label(address(executionEnvironment), "EXECUTION ENV");

        UserOperation memory userOp = txBuilder.buildUserOperation({
            from: userEOA, // NOTE: Would from ever not be user?
            to: address(controller),
            maxFeePerGas: tx.gasprice + 1, // TODO update
            value: 0,
            deadline: block.number + 2,
            data: new bytes(0)
        });

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: abi.encodeWithSelector(SimpleSolver.noPayback.selector),
            solverEOA: solverOneEOA,
            solverContract: address(solver),
            bidAmount: 1e18,
            value: 10e18
        });

        // Solver signs the solverOp
        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Frontend creates dAppOp calldata after seeing rest of data
        DAppOperation memory dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);

        // Frontend signs the dAppOp payload
        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // make the actual atlas call that should revert
        vm.startPrank(userEOA);
        vm.expectEmit(true, true, true, true);
        emit FastLaneErrorsEvents.SolverTxResult(address(solver), solverOneEOA, true, false, 1_048_578);
        vm.expectRevert();
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp });
        vm.stopPrank();

        // now try it again with a valid solverOp - but dont fully pay back
        solverOps[0] = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: abi.encodeWithSelector(SimpleSolver.onlyPayBid.selector, 1e18),
            solverEOA: solverOneEOA,
            solverContract: address(solver),
            bidAmount: 1e18,
            value: 10e18
        });

        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);
        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Call again with partial payback, should still revert
        vm.startPrank(userEOA);
        vm.expectEmit(true, true, true, true);
        emit FastLaneErrorsEvents.SolverTxResult(address(solver), solverOneEOA, true, false, 1_048_578);
        vm.expectRevert();
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp });
        vm.stopPrank();

        // final try, should be successful with full payback
        solverOps[0] = txBuilder.buildSolverOperation({
            userOp: userOp,
            solverOpData: abi.encodeWithSelector(SimpleSolver.payback.selector, 1e18),
            solverEOA: solverOneEOA,
            solverContract: address(solver),
            bidAmount: 1e18,
            value: 10e18
        });

        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);
        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Last call - should succeed
        vm.startPrank(userEOA);
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp });
        vm.stopPrank();
    }
}

contract DummyController is DAppControl {
    address immutable weth;

    constructor(
        address _escrow,
        address _weth
    )
        DAppControl(
            _escrow,
            msg.sender,
            CallConfig({
                sequenced: false,
                requirePreOps: false,
                trackPreOpsReturnData: false,
                trackUserReturnData: false,
                localUser: false,
                delegateUser: true,
                preSolver: false,
                postSolver: false,
                requirePostOps: false,
                zeroSolvers: false,
                reuseUserOp: false,
                userBundler: true,
                solverBundler: true,
                verifySolverBundlerCallChainHash: true,
                unknownBundler: true,
                forwardReturnData: false,
                requireFulfillment: true
            })
        )
    {
        weth = _weth;
    }

    function _allocateValueCall(address, uint256, bytes calldata) internal override { }

    function getBidFormat(UserOperation calldata) public view override returns (address bidToken) {
        bidToken = address(0);
    }

    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }

    fallback() external { }
}

contract SimpleSolver {
    address weth;
    address msgSender;

    constructor(address _weth) {
        weth = _weth;
    }

    function atlasSolverCall(
        address sender,
        address bidToken,
        uint256 bidAmount,
        bytes calldata solverOpData,
        bytes calldata extraReturnData
    )
        external
        payable
        returns (bool success, bytes memory data)
    {
        msgSender = msg.sender;
        (success, data) = address(this).call{ value: msg.value }(solverOpData);
    }

    function noPayback() external payable {
        address(0).call{ value: msg.value }(""); // do something with the eth and dont pay it back
    }

    function onlyPayBid(uint256 bidAmount) external payable {
        IWETH(weth).withdraw(bidAmount);
        payable(msgSender).transfer(bidAmount); // pay back to atlas
    }
    
    function payback(uint256 bidAmount) external payable {
        IWETH(weth).withdraw(bidAmount);
        payable(msgSender).transfer(msg.value + bidAmount); // pay back to atlas
    }

    receive() external payable {}
}
