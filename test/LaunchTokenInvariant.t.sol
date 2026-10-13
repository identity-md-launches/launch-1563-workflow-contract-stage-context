// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev A closed set of holders lets the invariant account for every token without storage cheats.
contract LaunchTokenLedgerHandler is Test {
    LaunchToken public immutable token;
    address[5] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public transfers;
    uint256 public delegatedTransfers;
    uint256 public rejectedTransfers;

    constructor() {
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("token ledger actor ", vm.toString(i)));
        }
        vm.prank(actors[0]);
        token = new LaunchToken();
        expectedBalance[actors[0]] = 1e27;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        ++transfers;
    }

    function approve(uint256 fromSeed, uint256 spenderSeed, uint256 amount, bool unlimited) public {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        amount = unlimited ? type(uint256).max : bound(amount, 0, 1e27);
        vm.prank(from);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[from][spender] = amount;
    }

    function transferFrom(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) public {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = expectedAllowance[from][spender];
        uint256 maximum = expectedBalance[from] < allowed ? expectedBalance[from] : allowed;
        uint256 amount = bound(amountSeed, 0, maximum);
        vm.prank(spender);
        assertTrue(token.transferFrom(from, to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        if (allowed != type(uint256).max) expectedAllowance[from][spender] -= amount;
        ++delegatedTransfers;
    }

    function rejectOverspend(uint256 fromSeed, uint256 toSeed, uint256 excessSeed) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 balance = expectedBalance[from];
        uint256 amount = balance + bound(excessSeed, 1, 1e27);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount));
        token.transfer(to, amount);
        ++rejectedTransfers;
    }

    function rejectUnapprovedSpend(uint256 fromSeed, uint256 spenderSeed, uint256 toSeed) public {
        address from = actors[fromSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowed = expectedAllowance[from][spender];
        if (allowed == type(uint256).max) return;
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, allowed + 1)
        );
        token.transferFrom(from, to, allowed + 1);
        ++rejectedTransfers;
    }

    function rejectZeroRecipient(uint256 fromSeed, uint256 amountSeed) public {
        address from = actors[fromSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
        ++rejectedTransfers;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is StdInvariant, Test {
    LaunchTokenLedgerHandler internal handler;
    LaunchToken internal token;

    function setUp() public {
        handler = new LaunchTokenLedgerHandler();
        token = handler.token();
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.rejectOverspend.selector;
        selectors[4] = handler.rejectUnapprovedSpend.selector;
        selectors[5] = handler.rejectZeroRecipient.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_fixedSupplyAndExactHolderAccounting() public view {
        uint256 total;
        for (uint256 i; i < 5; ++i) {
            address actor = handler.actors(i);
            assertEq(token.balanceOf(actor), handler.expectedBalance(actor), "holder ledger mismatch");
            total += token.balanceOf(actor);
            for (uint256 j; j < 5; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(actor, spender), handler.expectedAllowance(actor, spender));
            }
        }
        assertEq(total, 1e27, "tokens created, destroyed, or leaked outside the actor set");
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }

    function test_ledgerExercisesFullSupplySelfTransfersAndAllowanceRevocation() public {
        handler.transfer(0, 1, 1e27);
        handler.transfer(1, 1, 1e27);
        handler.approve(1, 2, 0, true);
        handler.transferFrom(1, 2, 3, 1e27);
        handler.approve(3, 2, 1e27, false);
        handler.transferFrom(3, 2, 3, 1e27);
        handler.rejectUnapprovedSpend(3, 2, 4);
        handler.approve(1, 2, 0, false);
        handler.rejectUnapprovedSpend(1, 2, 4);
        handler.rejectOverspend(3, 4, 1);
        handler.rejectZeroRecipient(3, 1);
        invariant_fixedSupplyAndExactHolderAccounting();
        assertEq(handler.transfers(), 2);
        assertEq(handler.delegatedTransfers(), 2);
        assertEq(handler.rejectedTransfers(), 4);
    }
}
