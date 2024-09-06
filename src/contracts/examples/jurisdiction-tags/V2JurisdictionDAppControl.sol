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
import { IUniswapV2Router01, IUniswapV2Router02 } from "./interfaces/IUniswapV2Router.sol";
import { IUniswapV2Factory } from "./interfaces/IUniswapV2Factory.sol";

//Tags
import "./Tags.sol";

/*
* @title V2JurisdictionDAppControl
* @notice This contract is a Jurisdiction based Uniswap v2 "backrun" module that rewards users with an arbitrary ERC20 token (or ETH) for
    MEV generating swaps conducted on a UniswapV2Router02. And checks to ensure only tagged users and pools are used.
* @notice Frontends can easily offer gasless swaps to users selling ERC20 tokens (users would need to approve Atlas to
    spend their tokens first). For ETH swaps, the user would need to bundle their own operation.
* @notice The reward token can be ETH (address(0)) or any ERC20 token. Solvers are required to pay their bid with that
    token. 
*/
contract V2JurisdictionDAppControl is DAppControl, Tags {
    address public immutable REWARD_TOKEN;
    address public immutable uniswapV2Router02;

    mapping(bytes4 => bool) public ERC20StartingSelectors;
    mapping(bytes4 => bool) public ETHStartingSelectors;
    mapping(bytes4 => bool) public exactINSelectors;

    event TokensRewarded(address indexed user, address indexed token, uint256 amount);

    constructor(
        address _atlas,
        address _rewardToken,
        address _uniswapV2Router02,
        string memory _tagName,
        string memory _tagSymbol,
        bool _revokable,
        bool _transferable,
        // address _owner,
        bool _allowFeeOnTransferTokens
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
        uniswapV2Router02 = _uniswapV2Router02;

        ERC20StartingSelectors[bytes4(IUniswapV2Router01.swapExactTokensForTokens.selector)] = true;
        ERC20StartingSelectors[bytes4(IUniswapV2Router01.swapTokensForExactTokens.selector)] = true;
        ERC20StartingSelectors[bytes4(IUniswapV2Router01.swapTokensForExactETH.selector)] = true;
        ERC20StartingSelectors[bytes4(IUniswapV2Router01.swapExactTokensForETH.selector)] = true;
        ERC20StartingSelectors[bytes4(IUniswapV2Router02.swapExactTokensForTokensSupportingFeeOnTransferTokens.selector)]
        = _allowFeeOnTransferTokens;
        ERC20StartingSelectors[bytes4(IUniswapV2Router02.swapExactTokensForETHSupportingFeeOnTransferTokens.selector)] =
            _allowFeeOnTransferTokens;

        ETHStartingSelectors[bytes4(IUniswapV2Router01.swapExactETHForTokens.selector)] = true;
        ETHStartingSelectors[bytes4(IUniswapV2Router01.swapETHForExactTokens.selector)] = true;
        ETHStartingSelectors[bytes4(IUniswapV2Router02.swapExactETHForTokensSupportingFeeOnTransferTokens.selector)] =
            _allowFeeOnTransferTokens;

        exactINSelectors[bytes4(IUniswapV2Router01.swapExactTokensForTokens.selector)] = true;
        exactINSelectors[bytes4(IUniswapV2Router01.swapExactTokensForETH.selector)] = true;
        exactINSelectors[bytes4(IUniswapV2Router02.swapExactTokensForTokensSupportingFeeOnTransferTokens.selector)] =
            _allowFeeOnTransferTokens;
        exactINSelectors[bytes4(IUniswapV2Router02.swapExactTokensForETHSupportingFeeOnTransferTokens.selector)] = _allowFeeOnTransferTokens;
        exactINSelectors[bytes4(IUniswapV2Router01.swapExactETHForTokens.selector)] = true;
        exactINSelectors[bytes4(IUniswapV2Router02.swapExactETHForTokensSupportingFeeOnTransferTokens.selector)] = _allowFeeOnTransferTokens; 
    }

    // ---------------------------------------------------- //
    //                       Custom                         //
    // ---------------------------------------------------- //

    /**
    * @notice This function inspects the user's call data to determine the tokens involved in the swap and the amount sold.
    * @param userData The user's call data.
    * @return tokenSold The address of the ERC20 token the user is selling (or address(0) for ETH).
    * @return tokenBought The address of the ERC20 token the user is buying.
    * @return amountSold The amount of the token sold.
    */
    function getSwapDetails(bytes calldata userData) external view returns (address tokenSold, address tokenBought, uint256 amountSold) {
        bytes4 funcSelector = bytes4(userData);

        // User is only allowed to call swap functions
        require(
            ERC20StartingSelectors[funcSelector] || ETHStartingSelectors[funcSelector],
            "V2RewardDAppControl: InvalidFunction"
        );

        if (ERC20StartingSelectors[funcSelector] || ETHStartingSelectors[funcSelector]) {
            address[] memory path;

            if (exactINSelectors[funcSelector]) {
                // Exact amount sold
                (amountSold,, path,,) = abi.decode(userData[4:], (uint256, uint256, address[], address, uint256));
            } else {
                // Max amount sold, unused amount will be refunded in the _postOpsCall hook if any
                (, amountSold, path,,) = abi.decode(userData[4:], (uint256, uint256, address[], address, uint256));
            }

            // Set tokenSold and tokenBought based on the path
            require(path.length >= 2, "V2RewardDAppControl: Invalid swap path");
            tokenSold = path[0];
            tokenBought = path[1];
        }
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
        // User is only allowed to call UniswapV2Router02
        require(userOp.dapp == uniswapV2Router02, "V2RewardDAppControl: InvalidDestination");
    }

    /*
    * @notice This function is called before the user's call to UniswapV2Router02 to make sure a user is tagged and pair is tagged
    * @dev This function is delegatecalled: msg.sender = Atlas, address(this) = ExecutionEnvironment
    * @dev If the user is selling an ERC20 token, the function transfers the tokens from the user to the
        ExecutionEnvironment and approves UniswapV2Router02 to spend the tokens from the ExecutionEnvironment
    * @param userOp The UserOperation struct
    * @return The address of the ERC20 token the user is selling (or address(0) for ETH), which is used in the
        _postOpsCall hook to refund leftover dust, if any
    */
    function _preOpsCall(UserOperation calldata userOp) internal override returns (bytes memory) {
        // Check if the user (execution environment) is tagged with JurisdictionTag
        require(V2JurisdictionDAppControl(userOp.control).isTagged(address(this)), "V2JurisdictionDAppControl: user (execution environment) must get tagged first");

        // The current hook is delegatecalled, so we need to call the userOp.control to access the mappings
        (address tokenSold, address tokenBought, uint256 amountSold) = V2JurisdictionDAppControl(userOp.control).getSwapDetails(userOp.data);

        // Get the Uniswap V2 Pair address for the tokens being sold and bought
        address pair = IUniswapV2Factory(IUniswapV2Router02(uniswapV2Router02).factory()).getPair(tokenSold, tokenBought);

        // Check that the Uniswap V2 Pair is tagged with JurisdictionTag
        require(V2JurisdictionDAppControl(userOp.control).isTagged(pair), "V2JurisdictionDAppControl: Uniswap V2 pair is not tagged with correct jurisdiction");

        // Pull the tokens from the user and approve UniswapV2Router02 to spend them
        _getAndApproveUserERC20(tokenSold, amountSold, uniswapV2Router02);

        // Return tokenSold for the _postOpsCall hook to be able to refund dust
        return abi.encode(tokenSold);
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
        require(bidToken == REWARD_TOKEN, "V2RewardDAppControl: InvalidBidToken");

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
        address tokenSold = abi.decode(data, (address));
        uint256 balance;

        // Refund ETH/ERC20 dust if any
        if (tokenSold == address(0)) {
            balance = address(this).balance;
            if (balance > 0) {
                SafeTransferLib.safeTransferETH(_user(), balance);
            }
        } else {
            balance = IERC20(tokenSold).balanceOf(address(this));
            if (balance > 0) {
                SafeTransferLib.safeTransfer(tokenSold, _user(), balance);
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
