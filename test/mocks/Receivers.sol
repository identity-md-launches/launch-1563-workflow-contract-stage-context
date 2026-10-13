// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CatWars} from "../../src/CatWars.sol";

contract TestReceiver {
    CatWars public immutable game;
    uint256 public roundId;
    bool public reject;
    bool public exhaustGas;
    bool public reenter;
    bool public reentered;

    constructor(CatWars game_) {
        game = game_;
    }

    function configure(bool reject_, bool exhaustGas_, bool reenter_) external {
        reject = reject_;
        exhaustGas = exhaustGas_;
        reenter = reenter_;
    }

    function bet(uint256 id, uint8 side) external payable {
        roundId = id;
        game.placeBet{value: msg.value}(id, side);
    }

    function request(uint256 id) external payable {
        roundId = id;
        game.requestResult{value: msg.value}(id);
    }

    function withdraw() external {
        game.withdraw();
    }

    receive() external payable {
        require(!reject, "receiver rejects ETH");
        if (exhaustGas) {
            assembly {
                invalid()
            }
        }
        if (reenter) {
            (bool claimOk,) = address(game).call(abi.encodeCall(game.claim, (roundId)));
            (bool withdrawOk,) = address(game).call(abi.encodeCall(game.withdraw, ()));
            reentered = claimOk || withdrawOk;
        }
    }
}
