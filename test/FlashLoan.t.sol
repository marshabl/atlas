// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "forge-std/Test.sol";

import { ERC20 } from "solmate/tokens/ERC20.sol";
import { TxBuilder } from "src/contracts/helpers/TxBuilder.sol";
import { BaseTest } from "./base/BaseTest.t.sol";
import { ArbitrageTest } from "./base/ArbitrageTest.t.sol";
import { SolverBase } from "src/contracts/solver/SolverBase.sol";
import { DAppControl } from "src/contracts/dapp/DAppControl.sol";
import { CallConfig } from "src/contracts/types/DAppApprovalTypes.sol";
import { SolverOutcome } from "src/contracts/types/EscrowTypes.sol";
import { UserOperation } from "src/contracts/types/UserCallTypes.sol";
import { SolverOperation } from "src/contracts/types/SolverCallTypes.sol";
import { DAppOperation } from "src/contracts/types/DAppApprovalTypes.sol";
import { FastLaneErrorsEvents } from "src/contracts/types/Emissions.sol";
import { IEscrow } from "src/contracts/interfaces/IEscrow.sol";
import { UserOperationBuilder } from "./base/builders/UserOperationBuilder.sol";
import { SolverOperationBuilder } from "./base/builders/SolverOperationBuilder.sol";
import { DAppOperationBuilder } from "./base/builders/DAppOperationBuilder.sol";

interface IWETH {
    function withdraw(uint256 wad) external;
}

