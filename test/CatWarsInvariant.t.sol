// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CatWars} from "../src/CatWars.sol";
import {CatWarsEngine} from "../src/CatWarsEngine.sol";
import {MockVRFWrapper} from "./mocks/MockVRFWrapper.sol";
import {TestReceiver} from "./mocks/Receivers.sol";

contract CatWarsHandler is Test {
    CatWars public game;
    MockVRFWrapper public wrapper;
    TestReceiver public receiver;
    address[] public actors;
    uint256 public initialFunds;
    uint256 public successfulBets;
    uint256 public successfulRequests;
    uint256 public successfulSettles;
    uint256 public successfulCancels;
    uint256 public successfulClaims;

    constructor() {
        wrapper = new MockVRFWrapper();
        game = new CatWars(address(wrapper), address(this));
        receiver = new TestReceiver(game);
        vm.deal(address(this), 100_000 ether);
        initialFunds = address(this).balance;
        for (uint256 i; i < 6; ++i) {
            address actor = address(uint160(uint256(keccak256(abi.encode("invariant bettor", i)))));
            actors.push(actor);
            vm.deal(actor, 10_000 ether);
            initialFunds += actor.balance;
        }
        actors.push(address(receiver));
        game.openRound(0, 1);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function open(uint8 a, uint8 b) external {
        if (game.getRound(game.roundCount() - 1).status == CatWars.Status.Open) return;
        if (game.paused()) return;
        a %= 8;
        b %= 7;
        if (b >= a) ++b;
        game.openRound(a, b);
    }

    function bet(uint256 actorSeed, uint8 side, uint96 amountSeed) public {
        uint256 id = game.roundCount() - 1;
        CatWars.Round memory r = game.getRound(id);
        if (r.status != CatWars.Status.Open || block.timestamp >= r.lockAt) return;
        address actor = actors[actorSeed % actors.length];
        CatWars.Bet memory b = game.getBet(id, actor);
        side = b.amount != 0 ? b.side : side % 2;
        uint256 amount = bound(amountSeed, game.minBet(), 2 ether);
        if (actor == address(receiver)) {
            receiver.bet{value: amount}(id, side);
        } else {
            vm.prank(actor);
            game.placeBet{value: amount}(id, side);
        }
        ++successfulBets;
    }

    function advance(uint32 secondsSeed) external {
        vm.warp(block.timestamp + bound(secondsSeed, 0, 25 hours));
    }

    function request(uint256 roundSeed, uint96 excessSeed) public {
        uint256 id = roundSeed % game.roundCount();
        CatWars.Round memory r = game.getRound(id);
        if (r.status != CatWars.Status.Open) return;
        if (block.timestamp < r.lockAt) vm.warp(r.lockAt);
        game.requestResult{value: game.vrfPrice() + bound(excessSeed, 0, 0.01 ether)}(id);
        ++successfulRequests;
    }

    function fulfill(uint256 roundSeed, uint256 word) public {
        uint256 id = roundSeed % game.roundCount();
        CatWars.Round memory r = game.getRound(id);
        if (r.status == CatWars.Status.Open) return;
        // Includes duplicate and stale callback delivery, to exercise idempotence.
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        wrapper.deliver(address(game), r.requestId, words);
    }

    function settle(uint256 roundSeed) public {
        uint256 id = roundSeed % game.roundCount();
        if (game.getRound(id).status != CatWars.Status.Fulfilled) return;
        game.settle(id);
        ++successfulSettles;
    }

    function cancel(uint256 roundSeed, bool asOutsider) external {
        uint256 id = roundSeed % game.roundCount();
        CatWars.Round memory r = game.getRound(id);
        if (r.status == CatWars.Status.Open) {
            if (asOutsider && block.timestamp <= r.lockAt + 1 hours) return;
        } else if (r.status == CatWars.Status.Requested) {
            if (block.timestamp <= r.requestedAt + 24 hours) return;
        } else {
            return;
        }
        if (asOutsider) vm.prank(actors[0]);
        game.cancelRound(id);
        ++successfulCancels;
    }

    function claim(uint256 roundSeed, uint256 actorSeed, uint8 mode) external {
        uint256 id = roundSeed % game.roundCount();
        CatWars.Round memory r = game.getRound(id);
        if (r.status != CatWars.Status.Settled && r.status != CatWars.Status.Cancelled) return;
        receiver.configure(mode % 3 == 0, mode % 3 == 1, false);
        address actor = actors[actorSeed % actors.length];
        if (mode % 2 == 0) {
            game.claimMany(id, actors);
        } else if (game.pendingPayout(id, actor) != 0) {
            game.claimFor(id, actor);
        }
        ++successfulClaims;
    }

    function withdraw(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        if (game.owed(actor) != 0) {
            if (actor == address(receiver)) {
                receiver.configure(false, false, true);
                receiver.withdraw();
            } else {
                vm.prank(actor);
                game.withdraw();
            }
        }
        if (game.owed(address(this)) != 0) game.withdraw();
    }

    function configure(uint16 rake, uint32 duration, uint96 minimum, uint256 treasurySeed, bool paused) external {
        game.setRakeBps(uint16(bound(rake, 0, 1000)));
        game.setBettingDuration(bound(duration, 60, 1 days));
        game.setMinBet(bound(minimum, 1, 0.01 ether));
        game.setTreasury(treasurySeed % 2 == 0 ? address(this) : actors[treasurySeed % actors.length]);
        if (paused && !game.paused()) game.pause();
        if (!paused && game.paused()) game.unpause();
    }

    /// @dev Guarantees that fuzzing also reaches deep lifecycle paths amid arbitrary other actions.
    function lifecycle(uint256 word) external {
        uint256 id = game.roundCount() - 1;
        CatWars.Round memory r = game.getRound(id);
        if (r.status == CatWars.Status.Open && block.timestamp < r.lockAt) {
            bet(0, 0, 0.01 ether);
            bet(1, 1, 0.02 ether);
            bet(6, 0, 0.01 ether);
        }
        request(id, 0);
        fulfill(id, word);
        settle(id);
    }

    receive() external payable {}
}

contract CatWarsInvariantTest is StdInvariant, Test {
    CatWarsHandler private handler;
    CatWars private game;

    function setUp() public {
        handler = new CatWarsHandler();
        game = handler.game();
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.bet.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.request.selector;
        selectors[4] = handler.fulfill.selector;
        selectors[5] = handler.settle.selector;
        selectors[6] = handler.cancel.selector;
        selectors[7] = handler.claim.selector;
        selectors[8] = handler.withdraw.selector;
        selectors[9] = handler.configure.selector;
        selectors[10] = handler.lifecycle.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_solvencyAndPerRoundAccounting() public view {
        uint256 liabilities = game.owed(address(handler));
        for (uint256 a; a < handler.actorCount(); ++a) {
            liabilities += game.owed(handler.actors(a));
        }
        uint256 openRounds;
        for (uint256 id; id < game.roundCount(); ++id) {
            CatWars.Round memory r = game.getRound(id);
            uint256[2] memory totals;
            uint256[2] memory bettors;
            uint256 pool = r.total0 + r.total1;
            uint256 rake = pool * r.rakeBps / 10_000;
            if (r.status == CatWars.Status.Open) ++openRounds;
            for (uint256 a; a < handler.actorCount(); ++a) {
                CatWars.Bet memory b = game.getBet(id, handler.actors(a));
                if (b.amount == 0) continue;
                totals[b.side] += b.amount;
                ++bettors[b.side];
                if (
                    r.status == CatWars.Status.Open || r.status == CatWars.Status.Requested
                        || r.status == CatWars.Status.Fulfilled
                ) {
                    liabilities += b.amount;
                    assertFalse(b.claimed);
                } else if (!b.claimed) {
                    if (r.status == CatWars.Status.Cancelled) {
                        liabilities += b.amount;
                    } else if (b.side == r.winner) {
                        liabilities += b.amount * (pool - rake) / (r.winner == 0 ? r.total0 : r.total1);
                    }
                }
            }
            assertEq(totals[0], r.total0);
            assertEq(totals[1], r.total1);
            assertEq(bettors[0], r.bettors0);
            assertEq(bettors[1], r.bettors1);
            if (r.status == CatWars.Status.Settled) {
                assertEq(r.rake, rake);
                (uint8 winner, uint8 turns,,) = CatWarsEngine.simulate(r.catA, r.catB, bytes32(r.randomWord));
                assertEq(r.winner, winner);
                assertEq(r.turns, turns);
            }
        }
        assertLe(openRounds, 1);
        assertGe(address(game).balance, liabilities);
    }

    function invariant_totalEthConserved() public view {
        uint256 funds = address(game).balance + address(handler).balance + address(handler.wrapper()).balance;
        for (uint256 i; i < handler.actorCount(); ++i) {
            funds += handler.actors(i).balance;
        }
        assertEq(funds, handler.initialFunds());
    }

    function test_handlerReachesPaymentsAndSettlement() public {
        handler.lifecycle(uint256(keccak256("invariant smoke test")));
        handler.claim(0, 0, 0);
        handler.withdraw(6);
        invariant_solvencyAndPerRoundAccounting();
        invariant_totalEthConserved();
        assertEq(handler.successfulBets(), 3);
        assertEq(handler.successfulRequests(), 1);
        assertEq(handler.successfulSettles(), 1);
        assertEq(handler.successfulClaims(), 1);
    }
}
