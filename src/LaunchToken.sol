// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The launch token is independent of the native-ETH game.
contract LaunchToken is ERC20 {
    constructor() ERC20("CAT WARS", "MEOW") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
