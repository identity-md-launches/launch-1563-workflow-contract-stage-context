// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {CatWars} from "../src/CatWars.sol";
import {MockVRFWrapper} from "./mocks/MockVRFWrapper.sol";

contract CatWarsGasTest is Test {
    struct Vector {
        uint256 a;
        uint256 b;
        int256 hp0;
        int256 hp1;
        bytes32 seed;
        uint256 turns;
        uint256 winner;
    }

    function test_settleGasAcross500ReferenceVectors() public {
        MockVRFWrapper wrapper = new MockVRFWrapper();
        CatWars game = new CatWars(address(wrapper), address(this));
        Vector[] memory vectors = abi.decode(
            vm.parseJson(vm.readFile(string.concat(vm.projectRoot(), "/test/vectors.json")), ".vectors"), (Vector[])
        );
        address red = makeAddr("red");
        address blue = makeAddr("blue");
        vm.deal(red, 1000 ether);
        vm.deal(blue, 1000 ether);
        vm.deal(address(this), 100 ether);
        uint256 sum;
        uint256 worst;
        uint256 executed;
        for (uint256 i; i < vectors.length; ++i) {
            Vector memory v = vectors[i];
            // The reference permits a mirror match in isolation, whereas the game forbids it.
            if (v.a == v.b) continue;
            uint256 id = game.openRound(uint8(v.a), uint8(v.b));
            vm.prank(red);
            game.placeBet{value: 1 ether}(id, 0);
            vm.prank(blue);
            game.placeBet{value: 1 ether}(id, 1);
            vm.warp(game.getRound(id).lockAt);
            game.requestResult{value: game.vrfPrice()}(id);
            wrapper.fulfill(game.getRound(id).requestId, uint256(v.seed));
            vm.cool(address(game));
            uint256 startGas = gasleft();
            game.settle(id);
            uint256 spent = startGas - gasleft();
            sum += spent;
            if (spent > worst) worst = spent;
            ++executed;
            CatWars.Round memory r = game.getRound(id);
            assertEq(r.winner, v.winner);
            assertEq(r.turns, v.turns);
        }
        assertGt(executed, 400);
        console.log("settle vector count", executed);
        console.log("settle average gas (cold storage)", sum / executed);
        console.log("settle maximum gas (cold storage)", worst);
        assertLt(worst, 600_000);
    }
}
