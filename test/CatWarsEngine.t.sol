// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CatWarsEngine} from "../src/CatWarsEngine.sol";

contract EngineHarness {
    function simulate(uint8 a, uint8 b, bytes32 seed) external pure returns (uint8, uint8, int256, int256) {
        return CatWarsEngine.simulate(a, b, seed);
    }
}

contract CatWarsEngineTest is Test {
    // fields in alphabetical order, as vm.parseJson requires
    struct Vector { uint256 a; uint256 b; int256 hp0; int256 hp1; bytes32 seed; uint256 turns; uint256 winner; }

    EngineHarness h = new EngineHarness();

    function _vectors() internal view returns (Vector[] memory) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/vectors.json"));
        return abi.decode(vm.parseJson(json, ".vectors"), (Vector[]));
    }

    function test_matchesAll500JsVectors() public view {
        Vector[] memory vs = _vectors();
        assertEq(vs.length, 500);
        for (uint256 i = 0; i < vs.length; i++) {
            (uint8 w, uint8 t, int256 h0, int256 h1) = h.simulate(uint8(vs[i].a), uint8(vs[i].b), vs[i].seed);
            assertEq(w, vs[i].winner, string.concat("winner mismatch at vector ", vm.toString(i)));
            assertEq(t, vs[i].turns, string.concat("turns mismatch at vector ", vm.toString(i)));
            assertEq(h0, vs[i].hp0, string.concat("hpA mismatch at vector ", vm.toString(i)));
            assertEq(h1, vs[i].hp1, string.concat("hpB mismatch at vector ", vm.toString(i)));
        }
    }

    function test_gasWorstCase() public {
        Vector[] memory vs = _vectors();
        uint256 worst; uint256 sum;
        for (uint256 i = 0; i < vs.length; i++) {
            uint256 g = gasleft();
            h.simulate(uint8(vs[i].a), uint8(vs[i].b), vs[i].seed);
            g -= gasleft();
            sum += g;
            if (g > worst) worst = g;
        }
        console.log("avg gas", sum / vs.length);
        console.log("worst gas", worst);
        assertLt(worst, 2_000_000);
    }

    function test_rejectsBadCat() public {
        vm.expectRevert(bytes("bad cat"));
        h.simulate(8, 0, bytes32(uint256(1)));
    }
}
