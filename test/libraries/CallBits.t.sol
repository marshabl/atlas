// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import "forge-std/Test.sol";

import { CallBits } from "../../src/contracts/libraries/CallBits.sol";
import "../../src/contracts/types/UserCallTypes.sol";
import "../base/TestUtils.sol";

contract CallBitsTest is Test {
    using CallBits for uint32;

    CallConfig callConfig1;
    CallConfig callConfig2;

    function setUp() public {
        callConfig1 = CallConfig({
            sequenced: true,
            requirePreOps: false,
            trackPreOpsReturnData: true,
            trackUserReturnData: false,
            delegateUser: true,
            localUser: false,
            preSolver: true,
            postSolver: false,
            requirePostOps: true,
            zeroSolvers: false,
            reuseUserOp: true,
            userAuctioneer: false,
            solverAuctioneer: true,
            unknownAuctioneer: false,
            verifyCallChainHash: true,
            forwardReturnData: false,
            requireFulfillment: true
        });

        callConfig2 = CallConfig({
            sequenced: !callConfig1.sequenced,
            requirePreOps: !callConfig1.requirePreOps,
            trackPreOpsReturnData: !callConfig1.trackPreOpsReturnData,
            trackUserReturnData: !callConfig1.trackUserReturnData,
            delegateUser: !callConfig1.delegateUser,
            localUser: !callConfig1.localUser,
            preSolver: !callConfig1.preSolver,
            postSolver: !callConfig1.postSolver,
            requirePostOps: !callConfig1.requirePostOps,
            zeroSolvers: !callConfig1.zeroSolvers,
            reuseUserOp: !callConfig1.reuseUserOp,
            userAuctioneer: !callConfig1.userAuctioneer,
            solverAuctioneer: !callConfig1.solverAuctioneer,
            unknownAuctioneer: !callConfig1.unknownAuctioneer,
            verifyCallChainHash: !callConfig1.verifyCallChainHash,
            forwardReturnData: !callConfig1.forwardReturnData,
            requireFulfillment: !callConfig1.requireFulfillment
        });
    }

    function testEncodeCallConfig() public {
        string memory expectedBitMapString = "00000000000000010101010101010101";
        assertEq(
            TestUtils.uint32ToBinaryString(CallBits.encodeCallConfig(callConfig1)),
            expectedBitMapString,
            "callConfig1 incorrect"
        );

        expectedBitMapString = "00000000000000001010101010101010";
        assertEq(
            TestUtils.uint32ToBinaryString(CallBits.encodeCallConfig(callConfig2)),
            expectedBitMapString,
            "callConfig2 incorrect"
        );
    }

    function testDecodeCallConfig() public {
        uint32 encodedCallConfig = CallBits.encodeCallConfig(callConfig1);
        CallConfig memory decodedCallConfig = encodedCallConfig.decodeCallConfig();
        assertEq(decodedCallConfig.sequenced, true, "sequenced 1 incorrect");
        assertEq(decodedCallConfig.requirePreOps, false, "requirePreOps 1 incorrect");
        assertEq(decodedCallConfig.trackPreOpsReturnData, true, "trackPreOpsReturnData 1 incorrect");
        assertEq(decodedCallConfig.trackUserReturnData, false, "trackUserReturnData 1 incorrect");
        assertEq(decodedCallConfig.delegateUser, true, "delegateUser 1 incorrect");
        assertEq(decodedCallConfig.localUser, false, "localUser 1 incorrect");
        assertEq(decodedCallConfig.preSolver, true, "preSolver 1 incorrect");
        assertEq(decodedCallConfig.postSolver, false, "postSolver 1 incorrect");
        assertEq(decodedCallConfig.requirePostOps, true, "requirePostOps 1 incorrect");
        assertEq(decodedCallConfig.zeroSolvers, false, "zeroSolvers 1 incorrect");
        assertEq(decodedCallConfig.reuseUserOp, true, "reuseUserOp 1 incorrect");
        assertEq(decodedCallConfig.userAuctioneer, false, "userAuctioneer 1 incorrect");
        assertEq(decodedCallConfig.solverAuctioneer, true, "solverAuctioneer 1 incorrect");
        assertEq(decodedCallConfig.unknownAuctioneer, false, "unknownAuctioneer 1 incorrect");
        assertEq(decodedCallConfig.verifyCallChainHash, true, "verifyCallChainHash 1 incorrect");
        assertEq(decodedCallConfig.forwardReturnData, false, "forwardPreOpsReturnData 1 incorrect");
        assertEq(decodedCallConfig.requireFulfillment, true, "requireFulfillment 1 incorrect");

        encodedCallConfig = CallBits.encodeCallConfig(callConfig2);
        decodedCallConfig = encodedCallConfig.decodeCallConfig();
        assertEq(decodedCallConfig.sequenced, false, "sequenced 2 incorrect");
        assertEq(decodedCallConfig.requirePreOps, true, "requirePreOps 2 incorrect");
        assertEq(decodedCallConfig.trackPreOpsReturnData, false, "trackPreOpsReturnData 2 incorrect");
        assertEq(decodedCallConfig.trackUserReturnData, true, "trackUserReturnData 2 incorrect");
        assertEq(decodedCallConfig.delegateUser, false, "delegateUser 2 incorrect");
        assertEq(decodedCallConfig.localUser, true, "localUser 2 incorrect");
        assertEq(decodedCallConfig.preSolver, false, "preSolver 2 incorrect");
        assertEq(decodedCallConfig.postSolver, true, "postSolver 2 incorrect");
        assertEq(decodedCallConfig.requirePostOps, false, "requirePostOps 2 incorrect");
        assertEq(decodedCallConfig.zeroSolvers, true, "zeroSolvers 2 incorrect");
        assertEq(decodedCallConfig.reuseUserOp, false, "reuseUserOp 2 incorrect");
        assertEq(decodedCallConfig.userAuctioneer, true, "userAuctioneer 2 incorrect");
        assertEq(decodedCallConfig.solverAuctioneer, false, "solverAuctioneer 2 incorrect");
        assertEq(decodedCallConfig.unknownAuctioneer, true, "unknownAuctioneer 2 incorrect");
        assertEq(decodedCallConfig.verifyCallChainHash, false, "verifyCallChainHash 2 incorrect");
        assertEq(decodedCallConfig.forwardReturnData, true, "forwardPreOpsReturnData 2 incorrect");
        assertEq(decodedCallConfig.requireFulfillment, false, "requireFulfillment 2 incorrect");
    }

    function testConfigParameters() public {
        uint32 encodedCallConfig = CallBits.encodeCallConfig(callConfig1);
        assertEq(encodedCallConfig.needsSequencedNonces(), true, "needsSequencedNonces 1 incorrect");
        assertEq(encodedCallConfig.needsPreOpsCall(), false, "needsPreOpsCall 1 incorrect");
        assertEq(encodedCallConfig.needsPreOpsReturnData(), true, "needsPreOpsReturnData 1 incorrect");
        assertEq(encodedCallConfig.needsUserReturnData(), false, "needsUserReturnData 1 incorrect");
        assertEq(encodedCallConfig.needsDelegateUser(), true, "needsDelegateUser 1 incorrect");
        assertEq(encodedCallConfig.needsLocalUser(), false, "needsLocalUser 1 incorrect");
        assertEq(encodedCallConfig.needsPreSolver(), true, "needsPreSolver 1 incorrect");
        assertEq(encodedCallConfig.needsSolverPostCall(), false, "needsSolverPostCall 1 incorrect");
        assertEq(encodedCallConfig.needsPostOpsCall(), true, "needsPostOpsCall 1 incorrect");
        assertEq(encodedCallConfig.allowsZeroSolvers(), false, "allowsZeroSolvers 1 incorrect");
        assertEq(encodedCallConfig.allowsReuseUserOps(), true, "allowsReuseUserOps 1 incorrect");
        assertEq(encodedCallConfig.allowsUserAuctioneer(), false, "allowsUserAuctioneer 1 incorrect");
        assertEq(encodedCallConfig.allowsSolverAuctioneer(), true, "allowsSolverAuctioneer 1 incorrect");
        assertEq(encodedCallConfig.allowsUnknownAuctioneer(), false, "allowsUnknownAuctioneer 1 incorrect");
        assertEq(encodedCallConfig.verifyCallChainHash(), true, "verifyCallChainHash 1 incorrect");
        assertEq(encodedCallConfig.forwardReturnData(), false, "forwardPreOpsReturnData 1 incorrect");
        assertEq(encodedCallConfig.needsFulfillment(), true, "needsFulfillment 1 incorrect");
        encodedCallConfig = CallBits.encodeCallConfig(callConfig2);
        assertEq(encodedCallConfig.needsSequencedNonces(), false, "needsSequencedNonces 2 incorrect");
        assertEq(encodedCallConfig.needsPreOpsCall(), true, "needsPreOpsCall 2 incorrect");
        assertEq(encodedCallConfig.needsPreOpsReturnData(), false, "needsPreOpsReturnData 2 incorrect");
        assertEq(encodedCallConfig.needsUserReturnData(), true, "needsUserReturnData 2 incorrect");
        assertEq(encodedCallConfig.needsDelegateUser(), false, "needsDelegateUser 2 incorrect");
        assertEq(encodedCallConfig.needsLocalUser(), true, "needsLocalUser 2 incorrect");
        assertEq(encodedCallConfig.needsPreSolver(), false, "needsPreSolver 2 incorrect");
        assertEq(encodedCallConfig.needsSolverPostCall(), true, "needsSolverPostCall 2 incorrect");
        assertEq(encodedCallConfig.needsPostOpsCall(), false, "needsPostOpsCall 2 incorrect");
        assertEq(encodedCallConfig.allowsZeroSolvers(), true, "allowsZeroSolvers 2 incorrect");
        assertEq(encodedCallConfig.allowsReuseUserOps(), false, "allowsReuseUserOps 2 incorrect");
        assertEq(encodedCallConfig.allowsUserAuctioneer(), true, "allowsUserAuctioneer 2 incorrect");
        assertEq(encodedCallConfig.allowsSolverAuctioneer(), false, "allowsSolverAuctioneer 2 incorrect");
        assertEq(encodedCallConfig.allowsUnknownAuctioneer(), true, "allowsUnknownAuctioneer 2 incorrect");
        assertEq(encodedCallConfig.verifyCallChainHash(), false, "verifyCallChainHash 2 incorrect");
        assertEq(encodedCallConfig.forwardReturnData(), true, "forwardPreOpsReturnData 2 incorrect");
        assertEq(encodedCallConfig.needsFulfillment(), false, "needsFulfillment 2 incorrect");
    }
}
