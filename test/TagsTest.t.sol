// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/contracts/examples/jurisdiction-tags/Tags.sol";

contract TagsTest is Test {
    Tags private tags;
    address private owner;
    address private user1 = address(0x1);
    address private user2 = address(0x2);

    function setUp() public {
        // Set the owner address
        owner = address(this);

        // Deploy the Tags contract with the owner address
        tags = new Tags("My Custom Tags", "TAG", true, false, owner);
    }

    function testInitialization() public {
        // Check that the Tags contract is initialized with the correct parameters
        assertEq(tags.name(), "My Custom Tags");
        assertEq(tags.symbol(), "TAG");
        assertTrue(tags.revokable(), "Revokable should be true");
        assertFalse(tags.transferable(), "Transferable should be false");
        assertEq(tags.totalTags(), 0);
        assertEq(tags.owner(), owner, "Owner should be the deployer");
    }

    function testTagging() public {
        // Tag a user
        tags.tag(user1);

        // Verify the user is tagged and totalTags has increased
        assertTrue(tags.isTagged(user1), "User should be tagged");
        assertEq(tags.totalTags(), 1);
    }

    function testRevokingTag() public {
        // Tag a user
        tags.tag(user1);

        // Revoke the tag from the user
        tags.revoke(user1);

        // Verify the user is no longer tagged and totalTags has decreased
        assertFalse(tags.isTagged(user1), "User should be untagged");
        assertEq(tags.totalTags(), 0);
    }

    function testCannotTransferTag() public {
        // Tag a user
        tags.tag(user1);

        // Attempt to transfer the tag should fail
        vm.prank(user1);
        vm.expectRevert("Tags: Transferring is not allowed");
        tags.transfer(user2);
    }

    function testOnlyOwnerCanTag() public {
        // Attempt to tag a user from a non-owner address
        vm.prank(user1);
        vm.expectRevert("Tags: Only the contract owner can perform this action");
        tags.tag(user2);
    }

    function testOnlyOwnerCanRevoke() public {
        // Tag a user from the owner
        tags.tag(user1);

        // Attempt to revoke the tag from a non-owner address
        vm.prank(user1);
        vm.expectRevert("Tags: Only the contract owner can perform this action");
        tags.revoke(user1);
    }

    function testOwnerCanBeChanged() public {
        // Change the owner to user1
        tags.setOwner(user1);

        // Verify the owner has been updated
        assertEq(tags.owner(), user1, "Owner should be updated to user1");

        // Attempt to tag a user from the new owner
        vm.prank(user1);
        tags.tag(user2);

        assertTrue(tags.isTagged(user2), "User2 should be tagged by new owner");
    }

    function testOnlyNewOwnerCanTagAfterChange() public {
        // Change the owner to user1
        tags.setOwner(user1);

        // Attempt to tag a user from the old owner should fail
        vm.expectRevert("Tags: Only the contract owner can perform this action");
        tags.tag(user2);
    }
}