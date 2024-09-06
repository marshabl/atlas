// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";

import { BaseTest } from "test/base/BaseTest.t.sol";
import { TxBuilder } from "src/contracts/helpers/TxBuilder.sol";
import { UserOperationBuilder } from "test/base/builders/UserOperationBuilder.sol";

import { SolverOperation } from "src/contracts/types/SolverOperation.sol";
import { UserOperation } from "src/contracts/types/UserOperation.sol";
import { DAppConfig } from "src/contracts/types/ConfigTypes.sol";
import "src/contracts/types/DAppOperation.sol";

import { V2FactoryJurisdictionDAppControl } from "src/contracts/examples/jurisdiction-tags/V2FactoryJurisdictionDAppControl.sol";
import { IUniswapV2Router01, IUniswapV2Router02 } from "src/contracts/examples/v2-example-router/interfaces/IUniswapV2Router.sol";
import { IUniswapV2Factory } from "src/contracts/examples/jurisdiction-tags/interfaces/IUniswapV2Factory.sol";

import { SolverBase } from "src/contracts/solver/SolverBase.sol";

contract V2FactoryJurisdictionDAppControlTest is BaseTest {

    struct Sig {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    IERC20 DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20 DONG = IERC20(0x3709A4C208768A344A06ddDbeD7209076B2D814B);
    address DAI_ADDRESS = address(DAI);
    address DONG_ADDRESS = address(DONG);
    address V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f; // Uniswap V2 factory address

    V2FactoryJurisdictionDAppControl jurisdictionDApp;
    TxBuilder txBuilder;
    Sig sig;

    BasicV2Solver basicV2Solver;

    function setUp() public override {
        super.setUp();

        // Deploy a new forked Uniswap V2 Factory
        vm.startPrank(governanceEOA);

        jurisdictionDApp = new V2FactoryJurisdictionDAppControl(
            address(atlas),
            WETH_ADDRESS,
            V2_FACTORY,
            "United States of America",
            "USA",
            true,
            false
        );
        atlasVerification.initializeGovernance(address(jurisdictionDApp));
        vm.stopPrank();

        txBuilder = new TxBuilder({
            _control: address(jurisdictionDApp),
            _atlas: address(atlas),
            _verification: address(atlasVerification)
        });
    }

    function test_UserCreatesLiquidityPair() public {
        // Ensure that the execution environment is tagged when it's created
        vm.startPrank(userEOA);
        address executionEnvironment = atlas.createExecutionEnvironment(userEOA, address(jurisdictionDApp));
        console.log("atlas: ", address(atlas));
        console.log("execution environment: ", address(executionEnvironment));
        console.log("dapp: ", address(jurisdictionDApp));
        console.log("user: ", userEOA);
        console.log("gov: ", governanceEOA);
        vm.stopPrank();

        vm.startPrank(address(jurisdictionDApp));

        // Need to tag every user once they make their EE
        jurisdictionDApp.tag(address(executionEnvironment));

        // Retrieve the factory address
        address factoryAddress = V2_FACTORY;

        vm.stopPrank();

        UserOperation memory userOp;
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        DAppOperation memory dAppOp;

        // USER OPERATION FOR PAIR CREATION
        bytes memory userOpData = abi.encodeCall(IUniswapV2Factory.createPair, (
            DONG_ADDRESS,
            DAI_ADDRESS
        ));

        userOp = txBuilder.buildUserOperation({
            from: userEOA,
            to: address(jurisdictionDApp),
            maxFeePerGas: tx.gasprice + 1,
            value: 0,
            deadline: block.number + 555, // block deadline
            data: userOpData
        });

        // Assign factory as the destination for the user operation
        userOp.dapp = V2_FACTORY;
        userOp.sessionKey = governanceEOA;

        // User signs UserOperation data
        (sig.v, sig.r, sig.s) = vm.sign(userPK, atlasVerification.getUserOperationPayload(userOp));
        userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // SOLVER AND METACALL STUFF
        dAppOp = txBuilder.buildDAppOperation(governanceEOA, userOp, solverOps);

        // DApp Gov bonds AtlETH to pay gas in event of no solver
        deal(governanceEOA, 2e18);
        vm.startPrank(governanceEOA);
        atlas.deposit{ value: 1e18 }();
        atlas.bond(1e18);

        address pairAddressBefore = IUniswapV2Factory(factoryAddress).getPair(DONG_ADDRESS, DAI_ADDRESS);

        console.log("\nBEFORE METACALL");
        console.log("PairAddress before metacall", pairAddressBefore);

        atlas.metacall({ userOp: userOp, solverOps: solverOps, dAppOp: dAppOp });

        address pairAddressAfter = IUniswapV2Factory(factoryAddress).getPair(DONG_ADDRESS, DAI_ADDRESS);

        console.log("\nAFTER METACALL");
        console.log("PairAddress after metacall", pairAddressAfter);

        vm.startPrank(address(jurisdictionDApp));

        // Tag this pool as okay to use
        jurisdictionDApp.tag(address(pairAddressAfter));

        // Verify that the pair was created and tagged
        assertTrue(jurisdictionDApp.isTagged(pairAddressAfter), "Pair should be tagged with USA jurisdiction");
    }
}



contract BasicV2Solver is SolverBase {
    constructor(address weth, address atlas) SolverBase(weth, atlas, msg.sender) { }

    function backrun() public onlySelf {
        // Backrun logic would go here
    }

    // This ensures a function can only be called through atlasSolverCall
    // which includes security checks to work safely with Atlas
    modifier onlySelf() {
        require(msg.sender == address(this), "Not called via atlasSolverCall");
        _;
    }

    fallback() external payable { }
    receive() external payable { }
}
