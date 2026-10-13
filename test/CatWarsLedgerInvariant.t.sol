// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CatWars} from "src/CatWars.sol";
import {CatWarsEngine} from "src/CatWarsEngine.sol";
import {MockVRFWrapper} from "./mocks/MockVRFWrapper.sol";
import {TestReceiver} from "./mocks/Receivers.sol";

/// @dev Ghosts come from submitted inputs, never from getBet/pendingPayout/owed.
/// All funding happens once; later actions cannot hide a shortfall with vm.deal.
contract CatWarsLedgerHandler is Test {
    struct RoundModel {
        CatWars.Status status;
        uint8 catA;
        uint8 catB;
        uint16 rakeBps;
        uint256 lockAt;
        uint256 requestedAt;
        uint256 requestId;
        uint256 randomWord;
        uint8 winner;
        uint8 turns;
        uint256 rake;
        uint256[2] totals;
    }

    struct BetModel {
        uint256 amount;
        uint8 side;
        bool claimed;
    }

    CatWars public immutable game;
    MockVRFWrapper public immutable wrapper;
    TestReceiver public immutable receiver;
    address[5] public actors;
    RoundModel[] internal rounds;
    mapping(uint256 => mapping(uint256 => BetModel)) internal bets;
    mapping(address => uint256) internal credits;
    mapping(address => uint256) internal balances;
    address internal treasury;
    uint16 internal rakeBps = 500;
    uint256 internal duration = 300;
    uint256 internal minimum = 0.001 ether;
    bool internal paused;
    uint256 internal paidToWrapper;
    uint256 internal expectedGameBalance;
    uint256 public betCalls;
    uint256 public requestCalls;
    uint256 public settleCalls;
    uint256 public cancelCalls;
    uint256 public claimCalls;
    uint256 public creditCalls;

    constructor() {
        wrapper = new MockVRFWrapper();
        game = new CatWars(address(wrapper), address(this));
        receiver = new TestReceiver(game);
        for (uint256 i; i < 5; ++i) {
            actors[i] = i == 4 ? address(receiver) : makeAddr(string.concat("game ledger actor ", vm.toString(i)));
            vm.deal(actors[i], 10_000 ether);
            balances[actors[i]] = 10_000 ether;
        }
        treasury = address(this);
        open(0, 1);
    }

    function open(uint8 a, uint8 b) public {
        if (paused || (rounds.length != 0 && rounds[rounds.length - 1].status == CatWars.Status.Open)) return;
        a %= 8;
        b %= 7;
        if (b >= a) ++b;
        uint256 id = game.openRound(a, b);
        assertEq(id, rounds.length);
        RoundModel storage r = rounds.push();
        r.catA = a;
        r.catB = b;
        r.lockAt = vm.getBlockTimestamp() + duration;
        r.rakeBps = rakeBps;
    }

    function bet(uint256 actorSeed, uint256 amountSeed, uint8 side) public {
        uint256 id = rounds.length - 1;
        RoundModel storage r = rounds[id];
        if (r.status != CatWars.Status.Open || vm.getBlockTimestamp() >= r.lockAt) return;
        uint256 a = actorSeed % 5;
        BetModel storage b = bets[id][a];
        side = b.amount == 0 ? side % 2 : b.side;
        uint256 amount = bound(amountSeed, minimum, 2 ether);
        vm.prank(actors[a]);
        game.placeBet{value: amount}(id, side);
        b.side = side;
        b.amount += amount;
        r.totals[side] += amount;
        balances[actors[a]] -= amount;
        expectedGameBalance += amount;
        ++betCalls;
    }

    function advance(uint256 secondsSeed) public {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 25 hours));
    }

    function request(uint256 roundSeed, uint256 callerSeed, uint256 extraSeed, bool rejectRefund) public {
        uint256 id = roundSeed % rounds.length;
        RoundModel storage r = rounds[id];
        if (r.status != CatWars.Status.Open) return;
        if (vm.getBlockTimestamp() < r.lockAt) vm.warp(r.lockAt);
        address caller = actors[callerSeed % 5];
        receiver.configure(rejectRefund, false, false);
        uint256 extra = bound(extraSeed, 0, 0.02 ether);
        uint256 fee = wrapper.calculateRequestPriceNative(150_000, 1);
        bool cancelled = r.totals[0] == 0 || r.totals[1] == 0;
        vm.prank(caller);
        game.requestResult{value: fee + extra}(id);
        uint256 refund = cancelled ? fee + extra : extra;
        balances[caller] -= fee + extra;
        if (caller == address(receiver) && rejectRefund) {
            credits[caller] += refund;
            expectedGameBalance += refund;
            if (refund != 0) ++creditCalls;
        } else {
            balances[caller] += refund;
        }
        if (cancelled) {
            r.status = CatWars.Status.Cancelled;
            ++cancelCalls;
        } else {
            r.status = CatWars.Status.Requested;
            r.requestedAt = vm.getBlockTimestamp();
            r.requestId = wrapper.lastRequestId();
            paidToWrapper += fee;
            ++requestCalls;
        }
    }

    function callback(uint256 roundSeed, uint256 word, uint8 mode) public {
        uint256 id = roundSeed % rounds.length;
        RoundModel storage r = rounds[id];
        uint256[] memory words = new uint256[](mode % 3 == 1 ? 0 : 1);
        if (words.length != 0) words[0] = word;
        uint256 requestId = mode % 3 == 2 ? type(uint256).max : r.requestId;
        wrapper.deliver(address(game), requestId, words);
        if (mode % 3 == 0 && r.status == CatWars.Status.Requested) {
            r.status = CatWars.Status.Fulfilled;
            r.randomWord = word;
        }
    }

    function settle(uint256 roundSeed) public {
        uint256 id = roundSeed % rounds.length;
        RoundModel storage r = rounds[id];
        if (r.status != CatWars.Status.Fulfilled) return;
        vm.prank(actors[0]);
        game.settle(id);
        (r.winner, r.turns,,) = CatWarsEngine.simulate(r.catA, r.catB, bytes32(r.randomWord));
        r.rake = (r.totals[0] + r.totals[1]) * r.rakeBps / 10_000;
        credits[treasury] += r.rake;
        r.status = CatWars.Status.Settled;
        ++settleCalls;
    }

    function cancel(uint256 roundSeed, bool permissionless) public {
        uint256 id = roundSeed % rounds.length;
        RoundModel storage r = rounds[id];
        if (r.status == CatWars.Status.Open) {
            if (permissionless && vm.getBlockTimestamp() <= r.lockAt + 1 hours) return;
        } else if (r.status == CatWars.Status.Requested) {
            if (vm.getBlockTimestamp() <= r.requestedAt + 24 hours) return;
        } else {
            return;
        }
        if (permissionless) vm.prank(actors[0]);
        game.cancelRound(id);
        r.status = CatWars.Status.Cancelled;
        ++cancelCalls;
    }

    function claim(uint256 roundSeed, uint256 actorSeed, bool batch, bool rejectPayment) public {
        uint256 id = roundSeed % rounds.length;
        CatWars.Status status = rounds[id].status;
        if (status != CatWars.Status.Settled && status != CatWars.Status.Cancelled) return;
        receiver.configure(rejectPayment, false, false);
        if (batch) {
            // Duplicates, non-bettors, losers and already claimed entries must be harmless.
            address[] memory players = new address[](7);
            for (uint256 i; i < 5; ++i) {
                players[i] = actors[i];
            }
            players[5] = actors[4];
            players[6] = address(this);
            vm.prank(actors[0]);
            game.claimMany(id, players);
            for (uint256 i; i < 5; ++i) {
                _recordClaim(id, i, rejectPayment);
            }
        } else {
            uint256 a = actorSeed % 5;
            if (!_eligible(id, a)) return;
            vm.prank(actors[(a + 1) % 5]);
            game.claimFor(id, actors[a]);
            _recordClaim(id, a, rejectPayment);
        }
        ++claimCalls;
    }

    function withdraw(uint256 actorSeed, bool rejectPayment) public {
        address actor = actorSeed % 6 == 5 ? address(this) : actors[actorSeed % 6];
        uint256 amount = credits[actor];
        receiver.configure(rejectPayment, false, false);
        vm.prank(actor);
        if (amount == 0) {
            vm.expectRevert(CatWars.NothingToWithdraw.selector);
            game.withdraw();
        } else if (actor == address(receiver) && rejectPayment) {
            vm.expectRevert(CatWars.TransferFailed.selector);
            game.withdraw();
        } else {
            game.withdraw();
            credits[actor] = 0;
            balances[actor] += amount;
            expectedGameBalance -= amount;
        }
    }

    function configure(uint16 rakeSeed, uint256 durationSeed, uint256 minSeed, uint256 treasurySeed, bool pause_)
        public
    {
        rakeBps = uint16(bound(rakeSeed, 0, 1000));
        duration = bound(durationSeed, 60, 1 days);
        minimum = bound(minSeed, 1, 0.01 ether);
        treasury = treasurySeed % 6 == 5 ? address(this) : actors[treasurySeed % 6];
        game.setRakeBps(rakeBps);
        game.setBettingDuration(duration);
        game.setMinBet(minimum);
        game.setTreasury(treasury);
        if (pause_ != paused) {
            if (pause_) game.pause();
            else game.unpause();
            paused = pause_;
        }
    }

    /// @dev This extra action reaches deep states without removing independent actions above.
    function progress(uint256 word) public {
        uint256 id = rounds.length - 1;
        if (rounds[id].status != CatWars.Status.Open) {
            open(uint8(word), uint8(word >> 8));
            id = rounds.length - 1;
        }
        bet(0, 0.01 ether, 0);
        bet(1, 0.02 ether, 1);
        bet(4, 0.03 ether, 0);
        request(id, 4, 0.01 ether, true);
        callback(id, word, 0);
        settle(id);
    }

    function _eligible(uint256 id, uint256 a) internal view returns (bool) {
        BetModel storage b = bets[id][a];
        return
            b.amount != 0 && !b.claimed
                && (rounds[id].status == CatWars.Status.Cancelled || b.side == rounds[id].winner);
    }

    function _entitlement(uint256 id, uint256 a) internal view returns (uint256) {
        RoundModel storage r = rounds[id];
        BetModel storage b = bets[id][a];
        if (r.status == CatWars.Status.Cancelled) return b.amount;
        if (r.status != CatWars.Status.Settled || b.side != r.winner) return 0;
        return b.amount * (r.totals[0] + r.totals[1] - r.rake) / r.totals[r.winner];
    }

    function _recordClaim(uint256 id, uint256 a, bool rejectPayment) internal {
        if (!_eligible(id, a)) return;
        uint256 amount = _entitlement(id, a);
        bets[id][a].claimed = true;
        if (a == 4 && rejectPayment) {
            credits[actors[a]] += amount;
            if (amount != 0) ++creditCalls;
        } else {
            balances[actors[a]] += amount;
            expectedGameBalance -= amount;
        }
    }

    /// @notice SPEC 2.2/2.6: independent stakes, claims, credits and dust exhaust the balance.
    function assertLedger() public view {
        assertEq(game.roundCount(), rounds.length);
        assertEq(address(game).balance, expectedGameBalance, "unexpected game cash movement");
        assertEq(address(wrapper).balance, paidToWrapper, "VRF consumed funds other than caller fees");
        uint256 liabilities;
        uint256 dust;
        for (uint256 i; i < 6; ++i) {
            address a = i == 5 ? address(this) : actors[i];
            assertEq(game.owed(a), credits[a], "wrong beneficiary or lost/duplicated credit");
            assertEq(a.balance, balances[a], "wrong recipient or payment amount");
            liabilities += credits[a];
        }
        for (uint256 id; id < rounds.length; ++id) {
            RoundModel storage m = rounds[id];
            CatWars.Round memory r = game.getRound(id);
            assertEq(uint8(r.status), uint8(m.status), "invalid state transition");
            assertEq(r.catA, m.catA);
            assertEq(r.catB, m.catB);
            assertEq(r.lockAt, m.lockAt);
            assertEq(r.rakeBps, m.rakeBps);
            assertEq(r.total0, m.totals[0]);
            assertEq(r.total1, m.totals[1]);
            assertEq(r.requestId, m.requestId);
            assertEq(r.requestedAt, m.requestedAt);
            assertEq(r.randomWord, m.randomWord, "randomness overwritten by stale callback");
            assertEq(r.winner, m.winner);
            assertEq(r.turns, m.turns);
            assertEq(r.rake, m.rake);
            uint256[2] memory counts;
            uint256 entitlements;
            for (uint256 a; a < 5; ++a) {
                BetModel storage b = bets[id][a];
                CatWars.Bet memory actual = game.getBet(id, actors[a]);
                assertEq(actual.amount, b.amount, "stake ledger mismatch");
                assertEq(actual.side, b.side);
                assertEq(actual.claimed, b.claimed, "claim was lost or repeated");
                if (b.amount != 0) ++counts[b.side];
                uint256 payout = _entitlement(id, a);
                entitlements += payout;
                assertEq(game.pendingPayout(id, actors[a]), b.claimed ? 0 : payout);
                if (!b.claimed) liabilities += payout;
            }
            assertEq(r.bettors0, counts[0]);
            assertEq(r.bettors1, counts[1]);
            if (m.status == CatWars.Status.Settled) {
                uint256 remainder = m.totals[0] + m.totals[1] - m.rake - entitlements;
                assertLt(remainder, counts[m.winner], "more than rounding dust retained");
                dust += remainder;
            } else if (m.status != CatWars.Status.Cancelled) {
                liabilities += m.totals[0] + m.totals[1];
            }
        }
        assertEq(address(game).balance, liabilities + dust, "cash does not equal liabilities plus dust");
    }

    /// @dev Called after each random sequence to prove that liabilities are actually payable.
    function closeAll() external {
        vm.warp(vm.getBlockTimestamp() + 26 hours);
        for (uint256 id; id < rounds.length; ++id) {
            cancel(id, true);
            settle(id);
            claim(id, 0, true, false);
        }
        for (uint256 a; a < 6; ++a) {
            withdraw(a, false);
        }
        assertLedger();
        for (uint256 id; id < rounds.length; ++id) {
            for (uint256 a; a < 5; ++a) {
                assertEq(game.pendingPayout(id, actors[a]), 0);
            }
        }
    }

    receive() external payable {}
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract CatWarsLedgerInvariantTest is StdInvariant, Test {
    CatWarsLedgerHandler internal handler;

    function setUp() public {
        handler = new CatWarsLedgerHandler();
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.bet.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.request.selector;
        selectors[4] = handler.callback.selector;
        selectors[5] = handler.settle.selector;
        selectors[6] = handler.cancel.selector;
        selectors[7] = handler.claim.selector;
        selectors[8] = handler.withdraw.selector;
        selectors[9] = handler.configure.selector;
        selectors[10] = handler.progress.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_independentLedgerAndStateMachine() public view {
        handler.assertLedger();
    }

    function afterInvariant() public {
        handler.closeAll();
    }

    function test_ledgerExercisesCreditsSettlementTimeoutsAndCompleteExit() public {
        handler.progress(uint256(keccak256("ledger smoke")));
        handler.assertLedger();
        handler.claim(0, 0, true, true);
        handler.withdraw(4, true);
        handler.configure(1000, 60, 1, 4, false);
        handler.open(2, 3);
        handler.bet(0, 1, 0);
        handler.bet(1, 2, 1);
        handler.request(1, 4, 1, true);
        handler.advance(25 hours);
        handler.cancel(1, true);
        handler.callback(1, type(uint256).max, 0);
        handler.assertLedger();
        handler.closeAll();
        assertEq(handler.betCalls(), 5);
        assertEq(handler.requestCalls(), 2);
        assertEq(handler.settleCalls(), 1);
        assertEq(handler.cancelCalls(), 1);
        assertGe(handler.claimCalls(), 2);
        assertGe(handler.creditCalls(), 2);
    }
}
