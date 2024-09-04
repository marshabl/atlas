// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Script.sol";
import "../src/contracts/examples/jurisdiction-tags/Tags.sol";

contract DeployTags is Script {
    function run() external {
        // Define the parameters for the Tags contract
        string memory name = "My Custom Tags";
        string memory symbol = "TAG";
        bool revokable = true;
        bool transferable = false;
        address owner = msg.sender;  // Use the deployer as the owner

        vm.startBroadcast();

        // Deploy the Tags contract with the specified parameters
        Tags tags = new Tags(name, symbol, revokable, transferable, owner);
        console.log("Tags contract deployed at:", address(tags));

        vm.stopBroadcast();
    }
}