// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CatWars} from "../../src/CatWars.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

contract MockVRFWrapper {
    uint256 public fee = 0.002 ether;
    uint256 public lastRequestId;
    uint256 public requestCount;
    uint256 public totalPaid;
    uint32 public lastGasLimit;
    uint16 public lastConfirmations;
    uint32 public lastNumWords;
    bytes public lastExtraArgs;
    bool public failRequests;
    bool public repriceAfterStatusChange;
    bool public reuseId;
    mapping(uint256 => address) public consumer;

    // Deliberately reverts: construction and native requests must never need LINK.
    function link() external pure returns (address) {
        revert("native-only mock");
    }

    function setFailRequests(bool value) external {
        failRequests = value;
    }

    function setReprice(bool value) external {
        repriceAfterStatusChange = value;
    }

    function setReuseId(bool value) external {
        reuseId = value;
    }

    function calculateRequestPriceNative(uint32 gasLimit, uint32 words) external view returns (uint256) {
        require(gasLimit == 150_000 && words == 1, "bad quote parameters");
        uint256 price = fee + uint256(gasLimit) * tx.gasprice;
        if (repriceAfterStatusChange && CatWars(msg.sender).getRound(0).status == CatWars.Status.Requested) {
            price += 1 ether;
        }
        return price;
    }

    function requestRandomWordsInNative(uint32 gasLimit, uint16 confirmations, uint32 words, bytes calldata extraArgs)
        external
        payable
        returns (uint256 id)
    {
        require(!failRequests, "wrapper unavailable");
        require(gasLimit == 150_000 && confirmations == 3 && words == 1, "bad request parameters");
        require(
            keccak256(extraArgs)
                == keccak256(VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}))),
            "must pay native"
        );
        require(msg.value >= fee, "underpaid");
        lastGasLimit = gasLimit;
        lastConfirmations = confirmations;
        lastNumWords = words;
        lastExtraArgs = extraArgs;
        ++requestCount;
        totalPaid += msg.value;
        id = reuseId ? lastRequestId : ++lastRequestId;
        consumer[id] = msg.sender;
    }

    function fulfill(uint256 id, uint256 word) external {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        CatWars(consumer[id]).rawFulfillRandomWords(id, words);
    }

    function deliver(address game, uint256 id, uint256[] memory words) external {
        CatWars(game).rawFulfillRandomWords(id, words);
    }
}