contract FlashLoanTest is BaseTest {
    DummyDAppControlBuilder public controller;

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

        controller = new DummyDAppControlBuilder(address(escrow), WETH_ADDRESS);
        atlasVerification.initializeGovernance(address(controller));
        vm.stopPrank();
    }

    function testFlashLoan() public {
        vm.startPrank(solverOneEOA);
        SimpleSolver solver = new SimpleSolver(WETH_ADDRESS, escrow);
        deal(WETH_ADDRESS, address(solver), 1e18); // 1 WETH to solver to pay bid
        atlas.bond(1 ether); // gas for solver to pay
        vm.stopPrank();

        vm.startPrank(userEOA);
        deal(userEOA, 100e18); // eth to solver for atleth deposit
        atlas.deposit{ value: 100e18 }();
        vm.stopPrank();

        // Input params for Atlas.metacall() - will be populated below

        UserOperation memory userOp = new UserOperationBuilder()
            .withFrom(userEOA)
            .withTo(address(atlas))
            .withGas(1_000_000)
            .withMaxFeePerGas(tx.gasprice + 1)
            .withNonce(address(atlasVerification))
            .withDapp(address(controller))
            .withControl(address(controller))
            .withDeadline(block.number + 2)
            .withData(new bytes(0))
            .build();

        SolverOperation[] memory solverOps = new SolverOperation[](1);
        solverOps[0] = new SolverOperationBuilder()
            .withFrom(solverOneEOA)
            .withTo(address(atlas))
            .withGas(1_000_000)
            .withMaxFeePerGas(userOp.maxFeePerGas)
            .withDeadline(userOp.deadline)
            .withSolver(address(solver))
            .withControl(address(controller))
            .withUserOpHash(userOp)
            .withBidToken(userOp)
            .withBidAmount(1e18)
            .withData(abi.encodeWithSelector(SimpleSolver.noPayback.selector))
            .withValue(10e18)
            .sign(address(atlasVerification), solverOnePK)
            .build();

        // Solver signs the solverOp
        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Frontend creates dAppOp calldata after seeing rest of data
        DAppOperation memory dAppOp = new DAppOperationBuilder()
            .withFrom(governanceEOA)
            .withTo(address(atlas))
            .withGas(2_000_000)
            .withMaxFeePerGas(userOp.maxFeePerGas)
            .withNonce(address(atlasVerification), governanceEOA)
            .withDeadline(userOp.deadline)
            .withControl(address(controller))
            .withUserOpHash(userOp)
            .withCallChainHash(userOp, solverOps)
            .sign(address(atlasVerification), governancePK)
            .build();

        // Frontend signs the dAppOp payload
        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // make the actual atlas call that should revert
        vm.startPrank(userEOA);
        vm.expectEmit(true, true, true, true);
        uint256 result = (1 << uint256(SolverOutcome.BidNotPaid)) | (1 << uint256(SolverOutcome.ExecutionCompleted));
        emit FastLaneErrorsEvents.SolverTxResult(address(solver), solverOneEOA, true, false, result);
        vm.expectRevert();
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp });
        vm.stopPrank();

        // now try it again with a valid solverOp - but dont fully pay back
        solverOps[0] = new SolverOperationBuilder()
            .withFrom(solverOneEOA)
            .withTo(address(atlas))
            .withGas(1_000_000)
            .withMaxFeePerGas(userOp.maxFeePerGas)
            .withDeadline(userOp.deadline)
            .withSolver(address(solver))
            .withControl(address(controller))
            .withUserOpHash(userOp)
            .withBidToken(userOp)
            .withBidAmount(1e18)
            .withData(abi.encodeWithSelector(SimpleSolver.onlyPayBid.selector, 1e18))
            .withValue(10e18)
            .sign(address(atlasVerification), solverOnePK)
            .build();

        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        dAppOp = new DAppOperationBuilder()
            .withFrom(governanceEOA)
            .withTo(address(atlas))
            .withGas(2_000_000)
            .withMaxFeePerGas(userOp.maxFeePerGas)
            .withNonce(address(atlasVerification), governanceEOA)
            .withDeadline(userOp.deadline)
            .withControl(address(controller))
            .withUserOpHash(userOp)
            .withCallChainHash(userOp, solverOps)
            .sign(address(atlasVerification), governancePK)
            .build();
            
        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Call again with partial payback, should still revert
        vm.startPrank(userEOA);
        vm.expectEmit(true, true, true, true);
        result = (1 << uint256(SolverOutcome.CallValueTooHigh)) | (1 << uint256(SolverOutcome.ExecutionCompleted));
        emit FastLaneErrorsEvents.SolverTxResult(address(solver), solverOneEOA, true, false, result);
        vm.expectRevert();
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp });
        vm.stopPrank();

        // final try, should be successful with full payback
        solverOps[0] = new SolverOperationBuilder()
            .withFrom(solverOneEOA)
            .withTo(address(atlas))
            .withGas(1_000_000)
            .withMaxFeePerGas(userOp.maxFeePerGas)
            .withDeadline(userOp.deadline)
            .withSolver(address(solver))
            .withControl(address(controller))
            .withUserOpHash(userOp)
            .withBidToken(userOp)
            .withBidAmount(1e18)
            .withData(abi.encodeWithSelector(SimpleSolver.payback.selector, 1e18))
            .withValue(10e18)
            .sign(address(atlasVerification), solverOnePK)
            .build();

        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlasVerification.getSolverPayload(solverOps[0]));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        dAppOp = new DAppOperationBuilder()
            .withFrom(governanceEOA)
            .withTo(address(atlas))
            .withGas(2_000_000)
            .withMaxFeePerGas(userOp.maxFeePerGas)
            .withNonce(address(atlasVerification), governanceEOA)
            .withDeadline(userOp.deadline)
            .withControl(address(controller))
            .withUserOpHash(userOp)
            .withCallChainHash(userOp, solverOps)
            .sign(address(atlasVerification), governancePK)
            .build();

        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlasVerification.getDAppOperationPayload(dAppOp));
        dAppOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        uint256 solverStartingWETH = WETH.balanceOf(address(solver));
        uint256 atlasStartingETH = address(atlas).balance;
        uint256 userStartingETH = address(userEOA).balance;

        assertEq(solverStartingWETH, 1e18, "solver incorrect starting WETH");
        assertEq(atlasStartingETH, 102e18, "atlas incorrect starting ETH"); // 2e initial + 1e solver + 100e user deposit

        // Last call - should succeed
        vm.startPrank(userEOA);
        result = (1 << uint256(SolverOutcome.Success)) | (1 << uint256(SolverOutcome.ExecutionCompleted));
        vm.expectEmit(true, true, true, true);
        emit FastLaneErrorsEvents.SolverTxResult(address(solver), solverOneEOA, true, true, result);
        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp });
        vm.stopPrank();

        uint256 solverEndingWETH = WETH.balanceOf(address(solver));
        uint256 atlasEndingETH = address(atlas).balance;
        uint256 userEndingETH = address(userEOA).balance;

        console.log("solverWETH", solverStartingWETH, solverEndingWETH);
        console.log("atlasETH", atlasStartingETH, atlasEndingETH);
        console.log("userETH", userStartingETH, userEndingETH);

        assertEq(solverEndingWETH, 0, "solver WETH not used");
        assertEq(atlasEndingETH - atlasStartingETH, 999424451125000000, "atlas incorrect ending ETH"); // atlas should receive bid

    }
}

contract DummyDAppControlBuilder is DAppControl {
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
                delegateUser: true,
                preSolver: false,
                postSolver: false,
                requirePostOps: false,
                zeroSolvers: false,
                reuseUserOp: false,
                userAuctioneer: true,
                solverAuctioneer: true,
                unknownAuctioneer: true,
                verifyCallChainHash: true,
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
    address escrow;

    constructor(address _weth, address _escrow) {
        weth = _weth;
        escrow = _escrow;
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

        if (bytes4(solverOpData[:4]) == SimpleSolver.payback.selector) {
            uint256 shortfall = IEscrow(escrow).shortfall();

            if (shortfall < msg.value) shortfall = 0;
            else shortfall -= msg.value;

            IEscrow(escrow).reconcile{ value: msg.value }(msg.sender, sender, shortfall);
        }
    }

    function noPayback() external payable {
        address(0).call{ value: msg.value }(""); // do something with the eth and dont pay it back
    }

    function onlyPayBid(uint256 bidAmount) external payable {
        IWETH(weth).withdraw(bidAmount);
        payable(msgSender).transfer(bidAmount); // pay back to atlas
        address(0).call{ value: msg.value }(""); // do something with the remaining eth
    }

    function payback(uint256 bidAmount) external payable {
        IWETH(weth).withdraw(bidAmount);
        payable(msgSender).transfer(bidAmount); // pay back to atlas
    }

    receive() external payable { }
}
