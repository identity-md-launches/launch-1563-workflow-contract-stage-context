// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VRFV2PlusWrapperConsumerBase} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFV2PlusWrapperConsumerBase.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {CatWarsEngine} from "./CatWarsEngine.sol";

/// @title CAT WARS — native-ETH pari-mutuel cat fights
/// @notice Request callers fund VRF separately. The owner has no custody withdrawal.
/// @dev The vendored Chainlink base resolves LINK lazily to permit empty-chain construction.
contract CatWars is Ownable2Step, ReentrancyGuard, Pausable, VRFV2PlusWrapperConsumerBase {
    enum Status {
        Open,
        Requested,
        Fulfilled,
        Settled,
        Cancelled
    }

    struct Round {
        uint8 catA;
        uint8 catB;
        Status status;
        uint16 rakeBps;
        uint8 winner;
        uint8 turns;
        uint256 lockAt;
        uint256 requestedAt;
        uint256 requestId;
        uint256 total0;
        uint256 total1;
        uint256 bettors0;
        uint256 bettors1;
        uint256 randomWord;
        uint256 rake;
    }

    struct Bet {
        uint8 side;
        uint256 amount;
        bool claimed;
    }

    uint8 public constant CATS_COUNT = 8;
    uint32 public constant CALLBACK_GAS_LIMIT = 150_000;
    uint16 public constant MAX_RAKE_BPS = 1000;
    uint256 public constant OPEN_TIMEOUT = 1 hours;
    uint256 public constant REQUEST_TIMEOUT = 24 hours;
    // Bounded receiver gas prevents a malicious fallback from exhausting a claimMany batch.
    uint256 public constant PAYOUT_GAS_LIMIT = 50_000;

    uint16 public rakeBps = 500;
    uint256 public bettingDuration = 300;
    uint256 public minBet = 0.001 ether;
    address public treasury;
    address public keeper;
    uint256 public roundCount;
    mapping(address => uint256) public owed;

    mapping(uint256 => Round) private _rounds;
    mapping(uint256 => mapping(address => Bet)) private _bets;
    // Store roundId + 1 so unknown requests cannot accidentally fulfill round zero.
    mapping(uint256 => uint256) private _requestRoundPlusOne;

    error InvalidAddress();
    error InvalidCats();
    error UnauthorizedKeeper();
    error NoRounds();
    error UnknownRound(uint256 roundId);
    error WrongStatus();
    error PreviousRoundOpen();
    error BettingClosed();
    error BettingStillOpen();
    error InvalidSide();
    error BelowMinimumBet();
    error CannotSwitchSide();
    error InsufficientVrfPayment(uint256 required, uint256 supplied);
    error WrapperUnavailable();
    error DuplicateRequestId();
    error CancellationNotAllowed();
    error NothingToClaim();
    error NothingToWithdraw();
    error TransferFailed();
    error InvalidSetting();

    event RoundOpened(uint256 indexed roundId, uint8 catA, uint8 catB, uint256 lockAt, uint16 rakeBps);
    event BetPlaced(
        uint256 indexed roundId, address indexed player, uint8 side, uint256 amount, uint256 total0, uint256 total1
    );
    event ResultRequested(uint256 indexed roundId, uint256 requestId, uint256 price);
    event RandomnessFulfilled(uint256 indexed roundId, uint256 randomWord);
    event RoundSettled(uint256 indexed roundId, bytes32 seed, uint8 winner, uint8 turns, uint256 pool, uint256 rake);
    event RoundCancelled(uint256 indexed roundId);
    event Claimed(uint256 indexed roundId, address indexed player, uint256 amount, bool sent);
    event Withdrawn(address indexed account, uint256 amount);
    event RefundCredited(address indexed account, uint256 amount);
    event RakeBpsChanged(uint16 previousValue, uint16 newValue);
    event BettingDurationChanged(uint256 previousValue, uint256 newValue);
    event MinBetChanged(uint256 previousValue, uint256 newValue);
    event TreasuryChanged(address indexed previousValue, address indexed newValue);
    event KeeperChanged(address indexed previousValue, address indexed newValue);

    constructor(address vrfWrapper, address owner_) Ownable(owner_) VRFV2PlusWrapperConsumerBase(vrfWrapper) {
        if (vrfWrapper == address(0)) revert InvalidAddress();
        treasury = owner_;
        keeper = owner_;
    }

    function openRound(uint8 catA, uint8 catB) external whenNotPaused returns (uint256 roundId) {
        if (msg.sender != owner() && msg.sender != keeper) revert UnauthorizedKeeper();
        if (catA >= CATS_COUNT || catB >= CATS_COUNT || catA == catB) revert InvalidCats();
        if (roundCount != 0 && _rounds[roundCount - 1].status == Status.Open) revert PreviousRoundOpen();
        roundId = roundCount++;
        Round storage r = _rounds[roundId];
        r.catA = catA;
        r.catB = catB;
        r.lockAt = block.timestamp + bettingDuration;
        r.rakeBps = rakeBps;
        emit RoundOpened(roundId, catA, catB, r.lockAt, r.rakeBps);
    }

    function placeBet(uint256 roundId, uint8 side) external payable nonReentrant {
        Round storage r = _round(roundId);
        if (r.status != Status.Open) revert WrongStatus();
        if (block.timestamp >= r.lockAt) revert BettingClosed();
        if (side >= 2) revert InvalidSide();
        if (msg.value < minBet) revert BelowMinimumBet();
        Bet storage b = _bets[roundId][msg.sender];
        if (b.amount == 0) {
            b.side = side;
            if (side == 0) ++r.bettors0;
            else ++r.bettors1;
        } else if (b.side != side) {
            revert CannotSwitchSide();
        }
        b.amount += msg.value;
        if (side == 0) r.total0 += msg.value;
        else r.total1 += msg.value;
        emit BetPlaced(roundId, msg.sender, side, msg.value, r.total0, r.total1);
    }

    function requestResult(uint256 roundId) external payable nonReentrant {
        Round storage r = _round(roundId);
        if (r.status != Status.Open) revert WrongStatus();
        if (block.timestamp < r.lockAt) revert BettingStillOpen();
        if (r.total0 == 0 || r.total1 == 0) {
            r.status = Status.Cancelled;
            emit RoundCancelled(roundId);
            _refund(msg.sender, msg.value);
            return;
        }

        uint256 price = vrfPrice();
        if (msg.value < price) revert InsufficientVrfPayment(price, msg.value);
        r.status = Status.Requested;
        r.requestedAt = block.timestamp;
        (uint256 requestId, uint256 paid) = requestRandomnessPayInNative(
            CALLBACK_GAS_LIMIT, 3, 1, VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: true}))
        );
        // Even if a wrapper's second quote differs, the transaction cannot spend player stakes.
        if (paid > msg.value) revert InsufficientVrfPayment(paid, msg.value);
        if (_requestRoundPlusOne[requestId] != 0) revert DuplicateRequestId();
        r.requestId = requestId;
        _requestRoundPlusOne[requestId] = roundId + 1;
        emit ResultRequested(roundId, requestId, paid);
        _refund(msg.sender, msg.value - paid);
    }

    /// @dev Authentication is in the Chainlink base. Unknown, empty and stale callbacks are no-ops.
    function fulfillRandomWords(uint256 requestId, uint256[] memory words) internal override {
        uint256 plusOne = _requestRoundPlusOne[requestId];
        if (plusOne == 0 || words.length == 0) return;
        Round storage r = _rounds[plusOne - 1];
        if (r.status != Status.Requested) return;
        r.randomWord = words[0];
        r.status = Status.Fulfilled;
        emit RandomnessFulfilled(plusOne - 1, words[0]);
    }

    function settle(uint256 roundId) external nonReentrant {
        Round storage r = _round(roundId);
        if (r.status != Status.Fulfilled) revert WrongStatus();
        bytes32 seed = bytes32(r.randomWord);
        (uint8 winner, uint8 turns,,) = CatWarsEngine.simulate(r.catA, r.catB, seed);
        uint256 pool = r.total0 + r.total1;
        uint256 rake = Math.mulDiv(pool, r.rakeBps, 10_000);
        r.winner = winner;
        r.turns = turns;
        r.rake = rake;
        r.status = Status.Settled;
        owed[treasury] += rake;
        emit RoundSettled(roundId, seed, winner, turns, pool, rake);
    }

    function cancelRound(uint256 roundId) external {
        Round storage r = _round(roundId);
        if (r.status == Status.Open) {
            if (msg.sender != owner() && msg.sender != keeper && block.timestamp <= r.lockAt + OPEN_TIMEOUT) {
                revert CancellationNotAllowed();
            }
        } else if (r.status == Status.Requested) {
            if (block.timestamp <= r.requestedAt + REQUEST_TIMEOUT) revert CancellationNotAllowed();
        } else {
            revert CancellationNotAllowed();
        }
        r.status = Status.Cancelled;
        emit RoundCancelled(roundId);
    }

    function claim(uint256 roundId) external nonReentrant {
        _claim(roundId, msg.sender, false);
    }

    function claimFor(uint256 roundId, address player) external nonReentrant {
        _claim(roundId, player, false);
    }

    /// @notice Skips losers, non-bettors and already claimed bets. Every payment goes to its bettor.
    function claimMany(uint256 roundId, address[] calldata players) external nonReentrant {
        Round storage r = _round(roundId);
        if (r.status != Status.Settled && r.status != Status.Cancelled) revert WrongStatus();
        for (uint256 i; i < players.length; ++i) {
            _claim(roundId, players[i], true);
        }
    }

    function withdraw() external nonReentrant {
        uint256 amount = owed[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        owed[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        (bool sent,) = msg.sender.call{value: amount}("");
        if (!sent) revert TransferFailed();
    }

    function _claim(uint256 roundId, address player, bool skipIneligible) private {
        Round storage r = _round(roundId);
        if (r.status != Status.Settled && r.status != Status.Cancelled) revert WrongStatus();
        Bet storage b = _bets[roundId][player];
        if (b.amount == 0 || b.claimed || (r.status == Status.Settled && b.side != r.winner)) {
            if (skipIneligible) return;
            revert NothingToClaim();
        }
        uint256 amount = _payout(r, b);
        b.claimed = true;
        bool sent = true;
        if (amount != 0) {
            (sent,) = player.call{value: amount, gas: PAYOUT_GAS_LIMIT}("");
            if (!sent) owed[player] += amount;
        }
        emit Claimed(roundId, player, amount, sent);
    }

    function _refund(address account, uint256 amount) private {
        if (amount == 0) return;
        (bool sent,) = account.call{value: amount, gas: PAYOUT_GAS_LIMIT}("");
        if (!sent) {
            owed[account] += amount;
            emit RefundCredited(account, amount);
        }
    }

    function _payout(Round storage r, Bet storage b) private view returns (uint256) {
        if (r.status == Status.Cancelled) return b.amount;
        return Math.mulDiv(b.amount, r.total0 + r.total1 - r.rake, r.winner == 0 ? r.total0 : r.total1);
    }

    function _round(uint256 roundId) private view returns (Round storage r) {
        if (roundId >= roundCount) revert UnknownRound(roundId);
        return _rounds[roundId];
    }

    /// @notice Reverts before the first round; round zero is a valid round after opening.
    function currentRoundId() external view returns (uint256) {
        if (roundCount == 0) revert NoRounds();
        return roundCount - 1;
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return _round(roundId);
    }

    function getBet(uint256 roundId, address player) external view returns (Bet memory) {
        _round(roundId);
        return _bets[roundId][player];
    }

    function pendingPayout(uint256 roundId, address player) external view returns (uint256) {
        Round storage r = _round(roundId);
        Bet storage b = _bets[roundId][player];
        if (b.claimed || b.amount == 0) return 0;
        if (r.status == Status.Cancelled) return b.amount;
        if (r.status == Status.Settled && b.side == r.winner) return _payout(r, b);
        return 0;
    }

    function vrfPrice() public view returns (uint256) {
        if (address(i_vrfV2PlusWrapper).code.length == 0) revert WrapperUnavailable();
        return i_vrfV2PlusWrapper.calculateRequestPriceNative(CALLBACK_GAS_LIMIT, 1);
    }

    function setRakeBps(uint16 value) external onlyOwner {
        if (value > MAX_RAKE_BPS) revert InvalidSetting();
        emit RakeBpsChanged(rakeBps, value);
        rakeBps = value;
    }

    function setBettingDuration(uint256 value) external onlyOwner {
        if (value < 60 || value > 1 days) revert InvalidSetting();
        emit BettingDurationChanged(bettingDuration, value);
        bettingDuration = value;
    }

    function setMinBet(uint256 value) external onlyOwner {
        if (value == 0) revert InvalidSetting();
        emit MinBetChanged(minBet, value);
        minBet = value;
    }

    function setTreasury(address value) external onlyOwner {
        if (value == address(0)) revert InvalidAddress();
        emit TreasuryChanged(treasury, value);
        treasury = value;
    }

    function setKeeper(address value) external onlyOwner {
        emit KeeperChanged(keeper, value);
        keeper = value;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
