// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CatWars} from "../src/CatWars.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract FactoryProbe {
    function deploy(bytes memory initCode, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(initCode, 32), mload(initCode), salt)
        }
        require(deployed != address(0), "deployment failed");
    }
}

contract DeploymentTest is Test {
    address private constant SEPOLIA_WRAPPER = 0x195f15F2d49d693cE265b4fB0fdDbE15b1850Cc1;
    address private constant LAUNCH_OWNER = 0xcb97592071fa186ED4C8D00DCD1d50F4145C1A80;

    function test_factoryDeploymentOnEmptyChainAndForbiddenOpcodes() public {
        vm.chainId(11155111);
        assertEq(SEPOLIA_WRAPPER.code.length, 0);
        FactoryProbe factory = new FactoryProbe();
        LaunchToken token = LaunchToken(factory.deploy(type(LaunchToken).creationCode, keccak256("token")));
        CatWars game = CatWars(
            factory.deploy(
                abi.encodePacked(type(CatWars).creationCode, abi.encode(SEPOLIA_WRAPPER, LAUNCH_OWNER)),
                keccak256("game")
            )
        );
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(game.owner(), LAUNCH_OWNER);
        assertEq(game.keeper(), LAUNCH_OWNER);
        assertEq(game.treasury(), LAUNCH_OWNER);
        _checkRuntime(address(token));
        _checkRuntime(address(game));
        vm.prank(address(factory));
        vm.expectRevert(CatWars.UnauthorizedKeeper.selector);
        game.openRound(0, 1);
        vm.prank(LAUNCH_OWNER);
        game.openRound(0, 1);
    }

    function _checkRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
