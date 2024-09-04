// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

contract Tags {
    string private _name;
    string private _symbol;
    uint256 private _totalTags;
    bool private _revokable;
    bool private _transferable;
    address private _owner;

    mapping(address => bool) private _tags;

    event Tagged(address indexed user);
    event TagRevoked(address indexed user);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);

    constructor(string memory name_, string memory symbol_, bool revokable_, bool transferable_, address owner_) {
        _name = name_;
        _symbol = symbol_;
        _revokable = revokable_;
        _transferable = transferable_;
        _owner = owner_;
    }

    modifier onlyOwner() {
        require(msg.sender == _owner, "Tags: Only the contract owner can perform this action");
        _;
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function totalTags() public view returns (uint256) {
        return _totalTags;
    }

    function revokable() public view returns (bool) {
        return _revokable;
    }

    function transferable() public view returns (bool) {
        return _transferable;
    }

    function owner() public view returns (address) {
        return _owner;
    }

    function setOwner(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Tags: New owner is the zero address");
        emit OwnerChanged(_owner, newOwner);
        _owner = newOwner;
    }

    function isTagged(address user) public view returns (bool) {
        return _tags[user];
    }

    function tag(address user) public onlyOwner {
        require(!_tags[user], "Tags: User is already tagged");
        _tags[user] = true;
        _totalTags += 1;
        emit Tagged(user);
    }

    function revoke(address user) public onlyOwner {
        require(_revokable, "Tags: Tagging is not revokable");
        require(_tags[user], "Tags: User is not tagged");
        _tags[user] = false;
        _totalTags -= 1;
        emit TagRevoked(user);
    }

    function transfer(address to) public {
        require(_transferable, "Tags: Transferring is not allowed");
        require(_tags[msg.sender], "Tags: Caller is not tagged");
        require(!_tags[to], "Tags: Recipient is already tagged");

        _tags[to] = true;
        _tags[msg.sender] = false;
    }
}
