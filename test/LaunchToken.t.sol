// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function setUp() public {
        token = new LaunchToken();
    }

    function test_exactSupplyAndMetadata() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "CAT WARS");
        assertEq(token.symbol(), "MEOW");
    }

    function testFuzz_transferHasNoFee(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_allowanceAndTransferFrom() public {
        token.approve(alice, 2 ether);
        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), bob, 1 ether));
        assertEq(token.balanceOf(bob), 1 ether);
        assertEq(token.allowance(address(this), alice), 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        token.transferFrom(address(this), bob, 2 ether);
    }

    function test_rejectsZeroRecipientAndOverspending() public {
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 1);
    }

    function test_noAdministrativeSupplyOrTransferControls() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "pause()",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], alice, 1e27));
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(alice), 0);
    }
}
