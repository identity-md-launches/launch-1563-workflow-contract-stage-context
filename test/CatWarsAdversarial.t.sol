// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CatWars} from "src/CatWars.sol";
import {CatWarsEngine} from "src/CatWarsEngine.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockVRFWrapper} from "./mocks/MockVRFWrapper.sol";
import {TestReceiver} from "./mocks/Receivers.sol";

contract PayoutReentryProbe {
    CatWars internal immutable game;
    bytes internal payload;
    bool public attempted;
    bool public guardRejected;

    constructor(CatWars game_, bytes memory payload_) {
        game = game_;
        payload = payload_;
    }

    receive() external payable {
        (bool ok, bytes memory reason) = address(game).call(payload);
        attempted = true;
        guardRejected = !ok && bytes4(reason) == ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
    }
}

contract CatWarsAdversarialTest is Test {
    CatWars internal game;
    MockVRFWrapper internal wrapper;
    address internal owner = makeAddr("adversarial owner");
    address internal alice = makeAddr("adversarial alice");
    address internal bob = makeAddr("adversarial bob");
    address internal carol = makeAddr("adversarial carol");
    address internal caller = makeAddr("permissionless caller");

    function setUp() public {
        wrapper = new MockVRFWrapper();
        game = new CatWars(address(wrapper), owner);
        vm.deal(address(this), 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(caller, 100 ether);
    }

    function _open() internal returns (uint256) {
        vm.prank(owner);
        return game.openRound(0, 1);
    }

    function _bet(uint256 id, address actor, uint8 side, uint256 amount) internal {
        vm.prank(actor);
        game.placeBet{value: amount}(id, side);
    }

    function _bothSides() internal returns (uint256 id) {
        id = _open();
        _bet(id, alice, 0, 1 ether);
        _bet(id, bob, 1, 2 ether);
    }

    function _request(uint256 id) internal returns (uint256) {
        vm.warp(game.getRound(id).lockAt);
        uint256 fee = game.vrfPrice();
        vm.prank(caller);
        game.requestResult{value: fee}(id);
        return game.getRound(id).requestId;
    }

    function _finish(uint256 id, uint256 word) internal {
        wrapper.fulfill(_request(id), word);
        vm.prank(caller);
        game.settle(id);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_unknownRoundRejectsEveryRoundEntryPointAtomically(uint256 rawId) public {
        _bothSides();
        uint256 id = bound(rawId, 1, type(uint256).max);
        address[] memory players = new address[](1);
        players[0] = alice;
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeCall(game.placeBet, (id, 0));
        calls[1] = abi.encodeCall(game.requestResult, (id));
        calls[2] = abi.encodeCall(game.settle, (id));
        calls[3] = abi.encodeCall(game.cancelRound, (id));
        calls[4] = abi.encodeCall(game.claim, (id));
        calls[5] = abi.encodeCall(game.claimFor, (id, alice));
        calls[6] = abi.encodeCall(game.claimMany, (id, players));
        calls[7] = abi.encodeCall(game.getBet, (id, alice));
        calls[8] = abi.encodeCall(game.pendingPayout, (id, alice));
        bytes32 beforeRound = keccak256(abi.encode(game.getRound(0)));
        uint256 beforeCaller = caller.balance;
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(caller);
            (bool ok, bytes memory reason) = address(game).call{value: i < 2 ? 1 ether : 0}(calls[i]);
            assertFalse(ok);
            assertEq(reason, abi.encodeWithSelector(CatWars.UnknownRound.selector, id));
        }
        assertEq(keccak256(abi.encode(game.getRound(0))), beforeRound);
        assertEq(address(game).balance, 3 ether);
        assertEq(caller.balance, beforeCaller);
        assertEq(wrapper.requestCount(), 0);
    }

    function test_allNonterminalStatesRejectClaimsAndPrematureSettlement() public {
        uint256 id = _bothSides();
        address[] memory empty = new address[](0);
        for (uint256 stage; stage < 3; ++stage) {
            bytes32 beforeRound = keccak256(abi.encode(game.getRound(id)));
            vm.expectRevert(CatWars.WrongStatus.selector);
            game.claim(id);
            vm.expectRevert(CatWars.WrongStatus.selector);
            game.claimFor(id, alice);
            vm.expectRevert(CatWars.WrongStatus.selector);
            game.claimMany(id, empty);
            if (stage < 2) {
                vm.expectRevert(CatWars.WrongStatus.selector);
                game.settle(id);
            }
            assertEq(keccak256(abi.encode(game.getRound(id))), beforeRound);
            assertEq(address(game).balance, 3 ether);
            assertEq(game.pendingPayout(id, alice), 0);
            if (stage == 0) _request(id);
            if (stage == 1) wrapper.fulfill(game.getRound(id).requestId, 123);
        }
        game.settle(id);
    }

    function test_terminalRoundsCannotReopenOrAccrueAnotherRake() public {
        uint256 settled = _bothSides();
        _finish(settled, type(uint256).max);
        uint256 cancelled = _bothSides();
        vm.prank(owner);
        game.cancelRound(cancelled);
        uint256 rake = game.owed(owner);
        for (uint256 id; id < 2; ++id) {
            bytes32 beforeRound = keccak256(abi.encode(game.getRound(id)));
            vm.expectRevert(CatWars.WrongStatus.selector);
            _bet(id, carol, 0, 1 ether);
            vm.expectRevert(CatWars.WrongStatus.selector);
            game.requestResult{value: 1 ether}(id);
            vm.expectRevert(CatWars.WrongStatus.selector);
            game.settle(id);
            vm.prank(owner);
            vm.expectRevert(CatWars.CancellationNotAllowed.selector);
            game.cancelRound(id);
            assertEq(keccak256(abi.encode(game.getRound(id))), beforeRound);
        }
        assertEq(game.owed(owner), rake);
        assertEq(address(game).balance, 6 ether);
    }

    function test_keeperCannotCancelRequestedAtBoundaryOrEverCancelFulfilled() public {
        vm.prank(owner);
        game.setKeeper(carol);
        uint256 id = _bothSides();
        uint256 request = _request(id);
        vm.warp(game.getRound(id).requestedAt + 24 hours);
        vm.prank(carol);
        vm.expectRevert(CatWars.CancellationNotAllowed.selector);
        game.cancelRound(id);
        wrapper.fulfill(request, 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(carol);
        vm.expectRevert(CatWars.CancellationNotAllowed.selector);
        game.cancelRound(id);
        vm.prank(caller);
        game.settle(id);
        assertEq(uint8(game.getRound(id).status), uint8(CatWars.Status.Settled));
    }

    function test_revertedSideSwitchPreservesCountsAndMoneyIncludingTopUps() public {
        uint256 id = _bothSides();
        _bet(id, alice, 0, 1 ether);
        bytes32 roundBefore = keccak256(abi.encode(game.getRound(id)));
        bytes32 betBefore = keccak256(abi.encode(game.getBet(id, alice)));
        uint256 balanceBefore = alice.balance;
        vm.expectRevert(CatWars.CannotSwitchSide.selector);
        _bet(id, alice, 1, 3 ether);
        assertEq(keccak256(abi.encode(game.getRound(id))), roundBefore);
        assertEq(keccak256(abi.encode(game.getBet(id, alice))), betBefore);
        assertEq(alice.balance, balanceBefore);
        assertEq(address(game).balance, 4 ether);
    }

    function test_existingStakeRemainsRefundableAfterMinimumRaisedToMaximum() public {
        uint256 id = _bothSides();
        vm.prank(owner);
        game.setMinBet(type(uint256).max);
        vm.expectRevert(CatWars.BelowMinimumBet.selector);
        _bet(id, alice, 0, 1 ether);
        vm.prank(owner);
        game.cancelRound(id);
        game.claimFor(id, alice);
        game.claimFor(id, bob);
        assertEq(alice.balance, 100 ether);
        assertEq(bob.balance, 100 ether);
        assertEq(address(game).balance, 0);
    }

    function test_zeroPayoutWinnerIsClaimedOnceWithoutCreatingCredit() public {
        vm.startPrank(owner);
        game.setMinBet(1);
        game.setRakeBps(1000);
        vm.stopPrank();
        uint256 word = uint256(keccak256("zero payout edge"));
        (uint8 winner,,,) = CatWarsEngine.simulate(0, 1, bytes32(word));
        uint256 id = _open();
        TestReceiver tiny = new TestReceiver(game);
        tiny.configure(true, false, false);
        tiny.bet{value: 1}(id, winner);
        _bet(id, alice, winner, 100);
        _bet(id, bob, 1 - winner, 1);
        _finish(id, word);
        assertEq(game.pendingPayout(id, address(tiny)), 0);
        vm.expectEmit(true, true, false, true, address(game));
        emit CatWars.Claimed(id, address(tiny), 0, true);
        game.claimFor(id, address(tiny));
        assertTrue(game.getBet(id, address(tiny)).claimed);
        assertEq(game.owed(address(tiny)), 0);
        vm.expectRevert(CatWars.NothingToClaim.selector);
        game.claimFor(id, address(tiny));
        game.claimFor(id, alice);
        assertEq(game.owed(owner), 10);
        assertEq(address(game).balance, 11); // Ten wei rake and one wei rounding dust.
    }

    /// @dev Equal winning stakes give an independent oracle: each gets floor(netPool / 2).
    /// Products exceed uint256, while deposits and the correct final quotient still fit.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_fullPrecisionPayoutAndRake(uint256 stakeSeed, uint256 losingSeed, uint16 rakeSeed) public {
        uint256 stake = bound(stakeSeed, 1 << 128, type(uint240).max / 4);
        uint256 losing = bound(losingSeed, 1, type(uint240).max / 4);
        uint16 rakeBps = uint16(bound(rakeSeed, 0, 1000));
        vm.startPrank(owner);
        game.setMinBet(1);
        game.setRakeBps(rakeBps);
        vm.stopPrank();
        uint256 word = uint256(keccak256("large payout"));
        (uint8 winner,,,) = CatWarsEngine.simulate(0, 1, bytes32(word));
        vm.deal(alice, stake);
        vm.deal(bob, stake);
        vm.deal(carol, losing);
        uint256 id = _open();
        _bet(id, alice, winner, stake);
        _bet(id, bob, winner, stake);
        _bet(id, carol, 1 - winner, losing);
        _finish(id, word);
        uint256 pool = 2 * stake + losing;
        // Quotient/remainder decomposition avoids reproducing Math.mulDiv in the oracle.
        uint256 rake = (pool / 10_000) * rakeBps + ((pool % 10_000) * rakeBps) / 10_000;
        uint256 expected = (pool - rake) / 2;
        assertEq(game.owed(owner), rake);
        assertEq(game.pendingPayout(id, alice), expected);
        assertEq(game.pendingPayout(id, bob), expected);
        game.claimFor(id, alice);
        game.claimFor(id, bob);
        assertEq(alice.balance, expected);
        assertEq(bob.balance, expected);
        assertEq(carol.balance, 0);
        vm.prank(owner);
        if (rake == 0) vm.expectRevert(CatWars.NothingToWithdraw.selector);
        game.withdraw();
        assertEq(address(game).balance, (pool - rake) % 2);
    }

    function test_sameRecipientCanAccumulateRefundRakeAndWinningsThenWithdrawExactlyOnce() public {
        TestReceiver receiver = new TestReceiver(game);
        receiver.configure(true, false, false);
        vm.prank(owner);
        game.setTreasury(address(receiver));
        uint256 word = uint256(keccak256("three credit sources"));
        (uint8 winner,,,) = CatWarsEngine.simulate(0, 1, bytes32(word));
        uint256 id = _open();
        receiver.bet{value: 1 ether}(id, winner);
        _bet(id, bob, 1 - winner, 2 ether);
        vm.warp(game.getRound(id).lockAt);
        receiver.request{value: game.vrfPrice() + 0.7 ether}(id);
        wrapper.fulfill(game.getRound(id).requestId, word);
        game.settle(id);
        game.claimFor(id, address(receiver));
        assertEq(game.owed(address(receiver)), 3.7 ether);
        assertEq(game.pendingPayout(id, address(receiver)), 0);
        vm.prank(owner);
        game.setTreasury(carol);
        vm.expectRevert(CatWars.TransferFailed.selector);
        receiver.withdraw();
        assertEq(game.owed(address(receiver)), 3.7 ether);
        assertEq(game.owed(carol), 0);
        receiver.configure(false, false, false);
        receiver.withdraw();
        assertEq(address(receiver).balance, 3.7 ether);
        assertEq(address(game).balance, 0);
        vm.expectRevert(CatWars.NothingToWithdraw.selector);
        receiver.withdraw();
    }

    function test_everyMoneyEntryPointRejectsCrossFunctionReentrancyWithGuardError() public {
        uint256 id = _open();
        address[] memory players = new address[](1);
        players[0] = alice;
        bytes[] memory payloads = new bytes[](7);
        payloads[0] = abi.encodeCall(game.placeBet, (id, 0));
        payloads[1] = abi.encodeCall(game.requestResult, (id));
        payloads[2] = abi.encodeCall(game.settle, (id));
        payloads[3] = abi.encodeCall(game.claim, (id));
        payloads[4] = abi.encodeCall(game.claimFor, (id, alice));
        payloads[5] = abi.encodeCall(game.claimMany, (id, players));
        payloads[6] = abi.encodeCall(game.withdraw, ());
        PayoutReentryProbe[] memory probes = new PayoutReentryProbe[](7);
        for (uint256 i; i < 7; ++i) {
            probes[i] = new PayoutReentryProbe(game, payloads[i]);
            vm.deal(address(probes[i]), 1 ether);
            _bet(id, address(probes[i]), 0, 1 ether);
        }
        _bet(id, alice, 0, 1 ether);
        vm.prank(owner);
        game.cancelRound(id);
        for (uint256 i; i < 7; ++i) {
            game.claimFor(id, address(probes[i]));
            assertTrue(probes[i].attempted(), "fallback did not actually execute");
            assertTrue(probes[i].guardRejected(), "failure came from state checks instead of the guard");
            assertEq(address(probes[i]).balance, 1 ether);
            assertEq(game.owed(address(probes[i])), 0, "fallback ran out of payout gas");
        }
        assertFalse(game.getBet(id, alice).claimed);
        game.claimFor(id, alice);
        assertEq(address(game).balance, 0);
    }

    function test_requestAndSettlementEventsPublishFullWidthBigEndianSeed() public {
        uint256 word = 0x0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef;
        vm.expectEmit(true, false, false, true, address(game));
        emit CatWars.RoundOpened(0, 0, 1, vm.getBlockTimestamp() + 300, 500);
        uint256 id = _open();
        vm.expectEmit(true, true, false, true, address(game));
        emit CatWars.BetPlaced(id, alice, 0, 1 ether, 1 ether, 0);
        _bet(id, alice, 0, 1 ether);
        _bet(id, bob, 1, 2 ether);
        vm.warp(game.getRound(id).lockAt);
        uint256 fee = game.vrfPrice();
        vm.expectEmit(true, false, false, true, address(game));
        emit CatWars.ResultRequested(id, 1, fee);
        vm.prank(caller);
        game.requestResult{value: fee}(id);
        vm.expectEmit(true, false, false, true, address(game));
        emit CatWars.RandomnessFulfilled(id, word);
        wrapper.fulfill(1, word);
        (uint8 winner, uint8 turns,,) = CatWarsEngine.simulate(0, 1, bytes32(word));
        vm.expectEmit(true, false, false, true, address(game));
        emit CatWars.RoundSettled(id, bytes32(word), winner, turns, 3 ether, 0.15 ether);
        game.settle(id);
        address player = winner == 0 ? alice : bob;
        vm.expectEmit(true, true, false, true, address(game));
        emit CatWars.Claimed(id, player, 2.85 ether, true);
        game.claimFor(id, player);
        vm.expectEmit(true, false, false, true, address(game));
        emit CatWars.Withdrawn(owner, 0.15 ether);
        vm.prank(owner);
        game.withdraw();
    }
}
