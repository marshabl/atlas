//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import { AtlETH } from "./AtlETH.sol";

import { IExecutionEnvironment } from "src/contracts/interfaces/IExecutionEnvironment.sol";
import { IAtlas } from "src/contracts/interfaces/IAtlas.sol";
import { ISolverContract } from "src/contracts/interfaces/ISolverContract.sol";
import { IAtlasVerification } from "src/contracts/interfaces/IAtlasVerification.sol";
import { IDAppControl } from "../interfaces/IDAppControl.sol";

import { EscrowBits } from "src/contracts/libraries/EscrowBits.sol";
import { CallBits } from "src/contracts/libraries/CallBits.sol";
import { SafetyBits } from "src/contracts/libraries/SafetyBits.sol";
import { DAppConfig } from "src/contracts/types/DAppApprovalTypes.sol";
import "src/contracts/types/SolverCallTypes.sol";
import "src/contracts/types/UserCallTypes.sol";
import "src/contracts/types/EscrowTypes.sol";
import "src/contracts/types/LockTypes.sol";

/// @title Escrow
/// @author FastLane Labs
/// @notice This Escrow component of Atlas handles execution of stages by calling corresponding functions on the
/// Execution Environment contract.
abstract contract Escrow is AtlETH {
    using EscrowBits for uint256;
    using CallBits for uint32;
    using SafetyBits for Context;

    constructor(
        uint256 _escrowDuration,
        address _verification,
        address _simulator,
        address _surchargeRecipient
    )
        AtlETH(_escrowDuration, _verification, _simulator, _surchargeRecipient)
    { }

    /// @notice Executes the preOps logic defined in the Execution Environment.
    /// @param ctx Metacall context data from the Context struct.
    /// @param dConfig Configuration data for the DApp involved, containing execution parameters and settings.
    /// @param userOp UserOperation struct of the current metacall tx.
    /// @return preOpsData The data returned by the preOps call, if successful.
    function _executePreOpsCall(
        Context memory ctx,
        DAppConfig calldata dConfig,
        UserOperation calldata userOp
    )
        internal
        withLockPhase(ExecutionPhase.PreOps)
        returns (Context memory, bytes memory)
    {
        (bool success, bytes memory data) = ctx.executionEnvironment.call(
            abi.encodePacked(
                abi.encodeCall(IExecutionEnvironment.preOpsWrapper, userOp), ctx.setAndPack(ExecutionPhase.PreOps, true)
            )
        );

        if (success) {
            if (dConfig.callConfig.needsPreOpsReturnData()) {
                return (ctx, abi.decode(data, (bytes)));
            } else {
                return (ctx, new bytes(0));
            }
        } else {
            if (ctx.isSimulation) revert PreOpsSimFail();
            revert PreOpsFail();
        }
    }

    /// @notice Executes the user operation logic defined in the Execution Environment.
    /// @param ctx Metacall context data from the Context struct.
    /// @param dConfig Configuration data for the DApp involved, containing execution parameters and settings.
    /// @param userOp UserOperation struct containing the user's transaction data.
    /// @return userData Data returned from executing the UserOperation, if the call was successful.
    function _executeUserOperation(
        Context memory ctx,
        DAppConfig calldata dConfig,
        UserOperation calldata userOp,
        bytes memory returnData
    )
        internal
        withLockPhase(ExecutionPhase.UserOperation)
        returns (Context memory, bytes memory)
    {
        (bool success, bytes memory data) = ctx.executionEnvironment.call{ value: userOp.value }(
            abi.encodePacked(
                abi.encodeCall(IExecutionEnvironment.userWrapper, userOp),
                ctx.setAndPack(ExecutionPhase.UserOperation, true)
            )
        );

        if (success) {
            // Handle formatting of returnData
            if (dConfig.callConfig.needsUserReturnData()) {
                return (ctx, abi.decode(data, (bytes)));
            } else {
                return (ctx, returnData);
            }
        } else {
            if (ctx.isSimulation) revert UserOpSimFail();
            revert UserOpFail();
        }
    }

    /// @notice Attempts to execute a SolverOperation and determine if it wins the auction.
    /// @param ctx Context struct containing the current state of the escrow lock.
    /// @param dConfig Configuration data for the DApp involved, containing execution parameters and settings.
    /// @param userOp UserOperation struct containing the user's transaction data relevant to this SolverOperation.
    /// @param solverOp SolverOperation struct containing the solver's bid and execution data.
    /// @param bidAmount The amount of bid submitted by the solver for this operation.
    /// @param prevalidated Boolean flag indicating whether the SolverOperation has been prevalidated to skip certain
    /// @param returnData Data returned from UserOp execution, used as input if necessary.
    /// checks for efficiency.
    /// @return ctx Updated Context struct, reflecting the new state after attempting the SolverOperation.
    /// @return bidAmount The determined bid amount for the SolverOperation if all validations pass and the operation is
    /// executed successfully; otherwise, returns 0.
    function _executeSolverOperation(
        Context memory ctx,
        DAppConfig calldata dConfig,
        UserOperation calldata userOp,
        SolverOperation calldata solverOp,
        uint256 bidAmount,
        bool prevalidated,
        bytes memory returnData
    )
        internal
        returns (Context memory, uint256)
    {
        // Set the gas baseline
        uint256 gasWaterMark = gasleft();
        uint256 result;
        if (!prevalidated) {
            result = IAtlasVerification(VERIFICATION).verifySolverOp(
                solverOp, ctx.userOpHash, userOp.maxFeePerGas, ctx.bundler
            );
            result = _checkSolverBidToken(solverOp.bidToken, dConfig.bidToken, result);
        }

        // Increment the call index once per solverOp
        unchecked {
            ++ctx.callIndex;
        }

        // Verify the transaction.
        if (result.canExecute()) {
            uint256 gasLimit;
            // Verify gasLimit again
            (result, gasLimit) = _validateSolverOperation(dConfig, solverOp, gasWaterMark);

            if (dConfig.callConfig.allowsTrustedOpHash()) {
                if (!prevalidated && !_handleAltOpHash(userOp, solverOp)) {
                    ctx.solverOutcome = uint24(result);
                    return (ctx, 0);
                }
            }

            // If there are no errors, attempt to execute
            if (result.canExecute()) {
                SolverTracker memory solverTracker;

                // Execute the solver call
                // _solverOpsWrapper returns a SolverOutcome enum value
                (result, solverTracker) = _solverOpWrapper(ctx, solverOp, bidAmount, gasLimit, returnData);

                if (result.executionSuccessful()) {
                    // first successful solver call that paid what it bid

                    emit SolverTxResult(solverOp.solver, solverOp.from, true, true, result);

                    ctx.solverSuccessful = true;
                    ctx.solverOutcome = uint24(result);
                    return (ctx, solverTracker.bidAmount); // auctionWon = true
                }
            }
        }

        ctx.solverOutcome = uint24(result);

        _releaseSolverLock(solverOp, gasWaterMark, result, false, !prevalidated);

        // emit event
        emit SolverTxResult(solverOp.solver, solverOp.from, result.executedWithError(), false, result);

        // auctionWon = false
        return (ctx, 0);
    }

    function _preSolverOpInner(
        Context calldata ctx,
        SolverOperation calldata solverOp,
        uint256 bidAmount,
        bytes calldata returnData
    )
        internal
        withLockPhase(ExecutionPhase.PreSolver)
        returns (SolverTracker memory solverTracker)
    {
        (bool success, bytes memory data) = ctx.executionEnvironment.call(
            abi.encodePacked(
                abi.encodeCall(IExecutionEnvironment.solverPreTryCatch, (bidAmount, solverOp, returnData)),
                ctx.setAndPack(ExecutionPhase.PreSolver, false)
            )
        );

        // If ExecutionEnvironment.solverPreTryCatch() failed, bubble up the error
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }

        // Update solverTracker with returned data
        return abi.decode(data, (SolverTracker));
    }

    function _solverOpInner(
        Context calldata ctx,
        SolverOperation calldata solverOp,
        uint256 bidAmount,
        uint256 gasLimit,
        bytes calldata returnData
    )
        internal
        withLockPhase(ExecutionPhase.SolverOperations)
    {
        // Set the solver lock - will perform accounting checks if value borrowed. If `_trySolverLock()` returns false,
        // we revert here and catch the error in `_solverOpWrapper()` above
        if (!_trySolverLock(solverOp)) revert InsufficientEscrow();

        (bool success,) = solverOp.solver.call{ value: solverOp.value, gas: gasLimit }(
            abi.encodeCall(
                ISolverContract.atlasSolverCall,
                (solverOp.from, ctx.executionEnvironment, solverOp.bidToken, bidAmount, solverOp.data, returnData)
            )
        );

        if (!success) revert SolverOpReverted();
    }

    function _postSolverOpInner(
        Context calldata ctx,
        SolverOperation calldata solverOp,
        bytes calldata returnData,
        SolverTracker memory solverTracker
    )
        internal
        withLockPhase(ExecutionPhase.PostSolver)
        returns (SolverTracker memory)
    {
        (bool success, bytes memory data) = ctx.executionEnvironment.call(
            abi.encodePacked(
                abi.encodeCall(IExecutionEnvironment.solverPostTryCatch, (solverOp, returnData, solverTracker)),
                ctx.setAndPack(ExecutionPhase.PostSolver, false)
            )
        );

        // If ExecutionEnvironment.solverPostTryCatch() failed, bubble up the error
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }

        // Update solverTracker with returned data
        return abi.decode(data, (SolverTracker));
    }

    /// @notice Allocates the winning bid amount after a successful SolverOperation execution.
    /// @dev This function handles the allocation of the bid amount to the appropriate recipients as defined in the
    /// DApp's configuration. It calls the allocateValue function in the Execution Environment, which is responsible for
    /// distributing the bid amount. Note that balance discrepancies leading to payment failures are typically due to
    /// issues in the DAppControl contract, not the execution environment itself.
    /// @param ctx Context struct containing the current state of the escrow lock.
    /// @param dConfig Configuration data for the DApp involved, containing execution parameters and settings.
    /// @param bidAmount The winning solver's bid amount, to be allocated.
    /// @param returnData Data returned from the execution of the UserOperation, which may influence how the bid amount
    /// is allocated.
    /// @return ctx Updated Context struct, reflecting the new state after attempting the SolverOperation.
    function _allocateValue(
        Context memory ctx,
        DAppConfig calldata dConfig,
        uint256 bidAmount,
        uint256 solverIndex,
        bytes memory returnData
    )
        internal
        withLockPhase(ExecutionPhase.AllocateValue)
        returns (Context memory)
    {
        (bool success,) = ctx.executionEnvironment.call(
            abi.encodePacked(
                abi.encodeCall(IExecutionEnvironment.allocateValue, (dConfig.bidToken, bidAmount, returnData)),
                ctx.setAndPack(ExecutionPhase.AllocateValue, true)
            )
        );

        ctx.paymentsSuccessful = success;
        ctx.callIndex = ctx.callCount - 1;
        ctx.solverOutcome = uint24(solverIndex);

        return ctx;
    }

    /// @notice Executes post-operation logic after SolverOperation, depending on the outcome of the auction.
    /// @dev Calls the postOpsWrapper function in the Execution Environment, which handles any necessary cleanup or
    /// finalization logic after the winning SolverOperation.
    /// @param ctx Context struct containing the current state of the escrow lock.
    /// @param solved Boolean indicating whether a SolverOperation was successful and won the auction.
    /// @param returnData Data returned from execution of the UserOp call, which may be required for the postOps logic.
    /// @return ctx Updated Context struct, reflecting the new state after attempting the SolverOperation.
    function _executePostOpsCall(
        Context memory ctx,
        bool solved,
        bytes memory returnData
    )
        internal
        withLockPhase(ExecutionPhase.PostOps)
        returns (Context memory)
    {
        (bool success,) = ctx.executionEnvironment.call(
            abi.encodePacked(
                abi.encodeCall(IExecutionEnvironment.postOpsWrapper, (solved, returnData)),
                ctx.setAndPack(ExecutionPhase.PostOps, false)
            )
        );

        if (!success) {
            if (ctx.isSimulation) revert PostOpsSimFail();
            revert PostOpsFail();
        }

        return ctx;
    }

    /// @notice Validates a SolverOperation's gas requirements and deadline against the current block and escrow state.
    /// @dev Performs a series of checks to ensure that a SolverOperation can be executed within the defined parameters
    /// and limits. This includes verifying that the operation is within the gas limit, that the current block is before
    /// the operation's deadline, and that the solver has sufficient balance in escrow to cover the gas costs.
    /// @param dConfig DApp configuration data, including solver gas limits and operation parameters.
    /// @param solverOp The SolverOperation being validated.
    /// @param gasWaterMark The initial gas measurement before validation begins, used to ensure enough gas remains for
    /// validation logic.
    /// @return result Updated result flags after performing the validation checks, including any new errors
    /// encountered.
    /// @return gasLimit The calculated gas limit for the SolverOperation, considering the operation's gas usage and
    /// the protocol's gas buffers.
    function _validateSolverOperation(
        DAppConfig calldata dConfig,
        SolverOperation calldata solverOp,
        uint256 gasWaterMark
    )
        internal
        view
        returns (uint256 result, uint256 gasLimit)
    {
        if (gasWaterMark < _VALIDATION_GAS_LIMIT + dConfig.solverGasLimit) {
            // Make sure to leave enough gas for dApp validation calls
            return (1 << uint256(SolverOutcome.UserOutOfGas), gasLimit); // gasLimit = 0
        }

        if (solverOp.deadline != 0 && block.number > solverOp.deadline) {
            return (
                1
                    << uint256(
                        dConfig.callConfig.allowsTrustedOpHash()
                            ? uint256(SolverOutcome.DeadlinePassedAlt)
                            : uint256(SolverOutcome.DeadlinePassed)
                    ),
                gasLimit // gasLimit = 0
            );
        }

        gasLimit = _SOLVER_GAS_LIMIT_SCALE
            * (solverOp.gas < dConfig.solverGasLimit ? solverOp.gas : dConfig.solverGasLimit)
            / (_SOLVER_GAS_LIMIT_SCALE + _SOLVER_GAS_LIMIT_BUFFER_PERCENTAGE) + _FASTLANE_GAS_BUFFER;

        uint256 gasCost = (tx.gasprice * gasLimit) + _getCalldataCost(solverOp.data.length);

        // Verify that we can lend the solver their tx value
        if (solverOp.value > address(this).balance) {
            return (1 << uint256(SolverOutcome.CallValueTooHigh), gasLimit);
        }

        // subtract out the gas buffer since the solver's metaTx won't use it
        gasLimit -= _FASTLANE_GAS_BUFFER;

        EscrowAccountAccessData memory aData = accessData[solverOp.from];

        uint256 solverBalance = aData.bonded;
        uint256 lastAccessedBlock = aData.lastAccessedBlock;

        // NOTE: Turn this into time stamp check for FCFS L2s?
        if (lastAccessedBlock == block.number) {
            result = 1 << uint256(SolverOutcome.PerBlockLimit);
        }

        // see if solver's escrow can afford tx gascost
        if (gasCost > solverBalance) {
            // charge solver for calldata so that we can avoid vampire attacks from solver onto user
            result |= 1 << uint256(SolverOutcome.InsufficientEscrow);
        }

        return (result, gasLimit);
    }

    /// @notice Determines the bid amount for a SolverOperation based on verification and validation results.
    /// @dev This function assesses whether a SolverOperation meets the criteria for execution by verifying it against
    /// the Atlas protocol's rules and the current Context lock state. It checks for valid execution based on the
    /// SolverOperation's specifics, like gas usage and deadlines. The function aims to protect against malicious
    /// bundlers by ensuring solvers are not unfairly charged for on-chain bid finding gas usage. If the operation
    /// passes verification and validation, and if it's eligible for bid amount determination, the function attempts to
    /// execute and determine the bid amount.
    /// @param ctx Context struct containing the current state of the escrow lock.
    /// @param dConfig DApp configuration data, including parameters relevant to solver bid validation.
    /// @param userOp The UserOperation associated with this SolverOperation, providing context for the bid amount
    /// determination.
    /// @param solverOp The SolverOperation being assessed, containing the solver's bid amount.
    /// @param returnData Data returned from execution of the UserOp call, passed to the execution environment's
    /// solverMetaTryCatch function for execution.
    /// @return bidAmount The determined bid amount for the SolverOperation if all validations pass and the operation is
    /// executed successfully; otherwise, returns 0.
    function _getBidAmount(
        Context memory ctx,
        DAppConfig calldata dConfig,
        UserOperation calldata userOp,
        SolverOperation calldata solverOp,
        bytes memory returnData
    )
        internal
        returns (uint256 bidAmount)
    {
        // NOTE: To prevent a malicious bundler from aggressively collecting storage refunds,
        // solvers should not be on the hook for any 'on chain bid finding' gas usage.

        uint256 gasWaterMark = gasleft();

        uint256 result =
            IAtlasVerification(VERIFICATION).verifySolverOp(solverOp, ctx.userOpHash, userOp.maxFeePerGas, ctx.bundler);

        result = _checkSolverBidToken(solverOp.bidToken, dConfig.bidToken, result);

        // Verify the transaction.
        if (!result.canExecute()) return 0;

        uint256 gasLimit;
        (result, gasLimit) = _validateSolverOperation(dConfig, solverOp, gasWaterMark);

        if (dConfig.callConfig.allowsTrustedOpHash()) {
            if (!_handleAltOpHash(userOp, solverOp)) {
                return (0);
            }
        }

        (bool success, bytes memory data) = address(this).call{ gas: gasLimit }(
            abi.encodeCall(IAtlas.solverCall, (ctx, solverOp, solverOp.bidAmount, gasLimit, returnData))
        );

        // The `solverCall()` above should always revert as key.bidFind is always true when it's called in the context
        // of this function. Therefore `success` should always be false below, and the revert should be unreachable.
        if (success) {
            revert Unreachable();
        }

        if (bytes4(data) == BidFindSuccessful.selector) {
            // Get the uint256 from the memory array
            assembly {
                let dataLocation := add(data, 0x20)
                bidAmount :=
                    mload(
                        add(
                            dataLocation,
                            sub(mload(data), 32) // TODO: make sure a full uint256 is safe from overflow
                        )
                    )
            }
            return bidAmount;
        }

        return 0;
    }

    /// @notice Validates UserOp hashes provided by the SolverOperation, using the alternative set of hashed parameters.
    /// @param userOp The UserOperation struct, providing the baseline parameters for comparison.
    /// @param solverOp The SolverOperation struct being validated against the UserOperation.
    /// @return A boolean value indicating whether the SolverOperation passed the alternative hash check, with `true`
    /// meaning it is considered valid
    function _handleAltOpHash(
        UserOperation calldata userOp,
        SolverOperation calldata solverOp
    )
        internal
        returns (bool)
    {
        // These failures should be attributed to bundler maliciousness
        if (userOp.control != solverOp.control) {
            return false;
        }
        if (userOp.deadline != 0 && solverOp.deadline != 0 && solverOp.deadline != userOp.deadline) {
            return false;
        }
        bytes32 hashId = keccak256(abi.encodePacked(solverOp.userOpHash, solverOp.from, solverOp.deadline));
        if (_solverOpHashes[hashId]) {
            return false;
        }
        _solverOpHashes[hashId] = true;
        return true;
    }

    // NOTE: This logic should be inside `verifySolverOp()` in AtlasVerification, but we hit Stack Too Deep errors when
    // trying to do this check there, as an additional param (dConfig.bidToken) is needed. This logic should be moved to
    // that function when a larger refactor is done to get around Stack Too Deep.
    function _checkSolverBidToken(
        address solverBidToken,
        address dConfigBidToken,
        uint256 result
    )
        internal
        pure
        returns (uint256)
    {
        if (solverBidToken != dConfigBidToken) {
            return result | 1 << uint256(SolverOutcome.InvalidBidToken);
        }
        return result;
    }

    /// @notice Wraps the execution of a SolverOperation and handles potential errors.
    /// @param ctx The current lock data.
    /// @param solverOp The SolverOperation struct containing the operation's execution data.
    /// @param bidAmount The bid amount associated with the SolverOperation.
    /// @param gasLimit The gas limit for executing the SolverOperation, calculated based on the operation's
    /// requirements and protocol buffers.
    /// @param returnData Data returned from the execution of the associated UserOperation, which may be required
    /// for the SolverOperation's logic.
    /// @return result SolverOutcome enum value encoded as a uint256 bitmap, representing the result of the
    /// SolverOperation
    /// @return solverTracker Tracking data for the solver's bid
    function _solverOpWrapper(
        Context memory ctx,
        SolverOperation calldata solverOp,
        uint256 bidAmount,
        uint256 gasLimit,
        bytes memory returnData
    )
        internal
        returns (uint256 result, SolverTracker memory solverTracker)
    {
        // Calls the solverCall function, just below this function, which will handle calling solverPreTryCatch and
        // solverPostTryCatch via the ExecutionEnvironment, and in between those two hooks, the actual solver call
        // directly from Atlas to the solver contract (not via the ExecutionEnvironment).
        (bool success, bytes memory data) = address(this).call{ gas: gasLimit }(
            abi.encodeCall(this.solverCall, (ctx, solverOp, bidAmount, gasLimit, returnData))
        );

        if (success) {
            // If solverCall() was successful, intentionally leave result unset as 0 indicates success
            solverTracker = abi.decode(data, (SolverTracker));
        } else {
            // If solverCall() failed, catch the error and encode the failure case in the result uint accordingly.
            bytes4 errorSwitch = bytes4(data);
            if (errorSwitch == AlteredControl.selector) {
                result = 1 << uint256(SolverOutcome.AlteredControl);
            } else if (errorSwitch == InsufficientEscrow.selector) {
                result = 1 << uint256(SolverOutcome.InsufficientEscrow);
            } else if (errorSwitch == PreSolverFailed.selector) {
                result = 1 << uint256(SolverOutcome.PreSolverFailed);
            } else if (errorSwitch == SolverOpReverted.selector) {
                result = 1 << uint256(SolverOutcome.SolverOpReverted);
            } else if (errorSwitch == PostSolverFailed.selector) {
                result = 1 << uint256(SolverOutcome.PostSolverFailed);
            } else if (errorSwitch == BidNotPaid.selector) {
                result = 1 << uint256(SolverOutcome.BidNotPaid);
            } else if (errorSwitch == InvalidSolver.selector) {
                result = 1 << uint256(SolverOutcome.InvalidSolver);
            } else if (errorSwitch == BalanceNotReconciled.selector) {
                result = 1 << uint256(SolverOutcome.BalanceNotReconciled);
            } else if (errorSwitch == CallbackNotCalled.selector) {
                result = 1 << uint256(SolverOutcome.CallbackNotCalled);
            } else if (errorSwitch == InvalidEntry.selector) {
                // DAppControl is attacking solver contract - treat as AlteredControl
                result = 1 << uint256(SolverOutcome.AlteredControl);
            } else {
                result = 1 << uint256(SolverOutcome.EVMError);
            }
        }
    }

    /// @notice Executes the SolverOperation logic, including preSolver and postSolver hooks via the Execution
    /// Environment, as well as the actual solver call directly from Atlas to the solver contract.
    /// @param ctx The Context struct containing lock data and the Execution Environment address.
    /// @param solverOp The SolverOperation to be executed.
    /// @param bidAmount The bid amount associated with the SolverOperation.
    /// @param gasLimit The gas limit for executing the SolverOperation.
    /// @param returnData Data returned from previous call phases.
    /// @return solverTracker Additional data for handling the solver's bid in different scenarios.
    function solverCall(
        Context calldata ctx,
        SolverOperation calldata solverOp,
        uint256 bidAmount,
        uint256 gasLimit,
        bytes calldata returnData
    )
        external
        payable
        returns (SolverTracker memory solverTracker)
    {
        if (msg.sender != address(this)) revert InvalidEntry();

        bool success;
        bool calledback;

        // ------------------------------------- //
        //             Pre-Solver Call           //
        // ------------------------------------- //

        solverTracker = _preSolverOpInner(ctx, solverOp, bidAmount, returnData);

        // ------------------------------------- //
        //              Solver Call              //
        // ------------------------------------- //

        _solverOpInner(ctx, solverOp, bidAmount, gasLimit, returnData);

        // ------------------------------------- //
        //            Post-Solver Call           //
        // ------------------------------------- //

        solverTracker = _postSolverOpInner(ctx, solverOp, returnData, solverTracker);

        // Verify that the solver repaid their borrowed solverOp.value by calling `reconcile()`. If solver did not fully
        // repay via `reconcile()`, the postSolverCall may still have covered the outstanding debt via `contribute()` so
        // we do a final repayment check here.
        (, calledback, success) = _solverLockData();
        if (!calledback) revert CallbackNotCalled();
        if (!success && deposits < claims + withdrawals) revert BalanceNotReconciled();

        // Check if this is an on-chain, ex post bid search
        if (ctx.bidFind) revert BidFindSuccessful(solverTracker.bidAmount);
    }

    receive() external payable { }
}
