//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import "forge-std/console.sol";

// Base Imports
import { SafeTransferLib } from "solady/utils/SafeTransferLib.sol";
import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

// Atlas Imports
import { DAppControl } from "src/contracts/dapp/DAppControl.sol";
import { CallConfig } from "src/contracts/types/ConfigTypes.sol";
import "src/contracts/types/UserOperation.sol";
import "src/contracts/types/SolverOperation.sol";

// Uniswap Imports
import { IUniswapV2Factory } from "./interfaces/IUniswapV2Factory.sol";
import { IUniswapV2Pair } from "./interfaces/IUniswapV2Pair.sol";

//Tags
import "./Tags.sol";

/*
* @title V2JurisdictionDAppControlFactory
* @notice This contract manages liquidity pairs using the Uniswap V2 Factory. It works with Atlas for MEV-related operations.
* @notice The contract interacts with the Uniswap V2 Factory to manage liquidity pairs, tag operations, and bid rewards.
*/
contract V2JurisdictionDAppControlFactory is DAppControl, Tags {
    address public immutable REWARD_TOKEN;
    address public immutable uniswapV2Factory;

    mapping(bytes4 => bool) public pairCreationSelectors;

    event LiquidityPairCreated(address indexed token0, address indexed token1, address pair);
    event TokensRewarded(address indexed user, address indexed token, uint256 amount);

    constructor(
        address _atlas,
        address _rewardToken,
        address _uniswapV2Factory,
        string memory _tagName,
        string memory _tagSymbol,
        bool _revokable,
        bool _transferable
    )
        DAppControl(
            _atlas,
            msg.sender,
            CallConfig({
                userNoncesSequential: false,
                dappNoncesSequential: false,
                requirePreOps: true,
                trackPreOpsReturnData: true,
                trackUserReturnData: false,
                delegateUser: false,
                requirePreSolver: false,
                requirePostSolver: false,
                requirePostOps: true,
                zeroSolvers: true,
                reuseUserOp: false,
                userAuctioneer: true,
                solverAuctioneer: false,
                unknownAuctioneer: true,
                verifyCallChainHash: true,
                forwardReturnData: false,
                requireFulfillment: false,
                trustedOpHash: true,
                invertBidValue: false,
                exPostBids: true,
                allowAllocateValueFailure: false
            })
        )
        Tags(_tagName, _tagSymbol, _revokable, _transferable, address(this)) // Initializing Tags contract
    {
        REWARD_TOKEN = _rewardToken;
        uniswapV2Factory = _uniswapV2Factory;

        pairCreationSelectors[bytes4(IUniswapV2Factory.createPair.selector)] = true;
    }

    // ---------------------------------------------------- //
    //                       Custom                         //
    // ---------------------------------------------------- //

    /**
    * @notice This function inspects the user's call data to determine the tokens involved in liquidity pair creation.
    * @param userData The user's call data.
    * @return token0 The address of the first token in the pair.
    * @return token1 The address of the second token in the pair.
    */
    function getPairDetails(bytes calldata userData) external view returns (address token0, address token1) {
        bytes4 funcSelector = bytes4(userData);

        // User is only allowed to call createPair function
        require(
            pairCreationSelectors[funcSelector],
            "V2JurisdictionDAppControlFactory: InvalidFunction"
        );

        // Decode the user data to extract token addresses
        (token0, token1) = abi.decode(userData[4:], (address, address));

        require(token0 != address(0) && token1 != address(0), "V2JurisdictionDAppControlFactory: Invalid tokens");
    }

    // ---------------------------------------------------- //
    //                     Atlas hooks                      //
    // ---------------------------------------------------- //

    /*
    * @notice This function checks the user operation and ensures that the user (execution environment)
    * is tagged with the JurisdictionTag. If the user is not tagged, tag them.
    * @param userOp The UserOperation struct containing the user's transaction data.
    */
    function _checkUserOperation(UserOperation memory userOp) internal view override {
        // User is only allowed to call UniswapV2Factory
        require(userOp.dapp == uniswapV2Factory, "V2JurisdictionDAppControlFactory: InvalidDestination");
    }

    /*
    * @notice This function is called before the user's call to UniswapV2Factory to create a pair.
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev If the user is creating a pair, ensure the pair is tagged and allowed.
    * @param userOp The UserOperation struct
    * @return The token addresses involved in the pair creation.
    */
    function _preOpsCall(UserOperation calldata userOp) internal override returns (bytes memory) {
        // Check if the user (execution environment) is tagged with JurisdictionTag
        require(V2JurisdictionDAppControlFactory(userOp.control).isTagged(address(this)), "V2JurisdictionDAppControlFactory: user must get tagged first");

        // Extract the pair details
        (address token0, address token1) = V2JurisdictionDAppControlFactory(userOp.control).getPairDetails(userOp.data);

        // Create the pair
        address pair = IUniswapV2Factory(uniswapV2Factory).createPair(token0, token1);

        // Check that the pair is tagged with JurisdictionTag
        require(V2JurisdictionDAppControlFactory(userOp.control).isTagged(pair), "V2JurisdictionDAppControlFactory: Uniswap V2 pair is not tagged with correct jurisdiction");

        // Return the pair for any future hooks
        return abi.encode(pair);
    }

    /*
    * @notice This function is called after a solver has successfully paid their bid
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev It simply transfers the reward token to the user (solvers are required to pay their bid with the reward
        token, so we don't have any more steps to take here)
    * @param bidToken The address of the token used for the winning SolverOperation's bid
    * @param bidAmount The winning bid amount
    * @param _
    */
    function _allocateValueCall(address bidToken, uint256 bidAmount, bytes calldata) internal override {
        require(bidToken == REWARD_TOKEN, "V2JurisdictionDAppControlFactory: InvalidBidToken");

        address user = _user();

        if (bidToken == address(0)) {
            SafeTransferLib.safeTransferETH(user, bidAmount);
        } else {
            SafeTransferLib.safeTransfer(REWARD_TOKEN, user, bidAmount);
        }

        emit TokensRewarded(user, REWARD_TOKEN, bidAmount);
    }

    /*
    * @notice This function is called as the last phase of a `metacall` transaction
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev It refunds any leftover dust (ETH/ERC20) to the user (this can occur when the user is calling an exactOUT
        function and the amount sold is less than the amountInMax)
    * @param data The address of the ERC20 token the user is selling (or address(0) for ETH), that was returned by the
        _preOpsCall hook
    */
    function _postOpsCall(bool, bytes calldata data) internal override {
        address token = abi.decode(data, (address));
        uint256 balance;

        // Refund ETH/ERC20 dust if any
        if (token == address(0)) {
            balance = address(this).balance;
            if (balance > 0) {
                SafeTransferLib.safeTransferETH(_user(), balance);
            }
        } else {
            balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                SafeTransferLib.safeTransfer(token, _user(), balance);
            }
        }
    }

    // ---------------------------------------------------- //
    //                 Getters and helpers                  //
    // ---------------------------------------------------- //

    function getBidFormat(UserOperation calldata) public view override returns (address bidToken) {
        return REWARD_TOKEN;
    }

    function getBidValue(SolverOperation calldata solverOp) public pure override returns (uint256) {
        return solverOp.bidAmount;
    }
}
