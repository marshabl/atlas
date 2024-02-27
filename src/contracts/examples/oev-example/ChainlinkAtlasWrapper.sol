//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";
import { SafeERC20, IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

// A wrapper contract for a specific Chainlink price feed, used by Atlas to capture Oracle Extractable Value (OEV).
// Each MEV-generating protocol needs their own wrapper for each Chainlink price feed they use.

contract ChainlinkAtlasWrapper is Ownable {
    address public immutable ATLAS;
    IChainlinkFeed public immutable BASE_FEED; // Base Chainlink Feed

    int256 public atlasLatestAnswer;
    uint256 public atlasLatestTimestamp;

    // Trusted ExecutionEnvironments
    mapping(address transmitter => bool trusted) public transmitters;

    error TransmitterNotTrusted(address transmitter);
    error ObservationsNotOrdered();
    error WithdrawETHFailed();

    event TransmitterStatusChanged(address transmitter, bool trusted);

    constructor(address atlas, address baseChainlinkFeed, address _owner) {
        ATLAS = atlas;
        BASE_FEED = IChainlinkFeed(baseChainlinkFeed);
        _transferOwnership(_owner);
    }

    // Called by the contract which creates OEV when reading a price feed update.
    // If Atlas solvers have submitted a more recent answer than the base oracle's most recent answer,
    // the `atlasLatestAnswer` will be returned. Otherwise fallback to the base oracle's answer.
    function latestAnswer() public view returns (int256) {
        if (BASE_FEED.latestTimestamp() >= atlasLatestTimestamp) {
            return BASE_FEED.latestAnswer();
        } else {
            return atlasLatestAnswer;
        }
    }

    // Called by a trusted ExecutionEnvironment during an Atlas metacall
    function transmit(bytes calldata report, bytes32[] calldata rs, bytes32[] calldata ss, bytes32 rawVs) external {
        if (!transmitters[msg.sender]) revert TransmitterNotTrusted(msg.sender);

        int256 answer = _verifyTransmitData(report, rs, ss, rawVs);

        atlasLatestAnswer = answer;
        atlasLatestTimestamp = block.timestamp;
    }

    // Verifies
    function _verifyTransmitData(
        bytes calldata report,
        bytes32[] calldata rs,
        bytes32[] calldata ss,
        bytes32 rawVs
    )
        internal
        pure
        returns (int256)
    {
        // TODO more checks needed OffchainAggregator transmit function logic
        // Need ways to access s_hotVars and s_oracles in the CL ETHUSD contract

        ReportData memory r;
        (,, r.observations) = abi.decode(report, (bytes32, bytes32, int192[]));

        // 1. Check observations are ordered, then take median
        for (uint256 i = 0; i < r.observations.length - 1; ++i) {
            bool inOrder = r.observations[i] <= r.observations[i + 1];
            if (!inOrder) revert ObservationsNotOrdered();
        }
        int192 median = r.observations[r.observations.length / 2];
        return int256(median);
    }

    // ---------------------------------------------------- //
    //                     Owner Functions                  //
    // ---------------------------------------------------- //

    // Owner can add/remove trusted transmitters (ExecutionEnvironments)
    function setTransmitterStatus(address transmitter, bool trusted) external onlyOwner {
        transmitters[transmitter] = trusted;
        emit TransmitterStatusChanged(transmitter, trusted);
    }

    // Withdraw ETH OEV captured via Atlas solver bids
    function withdrawETH(address recipient) external onlyOwner {
        (bool success,) = recipient.call{ value: address(this).balance }("");
        if (!success) revert WithdrawETHFailed();
    }

    // Withdraw ERC20 OEV captured via Atlas solver bids
    function withdrawERC20(address token, address recipient) external onlyOwner {
        SafeERC20.safeTransfer(IERC20(token), recipient, IERC20(token).balanceOf(address(this)));
    }
}

// -----------------------------------------------
// Structs and interface for Chainlink Aggregator
// -----------------------------------------------

struct ReportData {
    HotVars hotVars; // Only read from storage once
    bytes observers; // ith element is the index of the ith observer
    int192[] observations; // ith element is the ith observation
    bytes vs; // jth element is the v component of the jth signature
    bytes32 rawReportContext;
}

struct HotVars {
    // Provides 128 bits of security against 2nd pre-image attacks, but only
    // 64 bits against collisions. This is acceptable, since a malicious owner has
    // easier way of messing up the protocol than to find hash collisions.
    bytes16 latestConfigDigest;
    uint40 latestEpochAndRound; // 32 most sig bits for epoch, 8 least sig bits for round
    // Current bound assumed on number of faulty/dishonest oracles participating
    // in the protocol, this value is referred to as f in the design
    uint8 threshold;
    // Chainlink Aggregators expose a roundId to consumers. The offchain reporting
    // protocol does not use this id anywhere. We increment it whenever a new
    // transmission is made to provide callers with contiguous ids for successive
    // reports.
    uint32 latestAggregatorRoundId;
}

interface IChainlinkFeed {
    function latestAnswer() external view returns (int256);
    function latestTimestamp() external view returns (uint256);
}
