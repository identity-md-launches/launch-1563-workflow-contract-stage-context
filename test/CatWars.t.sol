// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CatWars} from "../src/CatWars.sol";
import {CatWarsEngine} from "../src/CatWarsEngine.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {MockVRFWrapper} from "./mocks/MockVRFWrapper.sol";
import {TestReceiver} from "./mocks/Receivers.sol";

contract CatWarsTest is Test {
    CatWars internal game;
    MockVRFWrapper internal wrapper;
    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal outsider = makeAddr("outsider");

    function setUp() public {
        wrapper = new MockVRFWrapper();
        game = new CatWars(address(wrapper), owner);
        vm.deal(address(this), 1000 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(carol, 100 ether);
        vm.deal(dave, 100 ether);
        vm.deal(outsider, 100 ether);
    }

    function _open() internal returns (uint256 id) {
        vm.prank(owner);
        return game.openRound(0, 1);
    }

    function _bet(uint256 id, address player, uint8 side, uint256 amount) internal {
        vm.prank(player);
        game.placeBet{value: amount}(id, side);
    }

    function _bothSides() internal returns (uint256 id) {
        id = _open();
        _bet(id, alice, 0, 1 ether);
        _bet(id, bob, 1, 2 ether);
    }

    function _request(uint256 id) internal returns (uint256) {
        vm.warp(game.getRound(id).lockAt);
        uint256 price = game.vrfPrice();
        vm.prank(outsider);
        game.requestResult{value: price}(id);
        return game.getRound(id).requestId;
    }

    function _finish(uint256 id, uint256 word) internal {
        wrapper.fulfill(_request(id), word);
        vm.prank(outsider);
        game.settle(id);
    }

    function test_constructorDefaultsWithoutSetupOrLinkCalls() public view {
        assertEq(game.owner(), owner);
        assertEq(game.treasury(), owner);
        assertEq(game.keeper(), owner);
        assertEq(game.rakeBps(), 500);
        assertEq(game.bettingDuration(), 300);
        assertEq(game.minBet(), 0.001 ether);
        assertEq(game.CALLBACK_GAS_LIMIT(), 150_000);
        assertEq(game.CATS_COUNT(), 8);
        assertEq(game.roundCount(), 0);
        assertFalse(game.paused());
    }

    function test_emptyChainConstructorAndFirstUseValidation() public {
        address noCode = makeAddr("empty chain wrapper");
        CatWars emptyChain = new CatWars(noCode, owner);
        assertEq(emptyChain.owner(), owner);
        assertEq(address(emptyChain.i_vrfV2PlusWrapper()), noCode);
        vm.expectRevert(CatWars.WrapperUnavailable.selector);
        emptyChain.vrfPrice();
        vm.expectRevert(CatWars.InvalidAddress.selector);
        new CatWars(address(0), owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CatWars(address(wrapper), address(0));
    }

    function test_noRoundAndUnknownRoundAreNotRoundZero() public {
        vm.expectRevert(CatWars.NoRounds.selector);
        game.currentRoundId();
        vm.expectRevert(abi.encodeWithSelector(CatWars.UnknownRound.selector, 0));
        game.getRound(0);
        vm.expectRevert(abi.encodeWithSelector(CatWars.UnknownRound.selector, 0));
        game.placeBet{value: 1 ether}(0, 0);
        assertEq(_open(), 0);
        assertEq(game.currentRoundId(), 0);
        vm.expectRevert(abi.encodeWithSelector(CatWars.UnknownRound.selector, 1));
        game.pendingPayout(1, alice);
    }

    function test_openAuthorizationCatsAndNoParallelOpenRounds() public {
        vm.expectRevert(CatWars.UnauthorizedKeeper.selector);
        game.openRound(0, 1);
        vm.startPrank(owner);
        vm.expectRevert(CatWars.InvalidCats.selector);
        game.openRound(0, 0);
        vm.expectRevert(CatWars.InvalidCats.selector);
        game.openRound(8, 0);
        game.setKeeper(keeper);
        vm.stopPrank();
        vm.prank(keeper);
        game.openRound(7, 0);
        vm.prank(owner);
        vm.expectRevert(CatWars.PreviousRoundOpen.selector);
        game.openRound(1, 2);
        vm.prank(keeper);
        game.cancelRound(0);
        assertEq(_open(), 1);
    }

    function test_betsTopUpsCountsSidesMinimumAndLockBoundary() public {
        uint256 id = _bothSides();
        _bet(id, alice, 0, 2 ether);
        _bet(id, carol, 0, 3 ether);
        CatWars.Round memory r = game.getRound(id);
        assertEq(r.total0, 6 ether);
        assertEq(r.total1, 2 ether);
        assertEq(r.bettors0, 2);
        assertEq(r.bettors1, 1);
        assertEq(game.getBet(id, alice).amount, 3 ether);
        vm.expectRevert(CatWars.CannotSwitchSide.selector);
        _bet(id, alice, 1, 1 ether);
        vm.expectRevert(CatWars.InvalidSide.selector);
        _bet(id, carol, 2, 1 ether);
        vm.expectRevert(CatWars.BelowMinimumBet.selector);
        _bet(id, carol, 0, 0.0009 ether);
        vm.warp(r.lockAt - 1);
        _bet(id, bob, 1, 0.001 ether);
        vm.warp(r.lockAt);
        vm.expectRevert(CatWars.BettingClosed.selector);
        _bet(id, bob, 1, 1 ether);
    }

    function test_requestPaymentQuoteAtGasPriceAndRefundExcess() public {
        uint256 id = _bothSides();
        vm.expectRevert(CatWars.BettingStillOpen.selector);
        game.requestResult{value: 1 ether}(id);
        vm.warp(game.getRound(id).lockAt);
        vm.txGasPrice(12 gwei);
        uint256 price = wrapper.fee() + 150_000 * 12 gwei;
        assertEq(game.vrfPrice(), price);
        vm.expectRevert(abi.encodeWithSelector(CatWars.InsufficientVrfPayment.selector, price, price - 1));
        game.requestResult{value: price - 1}(id);
        assertEq(address(game).balance, 3 ether);
        uint256 callerBefore = outsider.balance;
        vm.prank(outsider);
        game.requestResult{value: price + 1 ether}(id);
        assertEq(outsider.balance, callerBefore - price);
        assertEq(address(game).balance, 3 ether);
        assertEq(wrapper.totalPaid(), price);
        assertEq(wrapper.requestCount(), 1);
        assertEq(wrapper.lastGasLimit(), 150_000);
        assertEq(wrapper.lastConfirmations(), 3);
        assertEq(wrapper.lastNumWords(), 1);
        assertEq(uint8(game.getRound(id).status), uint8(CatWars.Status.Requested));
        assertEq(game.getRound(id).requestedAt, block.timestamp);
        vm.expectRevert(CatWars.WrongStatus.selector);
        game.requestResult{value: price}(id);
        // A pending request does not prevent betting in the next round.
        assertEq(_open(), 1);
    }

    function test_wrapperFailureRollsBackAndNeverConsumesStakes() public {
        uint256 id = _bothSides();
        vm.warp(game.getRound(id).lockAt);
        wrapper.setFailRequests(true);
        uint256 price = game.vrfPrice();
        vm.expectRevert(bytes("wrapper unavailable"));
        game.requestResult{value: price}(id);
        assertEq(uint8(game.getRound(id).status), uint8(CatWars.Status.Open));
        assertEq(address(game).balance, 3 ether);
        assertEq(wrapper.totalPaid(), 0);
        wrapper.setFailRequests(false);
        game.requestResult{value: price}(id);
        assertEq(wrapper.totalPaid(), price);
    }

    function test_changedWrapperQuoteCannotConsumeStakes() public {
        uint256 id = _bothSides();
        vm.warp(game.getRound(id).lockAt);
        wrapper.setReprice(true);
        uint256 price = game.vrfPrice();
        vm.expectRevert(abi.encodeWithSelector(CatWars.InsufficientVrfPayment.selector, price + 1 ether, price));
        game.requestResult{value: price}(id);
        assertEq(address(game).balance, 3 ether);
        assertEq(wrapper.totalPaid(), 0);
        assertEq(uint8(game.getRound(id).status), uint8(CatWars.Status.Open));
    }

    function test_fullLifecycleProRataPayoutsAndTreasury() public {
        uint256 id = _bothSides();
        _bet(id, alice, 0, 1 ether);
        _bet(id, carol, 0, 1 ether);
        _bet(id, dave, 1, 4 ether);
        uint256 word = uint256(keccak256("full-width VRF word"));
        _finish(id, word);
        (uint8 winner, uint8 turns,,) = CatWarsEngine.simulate(0, 1, bytes32(word));
        CatWars.Round memory r = game.getRound(id);
        assertEq(r.winner, winner);
        assertEq(r.turns, turns);
        assertEq(r.randomWord, word);
        assertEq(r.rake, 0.45 ether);
        assertEq(game.owed(owner), r.rake);
        address[4] memory players = [alice, bob, carol, dave];
        uint256 totalPaid;
        for (uint256 i; i < players.length; ++i) {
            CatWars.Bet memory b = game.getBet(id, players[i]);
            uint256 expected = b.side == winner ? b.amount * (9 ether - r.rake) / (winner == 0 ? 3 ether : 6 ether) : 0;
            assertEq(game.pendingPayout(id, players[i]), expected);
            uint256 beforeBalance = players[i].balance;
            if (b.side != winner) {
                vm.expectRevert(CatWars.NothingToClaim.selector);
                game.claimFor(id, players[i]);
            } else {
                vm.prank(outsider);
                game.claimFor(id, players[i]);
                assertEq(players[i].balance, beforeBalance + expected);
                assertEq(game.pendingPayout(id, players[i]), 0);
                assertTrue(game.getBet(id, players[i]).claimed);
                totalPaid += expected;
            }
        }
        uint256 ownerBefore = owner.balance;
        vm.prank(owner);
        game.withdraw();
        assertEq(owner.balance, ownerBefore + r.rake);
        assertEq(address(game).balance, 9 ether - totalPaid - r.rake);
        assertEq(game.owed(owner), 0);
        vm.expectRevert(CatWars.WrongStatus.selector);
        game.settle(id);
    }

    function test_oneSidedAndEmptyRoundCancelWithoutVrf() public {
        uint256 id = _open();
        _bet(id, alice, 1, 2 ether);
        vm.warp(game.getRound(id).lockAt);
        wrapper.setFailRequests(true);
        uint256 beforeBalance = outsider.balance;
        vm.prank(outsider);
        game.requestResult{value: 1 ether}(id);
        assertEq(outsider.balance, beforeBalance);
        assertEq(wrapper.requestCount(), 0);
        assertEq(game.owed(owner), 0);
        assertEq(game.pendingPayout(id, alice), 2 ether);
        vm.prank(alice);
        game.claim(id);
        assertEq(alice.balance, 100 ether);
        vm.prank(alice);
        vm.expectRevert(CatWars.NothingToClaim.selector);
        game.claim(id);
        uint256 empty = _open();
        vm.warp(game.getRound(empty).lockAt);
        game.requestResult(empty);
        assertEq(uint8(game.getRound(empty).status), uint8(CatWars.Status.Cancelled));
    }

    function test_openTimeoutStrictBoundaryAndPermissionlessRefunds() public {
        uint256 id = _bothSides();
        uint256 deadline = game.getRound(id).lockAt + 1 hours;
        vm.warp(deadline);
        vm.expectRevert(CatWars.CancellationNotAllowed.selector);
        game.cancelRound(id);
        vm.warp(deadline + 1);
        game.cancelRound(id);
        game.claimFor(id, alice);
        game.claimFor(id, bob);
        assertEq(alice.balance, 100 ether);
        assertEq(bob.balance, 100 ether);
        assertEq(address(game).balance, 0);
    }

    function test_requestedTimeoutStrictBoundaryAndLateCallbackIgnored() public {
        uint256 id = _bothSides();
        uint256 request = _request(id);
        vm.prank(owner);
        vm.expectRevert(CatWars.CancellationNotAllowed.selector);
        game.cancelRound(id);
        vm.warp(game.getRound(id).requestedAt + 24 hours);
        vm.expectRevert(CatWars.CancellationNotAllowed.selector);
        game.cancelRound(id);
        vm.warp(block.timestamp + 1);
        game.cancelRound(id);
        wrapper.fulfill(request, type(uint256).max);
        assertEq(game.getRound(id).randomWord, 0);
        assertEq(uint8(game.getRound(id).status), uint8(CatWars.Status.Cancelled));
        game.claimFor(id, alice);
        game.claimFor(id, bob);
        assertEq(address(game).balance, 0);
        assertEq(game.owed(owner), 0);
    }

    function test_fulfilledRoundCannotBeCancelledEvenAfterTimeout() public {
        uint256 id = _bothSides();
        wrapper.fulfill(_request(id), 123);
        vm.warp(block.timestamp + 30 days);
        vm.prank(owner);
        vm.expectRevert(CatWars.CancellationNotAllowed.selector);
        game.cancelRound(id);
        vm.expectRevert(CatWars.CancellationNotAllowed.selector);
        game.cancelRound(id);
        game.settle(id);
    }

    function test_callbacksAuthenticateUnknownEmptyDoubleAndZeroWord() public {
        uint256 id = _bothSides();
        uint256 request = _request(id);
        uint256[] memory words = new uint256[](1);
        words[0] = 7;
        vm.expectRevert(
            abi.encodeWithSelector(
                VRFV2PlusWrapperConsumerBase.OnlyVRFWrapperCanFulfill.selector, address(this), address(wrapper)
            )
        );
        game.rawFulfillRandomWords(request, words);
        wrapper.deliver(address(game), request + 5, words);
        wrapper.deliver(address(game), 0, words);
        wrapper.deliver(address(game), request, new uint256[](0));
        assertEq(uint8(game.getRound(id).status), uint8(CatWars.Status.Requested));
        wrapper.fulfill(request, 0);
        wrapper.fulfill(request, 999);
        assertEq(game.getRound(id).randomWord, 0);
        assertEq(uint8(game.getRound(id).status), uint8(CatWars.Status.Fulfilled));
        game.settle(id);
        wrapper.fulfill(request, 77);
        assertEq(game.getRound(id).randomWord, 0);
    }

    function test_callbacksUseLessThanConfiguredGas() public {
        uint256 id = _bothSides();
        uint256 request = _request(id);
        uint256[] memory words = new uint256[](1);
        words[0] = type(uint256).max;
        vm.prank(address(wrapper));
        (bool ok,) = address(game).call{gas: 150_000}(abi.encodeCall(game.rawFulfillRandomWords, (request, words)));
        assertTrue(ok);
        assertEq(game.getRound(id).randomWord, type(uint256).max);
    }

    function test_outOfOrderRequestsAreMappedToCorrectRounds() public {
        uint256 id0 = _bothSides();
        uint256 req0 = _request(id0);
        uint256 id1 = _bothSides();
        uint256 req1 = _request(id1);
        wrapper.fulfill(req1, 2);
        wrapper.fulfill(req0, 1);
        assertEq(game.getRound(id0).randomWord, 1);
        assertEq(game.getRound(id1).randomWord, 2);
        game.settle(id1);
        game.settle(id0);
        assertEq(game.owed(owner), 0.3 ether);
    }

    function test_duplicateWrapperRequestIdRevertsAtomically() public {
        uint256 id0 = _bothSides();
        _request(id0);
        uint256 id1 = _bothSides();
        vm.warp(game.getRound(id1).lockAt);
        uint256 price = game.vrfPrice();
        wrapper.setReuseId(true);
        vm.expectRevert(CatWars.DuplicateRequestId.selector);
        game.requestResult{value: price}(id1);
        assertEq(wrapper.requestCount(), 1);
        assertEq(uint8(game.getRound(id1).status), uint8(CatWars.Status.Open));
        assertEq(address(game).balance, 6 ether);
    }

    function test_revertingAndGasExhaustingReceiversDoNotBlockBatch() public {
        uint256 id = _open();
        TestReceiver bad = new TestReceiver(game);
        TestReceiver gasBurner = new TestReceiver(game);
        bad.bet{value: 1 ether}(id, 0);
        gasBurner.bet{value: 1 ether}(id, 0);
        _bet(id, alice, 0, 2 ether);
        bad.configure(true, false, false);
        gasBurner.configure(false, true, false);
        vm.prank(owner);
        game.cancelRound(id);
        address[] memory players = new address[](5);
        players[0] = address(bad);
        players[1] = address(gasBurner);
        players[2] = alice;
        players[3] = address(bad);
        players[4] = outsider;
        game.claimMany(id, players);
        assertEq(alice.balance, 100 ether);
        assertEq(game.owed(address(bad)), 1 ether);
        assertEq(game.owed(address(gasBurner)), 1 ether);
        assertTrue(game.getBet(id, address(bad)).claimed);
        vm.expectRevert(CatWars.TransferFailed.selector);
        bad.withdraw();
        assertEq(game.owed(address(bad)), 1 ether);
        bad.configure(false, false, false);
        bad.withdraw();
        assertEq(address(bad).balance, 1 ether);
        assertEq(game.owed(address(bad)), 0);
        gasBurner.configure(false, false, false);
        gasBurner.withdraw();
        assertEq(address(game).balance, 0);
    }

    function test_reentrancyCannotDoubleClaimOrWithdraw() public {
        uint256 id = _open();
        TestReceiver attacker = new TestReceiver(game);
        attacker.bet{value: 1 ether}(id, 0);
        _bet(id, alice, 0, 2 ether);
        vm.prank(owner);
        game.cancelRound(id);
        attacker.configure(false, false, true);
        game.claimFor(id, address(attacker));
        assertFalse(attacker.reentered());
        assertEq(address(attacker).balance, 1 ether);
        assertEq(address(game).balance, 2 ether);
        vm.expectRevert(CatWars.NothingToClaim.selector);
        game.claimFor(id, address(attacker));
        game.claimFor(id, alice);
        assertEq(address(game).balance, 0);

        uint256 second = _open();
        attacker.bet{value: 2 ether}(second, 0);
        vm.prank(owner);
        game.cancelRound(second);
        attacker.configure(true, false, false);
        game.claimFor(second, address(attacker));
        attacker.configure(false, false, true);
        attacker.withdraw();
        assertFalse(attacker.reentered());
        assertEq(game.owed(address(attacker)), 0);
        assertEq(address(game).balance, 0);
    }

    function test_failedRequestRefundIsCreditedWithoutBlockingProgress() public {
        TestReceiver requester = new TestReceiver(game);
        requester.configure(true, false, false);
        uint256 id = _bothSides();
        vm.warp(game.getRound(id).lockAt);
        uint256 price = game.vrfPrice();
        requester.request{value: price + 1 ether}(id);
        assertEq(game.owed(address(requester)), 1 ether);
        assertEq(address(game).balance, 4 ether);
        assertEq(uint8(game.getRound(id).status), uint8(CatWars.Status.Requested));
        uint256 empty = _open();
        vm.warp(game.getRound(empty).lockAt);
        requester.request{value: 2 ether}(empty);
        assertEq(game.owed(address(requester)), 3 ether);
        requester.configure(false, false, false);
        requester.withdraw();
        assertEq(address(requester).balance, 3 ether);
        assertEq(address(game).balance, 3 ether);
    }

    function test_pauseOnlyBlocksNewRounds() public {
        uint256 id = _bothSides();
        vm.prank(owner);
        game.pause();
        vm.prank(owner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        game.openRound(2, 3);
        _bet(id, alice, 0, 1 ether);
        _finish(id, uint256(keccak256("paused")));
        address[] memory players = new address[](2);
        players[0] = alice;
        players[1] = bob;
        game.claimMany(id, players);
        vm.prank(owner);
        game.withdraw();
        assertEq(address(game).balance, 0);
        vm.prank(owner);
        game.unpause();
        uint256 next = _bothSides();
        vm.prank(owner);
        game.pause();
        vm.prank(owner);
        game.cancelRound(next);
        game.claimFor(next, alice);
        vm.prank(bob);
        game.claim(next);
        assertEq(address(game).balance, 0);
    }

    function test_rakeSnapshotDurationBoundsAndTreasuryAtSettlement() public {
        uint256 id = _bothSides();
        uint256 lockAt = game.getRound(id).lockAt;
        vm.startPrank(owner);
        game.setRakeBps(1000);
        game.setBettingDuration(60);
        game.setTreasury(carol);
        vm.expectRevert(CatWars.InvalidSetting.selector);
        game.setRakeBps(1001);
        vm.expectRevert(CatWars.InvalidSetting.selector);
        game.setBettingDuration(59);
        vm.expectRevert(CatWars.InvalidSetting.selector);
        game.setBettingDuration(1 days + 1);
        vm.expectRevert(CatWars.InvalidSetting.selector);
        game.setMinBet(0);
        vm.expectRevert(CatWars.InvalidAddress.selector);
        game.setTreasury(address(0));
        vm.stopPrank();
        assertEq(game.getRound(id).lockAt, lockAt);
        _finish(id, 42);
        assertEq(game.getRound(id).rakeBps, 500);
        assertEq(game.getRound(id).rake, 0.15 ether);
        assertEq(game.owed(carol), 0.15 ether);
        assertEq(game.owed(owner), 0);
        uint256 next = _open();
        assertEq(game.getRound(next).rakeBps, 1000);
        assertEq(game.getRound(next).lockAt, block.timestamp + 60);
    }

    function test_adminAccessAndTwoStepOwnership() public {
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeCall(game.setRakeBps, (100));
        calls[1] = abi.encodeCall(game.setBettingDuration, (120));
        calls[2] = abi.encodeCall(game.setMinBet, (1));
        calls[3] = abi.encodeCall(game.setTreasury, (alice));
        calls[4] = abi.encodeCall(game.setKeeper, (alice));
        calls[5] = abi.encodeCall(game.pause, ());
        calls[6] = abi.encodeCall(game.unpause, ());
        calls[7] = abi.encodeCall(game.transferOwnership, (alice));
        calls[8] = abi.encodeCall(game.renounceOwnership, ());
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory result) = address(game).call(calls[i]);
            assertFalse(ok);
            assertEq(result, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        }
        vm.prank(owner);
        game.transferOwnership(alice);
        assertEq(game.owner(), owner);
        assertEq(game.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        game.acceptOwnership();
        vm.prank(alice);
        game.acceptOwnership();
        assertEq(game.owner(), alice);
        // Treasury/keeper do not silently change with ownership.
        assertEq(game.treasury(), owner);
        assertEq(game.keeper(), owner);
        vm.prank(alice);
        game.setKeeper(address(0));
        vm.prank(owner);
        vm.expectRevert(CatWars.UnauthorizedKeeper.selector);
        game.openRound(0, 1);
    }

    function test_noOwnerWithdrawalNoDirectEthNoEarlyClaim() public {
        uint256 id = _bothSides();
        vm.prank(owner);
        vm.expectRevert(CatWars.NothingToWithdraw.selector);
        game.withdraw();
        vm.expectRevert(CatWars.WrongStatus.selector);
        game.claimFor(id, alice);
        (bool accepted,) = address(game).call{value: 1 ether}("");
        assertFalse(accepted);
        vm.prank(owner);
        (bool drained,) = address(game).call(abi.encodeWithSignature("emergencyWithdraw()"));
        assertFalse(drained);
        assertEq(address(game).balance, 3 ether);
    }

    function test_batchSkipsLosersAndDuplicateClaims() public {
        uint256 id = _bothSides();
        _finish(id, 7);
        address[] memory players = new address[](5);
        players[0] = alice;
        players[1] = bob;
        players[2] = alice;
        players[3] = bob;
        players[4] = outsider;
        game.claimMany(id, players);
        uint256 afterClaims = address(game).balance;
        game.claimMany(id, players);
        assertEq(address(game).balance, afterClaims);
        assertEq(afterClaims, game.owed(owner));
        address winner = game.getRound(id).winner == 0 ? alice : bob;
        vm.expectRevert(CatWars.NothingToClaim.selector);
        game.claimFor(id, winner);
    }

    function test_zeroRakeAndRoundingDustRemainSolvent() public {
        vm.startPrank(owner);
        game.setRakeBps(0);
        game.setMinBet(1);
        vm.stopPrank();
        uint256 word = uint256(keccak256("dust"));
        (uint8 winner,,,) = CatWarsEngine.simulate(0, 1, bytes32(word));
        uint256 id = _open();
        _bet(id, alice, winner, 1);
        _bet(id, carol, winner, 2);
        _bet(id, bob, 1 - winner, 1);
        _finish(id, word);
        game.claimFor(id, alice);
        game.claimFor(id, carol);
        assertEq(address(game).balance, 1);
        assertEq(game.owed(owner), 0);
    }

    function testFuzz_lifecycleConservesFunds(uint96 a, uint96 b, uint96 c, uint256 word, uint16 rake) public {
        uint256 sa = bound(a, 0.001 ether, 10 ether);
        uint256 sb = bound(b, 0.001 ether, 10 ether);
        uint256 sc = bound(c, 0.001 ether, 10 ether);
        rake = uint16(bound(rake, 0, 1000));
        vm.prank(owner);
        game.setRakeBps(rake);
        uint256 id = _open();
        _bet(id, alice, 0, sa);
        _bet(id, carol, 0, sc);
        _bet(id, bob, 1, sb);
        _finish(id, word);
        CatWars.Round memory r = game.getRound(id);
        uint256 pool = sa + sb + sc;
        uint256 expectedRake = pool * rake / 10_000;
        assertEq(game.owed(owner), expectedRake);
        uint256 totalPayout;
        address[3] memory players = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            CatWars.Bet memory bet = game.getBet(id, players[i]);
            if (bet.side != r.winner) continue;
            uint256 amount = bet.amount * (pool - expectedRake) / (r.winner == 0 ? sa + sc : sb);
            assertEq(game.pendingPayout(id, players[i]), amount);
            totalPayout += amount;
            game.claimFor(id, players[i]);
        }
        assertEq(address(game).balance, pool - totalPayout);
        assertGe(address(game).balance, expectedRake);
        assertLe(address(game).balance - expectedRake, 1);
    }
}
