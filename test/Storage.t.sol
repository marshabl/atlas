// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import "forge-std/Test.sol";

import { Storage } from "src/contracts/atlas/Storage.sol";
import { BaseTest } from "test/base/BaseTest.t.sol";

contract StorageTest is BaseTest {
    using stdStorage for StdStorage;

    function setUp() public override {
        // Set up the environment
        super.setUp();
    }

    // Public Constants

    function test_storage_publicConstants() public {
        assertEq(address(atlas.VERIFICATION()), address(atlasVerification), "VERIFICATION set incorrectly");
        assertEq(atlas.SIMULATOR(), address(simulator), "SIMULATOR set incorrectly");
        assertEq(atlas.ESCROW_DURATION(), DEFAULT_ESCROW_DURATION, "ESCROW_DURATION set incorrectly");

        assertEq(atlas.name(), "Atlas ETH", "name set incorrectly");
        assertEq(atlas.symbol(), "atlETH", "symbol set incorrectly");
        assertEq(atlas.decimals(), 18, "decimals set incorrectly");

        assertEq(atlas.ATLAS_SURCHARGE_RATE(), DEFAULT_ATLAS_SURCHARGE_RATE, "ATLAS_SURCHARGE_RATE set incorrectly");
        assertEq(atlas.BUNDLER_SURCHARGE_RATE(), DEFAULT_BUNDLER_SURCHARGE_RATE, "BUNDLER_SURCHARGE_RATE set incorrectly");
        assertEq(atlas.SCALE(), DEFAULT_SCALE, "SCALE set incorrectly");
        assertEq(atlas.FIXED_GAS_OFFSET(), DEFAULT_FIXED_GAS_OFFSET, "FIXED_GAS_OFFSET set incorrectly");
    }

    // View Functions for internal storage variables

    function test_storage_view_totalSupply() public {
        uint256 depositAmount = 1e18;
        uint256 startTotalSupply = atlas.totalSupply();

        vm.deal(userEOA, depositAmount);
        vm.prank(userEOA);
        atlas.deposit{value: depositAmount}();

        assertEq(atlas.totalSupply(), startTotalSupply + depositAmount, "totalSupply did not increase correctly");
    }

    function test_storage_view_bondedTotalSupply() public {
        uint256 depositAmount = 1e18;
        assertEq(atlas.bondedTotalSupply(), 0, "bondedTotalSupply set incorrectly");

        vm.deal(userEOA, depositAmount);
        vm.prank(userEOA);
        atlas.depositAndBond{value: depositAmount}(depositAmount);

        assertEq(atlas.bondedTotalSupply(), depositAmount, "bondedTotalSupply did not increase correctly");
    }

    function test_storage_view_accessData() public {
        uint256 depositAmount = 1e18;
        (uint256 bonded, uint256 lastAccessedBlock, uint256 auctionWins, uint256 auctionFails, uint256 totalGasUsed) = atlas.accessData(userEOA);

        assertEq(bonded, 0, "user bonded should start as 0");
        assertEq(lastAccessedBlock, 0, "user lastAccessedBlock should start as 0");
        assertEq(auctionWins, 0, "user auctionWins should start as 0");
        assertEq(auctionFails, 0, "user auctionFails should start as 0");
        assertEq(totalGasUsed, 0, "user totalGasUsed should start as 0");

        vm.deal(userEOA, depositAmount);
        vm.prank(userEOA);
        atlas.depositAndBond{value: depositAmount}(depositAmount);

        (bonded, lastAccessedBlock, auctionWins, auctionFails, totalGasUsed) = atlas.accessData(userEOA);

        assertEq(bonded, depositAmount, "user bonded should be equal to depositAmount");
        assertEq(lastAccessedBlock, 0, "user lastAccessedBlock should still be 0");
        assertEq(auctionWins, 0, "user auctionWins should still be 0");
        assertEq(auctionFails, 0, "user auctionFails should still be 0");
        assertEq(totalGasUsed, 0, "user totalGasUsed should still be 0");

        vm.prank(userEOA);
        atlas.unbond(depositAmount);

        (bonded, lastAccessedBlock, auctionWins, auctionFails, totalGasUsed) = atlas.accessData(userEOA);

        assertEq(bonded, 0, "user bonded should be 0 again");
        assertEq(lastAccessedBlock, block.number, "user lastAccessedBlock should be equal to block.number");
        assertEq(auctionWins, 0, "user auctionWins should still be 0");
        assertEq(auctionFails, 0, "user auctionFails should still be 0");
        assertEq(totalGasUsed, 0, "user totalGasUsed should still be 0");
    }

    function test_storage_view_solverOpHashes() public {
        MockStorage mockStorage = new MockStorage(DEFAULT_ESCROW_DURATION, address(0), address(0), address(0));
        bytes32 testHash = keccak256(abi.encodePacked("test"));
        assertEq(mockStorage.solverOpHashes(testHash), false, "solverOpHashes[testHash] not false");
        mockStorage.setSolverOpHash(testHash);
        assertEq(mockStorage.solverOpHashes(testHash), true, "solverOpHashes[testHash] not true");
    }

    function test_storage_view_cumulativeSurcharge() public {
        MockStorage mockStorage = new MockStorage(DEFAULT_ESCROW_DURATION, address(0), address(0), address(0));
        assertEq(mockStorage.cumulativeSurcharge(), 0, "cumulativeSurcharge not 0");
        mockStorage.setCumulativeSurcharge(100);
        assertEq(mockStorage.cumulativeSurcharge(), 100, "cumulativeSurcharge not 100");
    }

    function test_storage_view_surchargeRecipient() public {
        assertEq(atlas.surchargeRecipient(), payee, "surchargeRecipient set incorrectly");
    }

    function test_storage_view_pendingSurchargeRecipient() public {
        assertEq(atlas.pendingSurchargeRecipient(), address(0), "pendingSurchargeRecipient should start at 0");
        vm.prank(payee);
        atlas.transferSurchargeRecipient(userEOA);
        assertEq(atlas.pendingSurchargeRecipient(), userEOA, "pendingSurchargeRecipient should be userEOA");
    }

    // Transient Storage Getters and Setters





}

// To test solverOpHashes() and cumulativeSurcharge() view function
contract MockStorage is Storage {
    constructor(
        uint256 escrowDuration,
        address verification,
        address simulator,
        address initialSurchargeRecipient
    )
        Storage(escrowDuration, verification, simulator, initialSurchargeRecipient)
    { }

    function setSolverOpHash(bytes32 opHash) public {
        S_solverOpHashes[opHash] = true;
    }

    function setCumulativeSurcharge(uint256 surcharge) public {
        S_cumulativeSurcharge = surcharge;
    }
}